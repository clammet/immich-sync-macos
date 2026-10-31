import FileProvider
import Foundation
import XCTest
@testable import ImmichCore
@testable import ImmichFileProvider

final class FolderViewTests: XCTestCase {
    private func work(_ catalog: Catalog, now: Date = Date()) throws -> [AssetPathWork] {
        try catalog.pathWork(sessionID: "mac-session", userID: "owner", now: now)
    }
    private func resolve(_ catalog: Catalog, _ assets: [Asset], now: Date = Date()) throws {
        try catalog.resolvedPaths(assets, work: work(catalog, now: now), userID: "owner", sessionID: "mac-session", now: now)
    }
    private func hierarchy(_ catalog: Catalog, _ id: String) throws -> [String] {
        var names: [String] = [], record = try catalog.item(id)
        while record.id != ItemRecord.libraryID {
            names.insert(record.filename, at: 0)
            record = try catalog.item(record.parentID)
        }
        return names
    }

    func testPathWorkCommitsWithCheckpointsAndResumesAfterBootstrapAndReopen() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        let messages = try bootstrap()
        try apply(catalog, Array(messages.dropLast()))
        XCTAssertTrue(try work(catalog).isEmpty) // Working generation is not published yet.
        let pending = try catalog.pendingAcknowledgements()
        XCTAssertFalse(pending.isEmpty)
        try catalog.acknowledged(pending, sessionID: "mac-session")
        let reopened = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        try apply(reopened, [messages.last!])
        XCTAssertEqual(try work(reopened).map(\.id), ["one"])
        try resolve(reopened, [makeAsset(path: "/data/library/user/2026/server-name.jpg")])
        XCTAssertTrue(try work(reopened).isEmpty)
        XCTAssertEqual(try hierarchy(reopened, "asset:one"), ["Server","data","library","user","2026","server-name [one].jpg"])
        XCTAssertEqual(try reopened.item("member:album:one").filename, "photo [one].jpg")
    }

    func testInvalidNativeBatchRollsBackPathWorkToo() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        XCTAssertThrowsError(try apply(catalog, [event("AssetV2", assetData()),event("SyncCompleteV1"),event("AssetV2", assetData("extra"))]))
        try apply(catalog, [event("SyncCompleteV1")])
        XCTAssertTrue(try work(catalog).isEmpty)
        XCTAssertThrowsError(try catalog.item("asset:one"))
    }

    func testPathOnlyAndIdenticalUpsertsCoalesceAndMoveWithoutContentDeletion() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try resolve(catalog, [makeAsset(path: "/upload/tmp/photo.jpg")])
        try catalog.pin("asset:one", value: true)
        let original = try catalog.item("asset:one")
        let same = try event("AssetV2", assetData(), sequence: 2)
        try apply(catalog, [same,same,same])
        XCTAssertEqual(try work(catalog).count, 1)
        let before = try catalog.anchor()
        try resolve(catalog, [makeAsset(path: "/data/library/user/2026/10/organized.jpg")])
        let moved = try catalog.item("asset:one")
        XCTAssertEqual(original.id, moved.id); XCTAssertEqual(original.contentVersion, moved.contentVersion)
        XCTAssertNotEqual(original.parentID, moved.parentID)
        XCTAssertEqual(try catalog.pinned(moved.id), true)
        XCTAssertEqual(try catalog.item("member:album:one").parentID, "album:album")
        XCTAssertEqual(try catalog.state("status", as: SyncStatus.self)?.assetCount, 1)
        // Even a move notification split across pages must not tell the working set to delete it.
        var anchor = before; var moves: [CatalogChange] = []
        while true {
            let changes = try catalog.changes(since: anchor, limit: 1)
            moves += changes.changes.filter { $0.id == moved.id }
            anchor = changes.anchor
            if !changes.more { break }
        }
        XCTAssertEqual(Set(moves.map(\.parentID)), Set([original.parentID,moved.parentID]))
        XCTAssertTrue(moves.allSatisfy { $0.record?.id == moved.id })
        XCTAssertThrowsError(try catalog.item(original.parentID)) // Empty old hierarchy is removed.
    }

    func testStaleLookupsCannotOverwriteNewUpdatesOrResurrectDeletedAssets() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        let stale = try work(catalog)
        try apply(catalog, [event("AssetV2", assetData(), sequence: 2)])
        try catalog.resolvedPaths([makeAsset(path: "/stale/photo.jpg")], work: stale, userID: "owner", sessionID: "mac-session")
        XCTAssertNil(try catalog.item("asset:one").asset?.originalPath)
        XCTAssertNotEqual(try work(catalog).first?.revision, stale.first?.revision)
        let beforeDelete = try work(catalog)
        try apply(catalog, [event("AssetDeleteV1", ["assetId": "one"], sequence: 3)])
        try catalog.resolvedPaths([makeAsset(path: "/resurrect/photo.jpg")], work: beforeDelete, userID: "owner", sessionID: "mac-session")
        XCTAssertTrue(try work(catalog).isEmpty)
        XCTAssertThrowsError(try catalog.item("asset:one"))
    }

    func testResetAndReauthenticationRejectOldPathResponses() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try resolve(catalog, [makeAsset(path: "/old/photo.jpg")])
        try apply(catalog, [event("AssetV2", assetData(), sequence: 2)])
        let stale = try work(catalog)
        try catalog.requestReset(sessionID: "mac-session"); try catalog.acceptedReset(sessionID: "mac-session")
        try apply(catalog, [event("AssetV2", assetData(), sequence: 3)])
        XCTAssertEqual(try catalog.item("asset:one").asset?.originalPath, "/old/photo.jpg")
        try apply(catalog, [event("SyncCompleteV1", sequence: 3)])
        try catalog.resolvedPaths([makeAsset(path: "/stale/photo.jpg")], work: stale, userID: "owner", sessionID: "mac-session")
        XCTAssertEqual(try catalog.item("asset:one").asset?.originalPath, "/old/photo.jpg")
        let replacement = try work(catalog)
        XCTAssertEqual(replacement.map(\.id), ["one"])
        try catalog.prepareSession("new-session")
        XCTAssertThrowsError(try catalog.resolvedPaths([makeAsset(path: "/wrong-session/photo.jpg")], work: replacement, userID: "owner", sessionID: "mac-session"))
        try catalog.acceptedReset(sessionID: "new-session")
        try apply(catalog, [event("AssetV2", assetData(), sequence: 4),event("SyncCompleteV1", sequence: 4)], sessionID: "new-session")
        let newWork = try catalog.pathWork(sessionID: "new-session", userID: "owner")
        XCTAssertEqual(newWork.count, 1)
        try catalog.resolvedPaths([makeAsset(path: "/new/photo.jpg")], work: newWork, userID: "owner", sessionID: "new-session")
        XCTAssertEqual(try catalog.item("asset:one").asset?.originalPath, "/new/photo.jpg")
    }

    func testDurableBackoffAndMissingOrMismatchedResultsPreserveNativeExistence() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        let now = Date()
        try catalog.failedPaths(work(catalog), sessionID: "mac-session", now: now)
        XCTAssertTrue(try work(catalog, now: now.addingTimeInterval(4)).isEmpty)
        let reopened = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        XCTAssertEqual(try work(reopened, now: now.addingTimeInterval(6)).count, 1)
        try resolve(reopened, [], now: now.addingTimeInterval(6))
        XCTAssertNotNil(try reopened.item("asset:one"))
        XCTAssertTrue(try work(reopened, now: now.addingTimeInterval(15)).isEmpty)
        try resolve(reopened, [makeAsset(checksum: "wrong", path: "/wrong/photo.jpg")], now: now.addingTimeInterval(17))
        XCTAssertNil(try reopened.item("asset:one").asset?.originalPath)
        try resolve(reopened, [makeAsset(path: "/correct/photo.jpg")], now: now.addingTimeInterval(40))
        XCTAssertTrue(try work(reopened, now: now.addingTimeInterval(10000)).isEmpty)
    }

    func testUnsafePathsAndCaseOrUnicodeCollisionsStayDistinctAndReachable() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        let paths = ["/A/photo.jpg", "/a/photo.jpg", "/café/photo.jpg", "/cafe\u{301}/photo.jpg", "/x:y/photo.jpg", "/x_y/photo.jpg", "relative/photo.jpg"]
        var events = try paths.indices.map { try event("AssetV2", assetData("id-\($0)"), sequence: $0 + 1) }
        let unsafe = ["/../outside.jpg", "/safe/./photo.jpg", "/safe//photo.jpg", "/control\n/photo.jpg", "/trailing/", "/" + String(repeating: "a/", count: 65) + "photo.jpg"]
        events += try unsafe.indices.map { try event("AssetV2", assetData("bad-\($0)"), sequence: $0 + 20) }
        events.append(try event("SyncCompleteV1", sequence: 50)); try apply(catalog, events)
        let assets = paths.enumerated().map { makeAsset("id-\($0.offset)", path: $0.element) }
            + unsafe.enumerated().map { makeAsset("bad-\($0.offset)", path: $0.element) }
        try resolve(catalog, assets)
        let parents = try paths.indices.map { try catalog.item("asset:id-\($0)").parentID }
        XCTAssertEqual(Set(parents).count, paths.count)
        let names = try parents.map { try catalog.item($0).filename.folding(options: [.caseInsensitive,.diacriticInsensitive], locale: nil) }
        XCTAssertNotEqual(names[0], names[1]); XCTAssertNotEqual(names[2], names[3]); XCTAssertNotEqual(names[4], names[5])
        for i in unsafe.indices { XCTAssertEqual(try hierarchy(catalog, "asset:bad-\(i)").first, "Unresolved paths") }
        for record in try catalog.page(parentID: nil, after: nil, expected: nil).items {
            XCTAssertFalse(record.filename.contains("/")); XCTAssertFalse(record.filename.contains(":"))
            XCTAssertLessThanOrEqual(record.filename.utf8.count, 240)
        }
        XCTAssertTrue(try work(catalog).isEmpty) // Unsafe paths do not cause endless polling.
    }

    func testRetiredServerFoldersPreserveLocalDescendantsAndCanReappear() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try resolve(catalog, [makeAsset(path: "/old/photos/photo.jpg")])
        let parent = try catalog.item("asset:one").parentID
        let local = ItemRecord(id: "ignored:" + UUID().uuidString, parentID: parent, filename: "notes.pdf", kind: .ignoredFile, modifiedAt: "1", localHash: "hash")
        try catalog.saveLocal(local)
        try FileManager.default.createDirectory(at: catalog.localDirectory, withIntermediateDirectories: true)
        let backing = catalog.localDirectory.appendingPathComponent(String(local.id.dropFirst(8)))
        let bytes = Data("local-only notes".utf8); try bytes.write(to: backing)
        try apply(catalog, [event("AssetV2", assetData(), sequence: 2)])
        try resolve(catalog, [makeAsset(path: "/new/photo.jpg")])
        XCTAssertEqual(try catalog.item(local.id), local)
        XCTAssertEqual(try catalog.item(parent).kind, .ignoredFolder)
        XCTAssertEqual(try hierarchy(catalog, local.id), ["Server","old","photos","notes.pdf"])
        try apply(catalog, [event("AssetV2", assetData(), sequence: 3)])
        try resolve(catalog, [makeAsset(path: "/old/photos/photo.jpg")])
        XCTAssertEqual(try catalog.item("asset:one").parentID, parent)
        XCTAssertEqual(try catalog.item(parent).kind, .folder)
        XCTAssertNotNil(try catalog.item(local.id))
        var cycle = try catalog.item(parent)
        cycle.kind = .ignoredFolder; cycle.parentID = parent
        XCTAssertThrowsError(try catalog.saveLocal(cycle))
        try catalog.requestReset(sessionID: "mac-session"); try catalog.acceptedReset(sessionID: "mac-session")
        try apply(catalog, [event("SyncCompleteV1", sequence: 4)])
        XCTAssertThrowsError(try catalog.item("asset:one"))
        XCTAssertEqual(try catalog.item(parent).kind, .ignoredFolder)
        XCTAssertEqual(try hierarchy(catalog, local.id), ["Server","old","photos","notes.pdf"])
        XCTAssertEqual(try Data(contentsOf: backing), bytes)
        XCTAssertTrue(try work(catalog).isEmpty)
    }

    func testLocalFilenameCollisionDoesNotOverwriteOrHideEitherItem() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        let local = ItemRecord(id: "ignored:" + UUID().uuidString, parentID: ItemRecord.libraryID, filename: "SERVER", kind: .ignoredFolder, modifiedAt: "1")
        try catalog.saveLocal(local)
        try resolve(catalog, [makeAsset(path: "/data/photo.jpg")])
        XCTAssertEqual(try catalog.item(local.id).filename, "SERVER")
        let tree = try hierarchy(catalog, "asset:one")
        XCTAssertTrue(tree[0].hasPrefix("Server ["))
        let before = tree
        try apply(catalog, [event("AssetV2", assetData(), sequence: 2)])
        try resolve(catalog, [makeAsset(path: "/data/photo.jpg")])
        XCTAssertEqual(try hierarchy(catalog, "asset:one"), before)
    }

    func testScopeFiltersAndExternalLibraryNamespacesRemainReadOnly() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        var external = assetData("external"); external["libraryId"] = "library-id"
        var locked = assetData("locked"); locked["visibility"] = "locked"
        var other = assetData("other"); other["ownerId"] = "someone-else"
        var unsupported = assetData("audio"); unsupported["type"] = "AUDIO"
        try apply(catalog, [event("AssetV2", external),event("AssetV2", locked),event("AssetV2", other),event("AssetV2", unsupported),event("AssetV2", assetData("trash", trashed: true)),event("SyncCompleteV1")])
        XCTAssertEqual(try work(catalog).map(\.id), ["external"])
        try resolve(catalog, [makeAsset("external", libraryID: "library-id", path: "/mnt/photos/file.jpg")])
        let record = try catalog.item("asset:external")
        XCTAssertEqual(try hierarchy(catalog, record.id).prefix(3), ["External Libraries","Library library-id","Server"])
        XCTAssertFalse(ProviderItem(record).capabilities.contains(.allowsDeleting))
        XCTAssertFalse(ProviderItem(try catalog.item(record.parentID)).capabilities.contains(.allowsAddingSubItems))
    }

    func testBatchedBootstrapCoalescesIDsAndHealthyIdleChecksQueryNoPaths() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let remote = FakeRemote()
        let ids = (0..<205).map { "asset-\($0)" }
        remote.assets = ids.map { makeAsset($0, path: "/data/2026/photo.jpg") }
        let initial = try ids.enumerated().map { try event("AssetV2", assetData($0.element), sequence: $0.offset + 1) }
        remote.streams = [.init(batches: [initial,try [event("AssetV2", assetData(ids[0]), sequence: 206),event("SyncCompleteV1", sequence: 207)]])]
        let engine = try SyncEngine(catalog: Catalog(url: folder.appendingPathComponent("catalog.sqlite")), remote: remote, account: testAccount())
        try await engine.synchronize(force: true)
        XCTAssertEqual(remote.pathRequests.map(\.count), [100,100,5])
        XCTAssertEqual(Set(remote.pathRequests.flatMap { $0 }), Set(ids))
        let before = try engine.catalog.anchor()
        try await engine.synchronize(force: true)
        try await engine.synchronize()
        XCTAssertEqual(remote.pathRequests.count, 3)
        XCTAssertEqual(try engine.catalog.anchor(), before)
        XCTAssertEqual(remote.downloadCount, 0); XCTAssertEqual(remote.events, [])
    }

    func testEngineResumesFailedPathWorkAfterAcknowledgementWithoutAnotherNativeStream() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        let remote = FakeRemote(); remote.pathFails = true
        remote.streams = [.init(batches: [try bootstrap()])]
        remote.afterAck = {
            XCTAssertEqual(try self.work(catalog).map(\.id), ["one"])
            XCTAssertFalse(try catalog.pendingAcknowledgements().isEmpty)
        }
        let engine = try SyncEngine(catalog: catalog, remote: remote, account: testAccount())
        do { try await engine.synchronize(force: true); XCTFail("Expected lookup failure") }
        catch SyncError.http { }
        XCTAssertTrue(try catalog.pendingAcknowledgements().isEmpty)
        XCTAssertNotNil(try catalog.state("status", as: SyncStatus.self)?.message)
        remote.afterAck = nil; remote.pathFails = false
        remote.assets = [makeAsset(path: "/recovered/photo.jpg")]
        let restarted = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        let due = try work(restarted, now: Date().addingTimeInterval(10))
        XCTAssertEqual(due.count, 1)
        // Advance the durable retry schedule without sleeping in a test.
        try restarted.failedPaths(due, sessionID: "mac-session", now: Date().addingTimeInterval(-100))
        let resumed = try SyncEngine(catalog: restarted, remote: remote, account: testAccount())
        try await resumed.synchronize()
        XCTAssertEqual(remote.synchronizeCount, 1)
        XCTAssertEqual(remote.pathRequests, [["one"],["one"]])
        XCTAssertTrue(try work(restarted).isEmpty)
        XCTAssertEqual(try restarted.item("asset:one").asset?.originalPath, "/recovered/photo.jpg")
        XCTAssertNil(try restarted.state("status", as: SyncStatus.self)?.message)
    }

    func testRecentSyncDoesNotThrottleReauthenticationOrInterruptedReplacementBootstrap() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        let remote = FakeRemote(); remote.assets = [makeAsset(path: "/before/photo.jpg")]
        remote.streams = [.init(batches: [try bootstrap()])]
        let first = try SyncEngine(catalog: catalog, remote: remote, account: testAccount())
        try await first.synchronize(force: true)
        remote.streams = [.init(batches: [try [event("AssetV2", assetData(), sequence: 2)]], failure: .invalidSyncStream),
                          .init(batches: [try [event("SyncCompleteV1", sequence: 2)]])]
        let reauthenticated = try SyncEngine(catalog: catalog, remote: remote, account: testAccount(sessionID: "new-session"))
        do { try await reauthenticated.synchronize(); XCTFail("Expected incomplete replacement") }
        catch SyncError.invalidSyncStream { }
        XCTAssertTrue(try catalog.isBootstrapping)
        try await reauthenticated.synchronize()
        XCTAssertFalse(try catalog.isBootstrapping)
        XCTAssertEqual(remote.resets, [true,true,false])
        XCTAssertNotNil(try catalog.item("asset:one"))
    }

    func testUploadThenOrganizationMovesSameAppearanceWithoutTransfersOrTrash() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let remote = FakeRemote(); remote.uploadPath = "/upload/owner/tmp.jpg"
        let engine = try SyncEngine(catalog: Catalog(url: folder.appendingPathComponent("catalog.sqlite")), remote: remote, account: testAccount())
        try await engine.synchronize(force: true)
        let file = folder.appendingPathComponent("new.jpg"); try Data("uploaded media".utf8).write(to: file)
        let uploaded = try await engine.create(parentID: ItemRecord.libraryID, filename: "new.jpg", directory: false, contents: file, progress: Progress())
        XCTAssertEqual(uploaded.id, "asset:edited")
        XCTAssertEqual(try hierarchy(engine.catalog, uploaded.id), ["Server","upload","owner","tmp [edited].jpg"])
        try engine.catalog.pin(uploaded.id, value: true)
        remote.assets[remote.assets.count - 1].originalPath = "/data/library/label/2026/10/31/new.jpg"
        remote.streams = [.init(batches: [try [event("AssetV2", assetData("edited", checksum: uploaded.asset!.checksum), sequence: 2),event("SyncCompleteV1", sequence: 2)]])]
        try await engine.synchronize(force: true)
        let moved = try engine.catalog.item(uploaded.id)
        XCTAssertNotEqual(moved.parentID, uploaded.parentID)
        XCTAssertEqual(moved.contentVersion, uploaded.contentVersion)
        XCTAssertEqual(try engine.catalog.pinned(moved.id), true)
        XCTAssertEqual(remote.events, ["upload"]); XCTAssertEqual(remote.downloadCount, 0)
        XCTAssertEqual(remote.pathRequests, [["edited"]])
        try await engine.synchronize(force: true)
        XCTAssertEqual(remote.pathRequests, [["edited"]])
    }

    func testDownloadReturnsCurrentFolderAfterConcurrentPathMove() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try resolve(catalog, [makeAsset(path: "/before/photo.jpg")])
        let remote = FakeRemote()
        remote.afterDownload = {
            try apply(catalog, [event("AssetV2", assetData(), sequence: 2)])
            try self.resolve(catalog, [makeAsset(path: "/after/photo.jpg")])
        }
        let engine = try SyncEngine(catalog: catalog, remote: remote, account: testAccount())
        let result = try await engine.download(id: "asset:one", directory: folder, progress: Progress(), requestedVersion: makeAsset().contentVersion)
        XCTAssertEqual(result.1.parentID, try catalog.item("asset:one").parentID)
        XCTAssertEqual(try hierarchy(catalog, result.1.id), ["Server","after","photo [one].jpg"])
    }

    func testServerFolderMutationsAreRejectedAndNewDirectoriesStayLocal() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try resolve(catalog, [makeAsset(path: "/data/photo.jpg")])
        let remote = FakeRemote(); let engine = try SyncEngine(catalog: catalog, remote: remote, account: testAccount())
        let asset = try catalog.item("asset:one"), parent = try catalog.item(asset.parentID)
        for operation in 0..<3 {
            do {
                if operation == 0 { _ = try await engine.modify(id: asset.id, baseContentVersion: asset.contentVersion, filename: nil, parentID: ItemRecord.libraryID, contents: nil, progress: Progress()) }
                if operation == 1 { _ = try await engine.modify(id: parent.id, baseContentVersion: parent.contentVersion, filename: "Renamed", parentID: nil, contents: nil, progress: Progress()) }
                if operation == 2 { try await engine.delete(id: parent.id, baseContentVersion: nil, recursive: true) }
                XCTFail("Expected server organization rejection")
            } catch SyncError.serverOrganization { }
        }
        XCTAssertEqual(remote.events, [])
        let local = try await engine.create(parentID: parent.id, filename: "Custom", directory: true, contents: nil, progress: Progress())
        XCTAssertEqual(local.kind, .ignoredFolder)
        let file = folder.appendingPathComponent("media.jpg"); try Data("local".utf8).write(to: file)
        let localMedia = try await engine.create(parentID: local.id, filename: "media.jpg", directory: false, contents: file, progress: Progress())
        XCTAssertEqual(localMedia.kind, .ignoredFile)
        XCTAssertEqual(remote.events, [])
        let promoted = try await engine.modify(id: localMedia.id, baseContentVersion: localMedia.contentVersion, filename: nil, parentID: ItemRecord.libraryID, contents: nil, progress: Progress())
        XCTAssertEqual(promoted.id, "asset:edited")
        XCTAssertEqual(remote.events, ["upload"])
        XCTAssertThrowsError(try catalog.item(localMedia.id))
    }

}
