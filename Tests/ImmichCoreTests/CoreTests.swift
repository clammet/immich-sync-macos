import CryptoKit
import FileProvider
import Foundation
import XCTest
@testable import ImmichCore
@testable import ImmichFileProvider

final class CoreTests: XCTestCase {
    func testServerNormalizationAndUnsafeURLs() throws {
        XCTAssertEqual(try ServerAddress("https://photos.example.com/prefix/").apiURL.absoluteString, "https://photos.example.com/prefix/api")
        XCTAssertEqual(try ServerAddress("https://photos.example.com/api/").apiURL.absoluteString, "https://photos.example.com/api")
        for value in ["https://key@host", "https://host/?key=secret", "https://host/#secret", "file:photos", "host"] {
            XCTAssertThrowsError(try ServerAddress(value), value)
        }
        XCTAssertThrowsError(try ServerAddress("http://localhost:2283"))
        XCTAssertEqual(try ServerAddress("http://localhost:2283", allowHTTP: true).apiURL.scheme, "http")
    }

    func testSupportedTypesComeFromServerAndIgnoreSidecars() {
        let types = MediaTypes(image: [".jpg", "arw", "image/heic"], video: [".mov"])
        for name in ["photo.JPG", "raw.arw", "photo.heic", "video.MOV"] { XCTAssertTrue(types.supports(filename: name), name) }
        for name in ["document.pdf", "photo.xmp", ".photo.jpg", "no-extension", "photo.jpg~"] { XCTAssertFalse(types.supports(filename: name), name) }
    }

    func testFilenameMappingPreventsTraversalAndCaseCollisions() {
        let name = ItemRecord.safeName("../a:b/\n.jpg", identity: "id", preserveExtension: true)
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains(":")); XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.hasPrefix(".")); XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertNotEqual(ItemRecord.safeName("A.jpg", identity: "one"), ItemRecord.safeName("a.jpg", identity: "two"))
        XCTAssertLessThanOrEqual(ItemRecord.safeName(String(repeating: "📷", count: 200) + ".jpg", identity: UUID().uuidString, preserveExtension: true).utf8.count, 240)
    }

    func testCatalogPersistsAnchorsDeletesAndPins() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("catalog.sqlite")
        let catalog = try Catalog(url: url)
        let initial = try catalog.anchor()
        let photo = makeAsset("one")
        let record = ItemRecord.record(asset: photo)
        try catalog.replace(with: [record])
        let changes = try catalog.changes(since: initial)
        XCTAssertEqual(changes.changes.count, 1); XCTAssertEqual(changes.changes[0].record, record)
        try catalog.pin(record.id, value: true)
        let reopened = try Catalog(url: url)
        XCTAssertEqual(try reopened.pinned(record.id), true)
        let beforeDeletion = try catalog.anchor()
        try catalog.replace(with: [])
        XCTAssertNil(try catalog.changes(since: beforeDeletion).changes[0].record)
        XCTAssertThrowsError(try catalog.changes(since: SyncAnchor(epoch: "other-database", sequence: 0)))
    }

    func testPagingRejectsAMixedSnapshot() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        let records = (0..<5).map { ItemRecord.record(asset: makeAsset("\($0)")) }
        try catalog.replace(with: records)
        let page = try catalog.page(parentID: ItemRecord.libraryID, after: nil, expected: nil, limit: 2)
        XCTAssertEqual(page.items.count, 2); XCTAssertNotNil(page.next)
        let next = try catalog.page(parentID: ItemRecord.libraryID, after: page.next, expected: page.anchor, limit: 2)
        XCTAssertEqual(Set(page.items.map(\.id)).intersection(next.items.map(\.id)), [])
        try catalog.replace(with: Array(records.dropLast()))
        XCTAssertThrowsError(try catalog.page(parentID: ItemRecord.libraryID, after: page.next, expected: page.anchor))
    }

    func testNativePolicyInheritanceAndReadOnlyExternalLibrary() {
        let normal = ItemRecord.record(asset: makeAsset("one"))
        XCTAssertEqual(ProviderItem(normal).contentPolicy, .inherited)
        XCTAssertEqual(ProviderItem(normal, pin: true).contentPolicy, .downloadEagerlyAndKeepDownloaded)
        XCTAssertEqual(ProviderItem(normal, pin: false).contentPolicy, .downloadLazily)
        XCTAssertTrue(ProviderItem(normal).capabilities.contains(.allowsWriting))
        XCTAssertFalse(ProviderItem(normal).capabilities.contains(.allowsRenaming))
        let external = ItemRecord.record(asset: makeAsset("external", libraryID: "external-library"))
        XCTAssertFalse(ProviderItem(external).capabilities.contains(.allowsDeleting))
        XCTAssertFalse(ProviderItem(external).capabilities.contains(.allowsWriting))
    }

    func testUnsupportedImportExcludesButExistingEditNeverExcludes() {
        let newError = ProviderErrors.map(SyncError.unsupported, newImport: true) as NSError
        let editError = ProviderErrors.map(SyncError.unsupported) as NSError
        XCTAssertEqual(newError.code, NSFileProviderError.excludedFromSync.rawValue)
        XCTAssertEqual(editError.code, NSFileProviderError.cannotSynchronize.rawValue)
    }

    func testMultipartDoesNotInjectHeadersAndPreservesBinaryContent() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input"); let output = folder.appendingPathComponent("multipart")
        let binary = Data([0, 1, 2, 255, 13, 10, 128]); try binary.write(to: file)
        try Multipart.write(file: file, filename: "photo\"\r\nInjected: x.jpg", fields: ["filename": "photo.jpg"], boundary: "BOUNDARY", to: output)
        let bytes = try Data(contentsOf: output)
        XCTAssertNotNil(bytes.range(of: binary))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nInjected:")); XCTAssertTrue(text.hasSuffix("\r\n--BOUNDARY--\r\n"))
        XCTAssertEqual(try FileDigest.sha1(file), Data(Insecure.SHA1.hash(data: binary)))
    }

    func testFailedSnapshotDoesNotPublishDeletes() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        let anchor = try engine.catalog.anchor()
        remote.snapshotFails = true
        do { try await engine.refresh(force: true); XCTFail("Expected a snapshot failure") } catch { }
        XCTAssertEqual(try engine.catalog.anchor(), anchor)
        XCTAssertNotNil(try engine.catalog.item("asset:one"))
    }

    func testUnsupportedImportIsDurableLocalOnlyAndBadged() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        let file = folder.appendingPathComponent("private.pdf")
        let bytes = Data("private document".utf8); try bytes.write(to: file)
        let item = try await engine.create(parentID: ItemRecord.libraryID, filename: "private.pdf", directory: false, contents: file, progress: Progress())
        XCTAssertEqual(item.kind, .ignoredFile)
        XCTAssertFalse(ProviderItem(item).isUploaded)
        XCTAssertEqual(ProviderItem(item).contentPolicy, .downloadEagerlyAndKeepDownloaded)
        XCTAssertEqual(ProviderItem(item).decorations?.first?.rawValue, "app.immich.sync.ignored")
        try await engine.refresh(force: true)
        XCTAssertEqual(try engine.catalog.item(item.id).localHash, item.localHash)
        let downloaded = try await engine.download(id: item.id, directory: folder, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: downloaded.0), bytes)
        XCTAssertEqual(remote.events, [])
    }

    func testLocalOnlyFileCanBeEditedAndDeletedWithoutRemoteMutation() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        let file = folder.appendingPathComponent("private.pdf"); try Data("first".utf8).write(to: file)
        let item = try await engine.create(parentID: ItemRecord.libraryID, filename: "private.pdf", directory: false, contents: file, progress: Progress())
        try Data("second".utf8).write(to: file)
        let modified = try await engine.modify(id: item.id, baseContentVersion: item.contentVersion, filename: "renamed.pdf", parentID: nil, contents: file, progress: Progress())
        XCTAssertEqual(modified.filename, "renamed.pdf")
        XCTAssertNotEqual(modified.localHash, item.localHash)
        try await engine.delete(id: item.id, baseContentVersion: modified.contentVersion, recursive: false)
        XCTAssertThrowsError(try engine.catalog.item(item.id))
        XCTAssertEqual(remote.events, [])
    }

    func testDeletingAlbumEntryOnlyRemovesMembership() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        try await engine.delete(id: "member:album:one", baseContentVersion: makeAsset("one").contentVersion, recursive: false)
        XCTAssertEqual(remote.events, ["remove:one:album"])
    }

    func testDeletingAllPhotosMovesToTrash() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        try await engine.delete(id: "asset:one", baseContentVersion: makeAsset("one").contentVersion, recursive: false)
        XCTAssertEqual(remote.events, ["trash:one"])
    }

    func testEditUploadsAndCopiesBeforeTrashingOriginal() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file)
        let result = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset("one").contentVersion,
            filename: nil, parentID: nil, contents: file, progress: Progress())
        XCTAssertEqual(result.asset?.id, "edited")
        XCTAssertEqual(remote.events, ["upload", "copy:one:edited", "trash:one"])
    }

    func testFailedCopyPreservesOriginalAndRetryReusesUpload() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file)
        remote.copyFails = true
        do { _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset("one").contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress()); XCTFail("Expected failure") } catch { }
        XCTAssertFalse(remote.events.contains("trash:one"))
        remote.copyFails = false
        _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset("one").contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress())
        XCTAssertEqual(remote.events.filter { $0 == "upload" }.count, 1)
        XCTAssertEqual(remote.events.last, "trash:one")
    }

    func testConcurrentRemoteChangeStopsLocalEditBeforeUpload() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        remote.assets = [makeAsset("one", checksum: "remote-new-version")]
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file)
        do { _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset("one").contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress()); XCTFail("Expected conflict") } catch SyncError.conflict { }
        XCTAssertEqual(remote.events, [])
    }

    func testCompletedEditRecoversAfterRefreshFailureAndCatalogRestart() async throws {
        let (engine, remote, folder) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.refresh(force: true)
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file)
        remote.failRefreshAfterTrash = true
        do { _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset("one").contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress()); XCTFail("Expected refresh failure") }
        catch SyncError.incompleteListing { }
        remote.failRefreshAfterTrash = false; remote.snapshotFails = false
        let restarted = SyncEngine(catalog: try Catalog(url: folder.appendingPathComponent("catalog.sqlite")), remote: remote)
        try await restarted.refresh(force: true)
        XCTAssertThrowsError(try restarted.catalog.item("asset:one"))
        let result = try await restarted.modify(id: "asset:one", baseContentVersion: makeAsset("one").contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress())
        XCTAssertEqual(result.asset?.id, "edited")
        XCTAssertEqual(remote.events, ["upload", "copy:one:edited", "trash:one"])
    }

    func testCatalogRejectsStaleWriterWithoutLosingLocalData() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("catalog.sqlite")
        let first = try Catalog(url: url); let second = try Catalog(url: url)
        let oldAnchor = try first.anchor()
        let record = ItemRecord.record(asset: makeAsset("one"))
        try second.replace(with: [record])
        XCTAssertThrowsError(try first.replace(with: [], expectedAnchor: oldAnchor))
        XCTAssertEqual(try first.item(record.id), record)
    }

    private func setup() throws -> (SyncEngine, FakeRemote, URL) {
        let folder = try temporaryFolder()
        let remote = FakeRemote()
        return (SyncEngine(catalog: try Catalog(url: folder.appendingPathComponent("catalog.sqlite")), remote: remote), remote, folder)
    }
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeAsset(_ id: String, checksum: String = "original", libraryID: String? = nil, trashed: Bool = false) -> Asset {
    Asset(id: id, ownerId: "owner", originalFileName: "photo.jpg", originalMimeType: "image/jpeg", checksum: checksum,
        type: "IMAGE", fileCreatedAt: "2026-01-01T00:00:00Z", fileModifiedAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z", isTrashed: trashed, isOffline: false, visibility: "timeline", libraryId: libraryID, exifInfo: nil)
}

final class FakeRemote: ImmichRemote, @unchecked Sendable {
    var assets = [makeAsset("one")]
    var events: [String] = []
    var snapshotFails = false
    var copyFails = false
    var failRefreshAfterTrash = false
    func snapshot() async throws -> RemoteSnapshot {
        if snapshotFails { throw SyncError.incompleteListing }
        return RemoteSnapshot(assets: assets.filter { !$0.isTrashed }, albums: [Album(id: "album", albumName: "Holiday", updatedAt: "1", ownerId: "owner", assetCount: 1)],
            memberships: ["album": assets.map(\.id)], mediaTypes: MediaTypes(image: ["jpg"], video: ["mov"]))
    }
    func asset(_ id: String) async throws -> Asset {
        guard let result = assets.first(where: { $0.id == id }) else { throw SyncError.missingItem }; return result
    }
    func upload(_ file: URL, filename: String, progress: Progress) async throws -> Asset {
        events.append("upload")
        let result = makeAsset("edited", checksum: try FileDigest.sha1(file).base64EncodedString())
        assets.append(result); return result
    }
    func download(_ asset: Asset, into directory: URL, progress: Progress) async throws -> URL { throw SyncError.unsupported }
    func thumbnail(_ assetID: String, large: Bool) async throws -> Data { throw SyncError.unsupported }
    func createAlbum(name: String) async throws -> Album { throw SyncError.unsupported }
    func renameAlbum(_ id: String, name: String) async throws { events.append("rename:\(id)") }
    func deleteAlbum(_ id: String) async throws { events.append("delete-album:\(id)") }
    func add(_ assetID: String, to albumID: String) async throws { events.append("add:\(assetID):\(albumID)") }
    func remove(_ assetID: String, from albumID: String) async throws { events.append("remove:\(assetID):\(albumID)") }
    func copyAssociations(from sourceID: String, to targetID: String) async throws {
        events.append("copy:\(sourceID):\(targetID)"); if copyFails { throw SyncError.http(503, retryAfter: nil) }
    }
    func trash(_ assetID: String) async throws {
        events.append("trash:\(assetID)")
        assets = assets.map { $0.id == assetID ? makeAsset($0.id, checksum: $0.checksum, trashed: true) : $0 }
        if failRefreshAfterTrash { snapshotFails = true }
    }
}
