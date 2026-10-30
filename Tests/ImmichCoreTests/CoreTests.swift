import CryptoKit
import FileProvider
import Foundation
import XCTest
@testable import ImmichCore
@testable import ImmichFileProvider

final class CoreTests: XCTestCase {
    func testServerNormalizationRejectsCredentialAndQueryURLs() throws {
        XCTAssertEqual(try ServerAddress("https://photos.example.com/prefix/").apiURL.absoluteString, "https://photos.example.com/prefix/api")
        XCTAssertEqual(try ServerAddress("https://photos.example.com/api/").apiURL.absoluteString, "https://photos.example.com/api")
        for value in ["https://key@host", "https://host/?token=secret", "https://host/#secret", "file:photos", "host"] {
            XCTAssertThrowsError(try ServerAddress(value))
        }
        XCTAssertThrowsError(try ServerAddress("http://localhost:2283"))
        XCTAssertEqual(try ServerAddress("http://localhost:2283", allowHTTP: true).apiURL.scheme, "http")
    }
    func testOnlyPinnedServerReleaseIsAccepted() throws {
        try ServerVersion(major: 3, minor: 3, patch: 5).requireSupported()
        for version in [ServerVersion(major: 2, minor: 5, patch: 0),ServerVersion(major: 3, minor: 2, patch: 0),ServerVersion(major: 4, minor: 0, patch: 0),ServerVersion(major: 3, minor: 3, patch: 5, prerelease: 1)] {
            XCTAssertThrowsError(try version.requireSupported())
        }
    }
    func testSupportedTypesUseServerExtensionsAndExcludeSidecars() {
        let types = MediaTypes(image: [".jpg", ".arw", ".heic"], video: [".mov"])
        for name in ["photo.JPG", "raw.arw", "photo.heic", "video.MOV"] { XCTAssertTrue(types.supports(filename: name)) }
        for name in ["document.pdf", "photo.xmp", ".photo.jpg", "no-extension", "photo.jpg~"] { XCTAssertFalse(types.supports(filename: name)) }
    }
    func testFilenameMappingPreventsTraversalAndCaseCollisions() {
        let name = ItemRecord.safeName("../a:b/\n.jpg", identity: "id", preserveExtension: true)
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains(":")); XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.hasPrefix(".")); XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertNotEqual(ItemRecord.safeName("A.jpg", identity: "one"),ItemRecord.safeName("a.jpg", identity: "two"))
        XCTAssertLessThanOrEqual(ItemRecord.safeName(String(repeating: "📷", count: 200) + ".jpg", identity: UUID().uuidString, preserveExtension: true).utf8.count, 240)
    }
    func testNativeAvailabilityAndExternalOriginalCapabilities() {
        let normal = ItemRecord.record(asset: makeAsset())
        XCTAssertEqual(ProviderItem(normal).contentPolicy, .inherited)
        XCTAssertEqual(ProviderItem(normal, pin: true).contentPolicy, .downloadEagerlyAndKeepDownloaded)
        XCTAssertTrue(ProviderItem(normal).capabilities.contains(.allowsWriting))
        XCTAssertFalse(ProviderItem(normal).capabilities.contains(.allowsRenaming))
        let external = ItemRecord.record(asset: makeAsset("external", libraryID: "external"))
        XCTAssertFalse(ProviderItem(external).capabilities.contains(.allowsDeleting))
    }
    func testNewExclusionDoesNotTurnAnExistingEditIntoRemoteDeletion() {
        XCTAssertEqual((ProviderErrors.map(SyncError.unsupported, newImport: true) as NSError).code, NSFileProviderError.excludedFromSync.rawValue)
        XCTAssertEqual((ProviderErrors.map(SyncError.unsupported) as NSError).code, NSFileProviderError.cannotSynchronize.rawValue)
        XCTAssertEqual((ProviderErrors.map(SyncError.http(401, retryAfter: nil)) as NSError).code, NSFileProviderError.notAuthenticated.rawValue)
    }
    func testMultipartPreservesBinaryAndPreventsFilenameHeaderInjection() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("multipart")
        let binary = Data([0,1,2,255,13,10,128]); try binary.write(to: file)
        try Multipart.write(file: file, filename: "photo\"\r\nInjected: x.jpg", fields: ["filename": "photo.jpg"], boundary: "BOUNDARY", to: output)
        let bytes = try Data(contentsOf: output)
        XCTAssertNotNil(bytes.range(of: binary))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\r\nInjected:"))
        XCTAssertEqual(try FileDigest.sha1(file),Data(Insecure.SHA1.hash(data: binary)))
    }
    func testOAuthUsesPKCEAndRejectsWrongStateOrRedirect() throws {
        let challenge = try OAuthChallenge()
        XCTAssertEqual(challenge.verifier.count, 43); XCTAssertEqual(challenge.challenge.count, 43)
        XCTAssertNotEqual(challenge.verifier, challenge.challenge)
        try challenge.validate(URL(string: "immich-sync://oauth?state=\(challenge.state)&code=code")!)
        for callback in ["immich-sync://oauth?state=wrong&code=code", "https://other.example.com/?state=\(challenge.state)&code=code",
                         "immich-sync://oauth?state=\(challenge.state)&state=\(challenge.state)&code=code", "immich-sync://oauth?state=\(challenge.state)&error=denied"] {
            XCTAssertThrowsError(try challenge.validate(URL(string: callback)!))
        }
    }
    func testIgnoredImportIsDurableAndNeverTriggersRemoteSync() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("private.pdf"), bytes = Data("private document".utf8)
        try bytes.write(to: file)
        let item = try await engine.create(parentID: ItemRecord.libraryID, filename: "private.pdf", directory: false, contents: file, progress: Progress())
        XCTAssertEqual(item.kind, .ignoredFile); XCTAssertFalse(ProviderItem(item).isUploaded)
        XCTAssertEqual(ProviderItem(item).decorations?.first?.rawValue, "app.immich.sync.ignored")
        XCTAssertEqual(ProviderItem(item).contentPolicy, .downloadEagerlyAndKeepDownloaded)
        let downloaded = try await engine.download(id: item.id, directory: folder, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: downloaded.0), bytes)
        XCTAssertEqual(remote.events, []); XCTAssertEqual(remote.synchronizeCount, 1)
    }
    func testIgnoredFileEditAndDeleteStayLocal() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("private.pdf"); try Data("first".utf8).write(to: file)
        let item = try await engine.create(parentID: ItemRecord.libraryID, filename: "private.pdf", directory: false, contents: file, progress: Progress())
        try Data("second".utf8).write(to: file)
        let modified = try await engine.modify(id: item.id, baseContentVersion: item.contentVersion, filename: "renamed.pdf", parentID: nil, contents: file, progress: Progress())
        XCTAssertNotEqual(modified.localHash, item.localHash)
        try await engine.delete(id: item.id, baseContentVersion: modified.contentVersion, recursive: false)
        XCTAssertThrowsError(try engine.catalog.item(item.id)); XCTAssertEqual(remote.events, [])
    }
    func testUploadsAndAlbumChangesCommitLocallyWithoutFullRefresh() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("new.jpg"); try Data("new".utf8).write(to: file)
        let uploaded = try await engine.create(parentID: "album:album", filename: "new.jpg", directory: false, contents: file, progress: Progress())
        XCTAssertEqual(uploaded.id, "member:album:edited")
        XCTAssertNotNil(try engine.catalog.item("asset:edited"))
        let album = try await engine.create(parentID: ItemRecord.albumsID, filename: "New album", directory: true, contents: nil, progress: Progress())
        _ = try await engine.modify(id: album.id, baseContentVersion: album.contentVersion, filename: "Renamed", parentID: nil, contents: nil, progress: Progress())
        XCTAssertTrue(try engine.catalog.item(album.id).filename.hasPrefix("Renamed"))
        XCTAssertEqual(remote.synchronizeCount, 1)
    }
    func testAlbumRemovalKeepsOriginalWhileLibraryDeletionTrashesIt() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try await engine.delete(id: "member:album:one", baseContentVersion: makeAsset().contentVersion, recursive: false)
        XCTAssertEqual(remote.events, ["remove:one:album"]); XCTAssertNotNil(try engine.catalog.item("asset:one"))
        try await engine.delete(id: "asset:one", baseContentVersion: makeAsset().contentVersion, recursive: false)
        XCTAssertEqual(remote.events.last, "trash:one"); XCTAssertThrowsError(try engine.catalog.item("asset:one"))
        XCTAssertEqual(remote.synchronizeCount, 1)
    }
    func testEditCopiesBeforeTrashAndPreservesPinnedAvailability() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        try engine.catalog.pin("asset:one", value: true)
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file)
        let result = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset().contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress())
        XCTAssertEqual(result.id, "asset:edited")
        XCTAssertEqual(remote.events, ["upload","copy:one:edited","trash:one"])
        XCTAssertEqual(try engine.catalog.pinned(result.id), true)
        XCTAssertNotNil(try engine.catalog.item("member:album:edited")); XCTAssertEqual(remote.synchronizeCount, 1)
    }
    func testFailedCopyPreservesOriginalAndRetryReusesUploadedAsset() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file)
        remote.copyFails = true
        do { _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset().contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress()); XCTFail("Expected failure") } catch SyncError.http { }
        XCTAssertNotNil(try engine.catalog.item("asset:one")); XCTAssertFalse(remote.events.contains("trash:one"))
        remote.copyFails = false
        _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset().contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress())
        XCTAssertEqual(remote.events.filter { $0 == "upload" }.count, 1)
    }
    func testLostTrashResponseRecoversWithoutRepeatedUploadOrDeletion() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file); remote.trashResponseFails = true
        do { _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset().contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress()); XCTFail("Expected failure") } catch SyncError.http { }
        let restarted = try SyncEngine(catalog: Catalog(url: folder.appendingPathComponent("catalog.sqlite")), remote: remote, account: testAccount())
        let item = try await restarted.modify(id: "asset:one", baseContentVersion: makeAsset().contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress())
        XCTAssertEqual(item.id, "asset:edited")
        XCTAssertEqual(remote.events, ["upload","copy:one:edited","trash:one"])
    }
    func testRemoteConflictStopsAnEditBeforeUpload() async throws {
        let (engine, remote, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        remote.assets = [makeAsset(checksum: "remote-change")]
        let file = folder.appendingPathComponent("edit.jpg"); try Data("edited".utf8).write(to: file)
        do { _ = try await engine.modify(id: "asset:one", baseContentVersion: makeAsset().contentVersion, filename: nil, parentID: nil, contents: file, progress: Progress()); XCTFail("Expected conflict") } catch SyncError.conflict { }
        XCTAssertEqual(remote.events, [])
    }
    private func setup() async throws -> (SyncEngine, FakeRemote, URL) {
        let folder = try temporaryFolder(); let remote = FakeRemote()
        remote.streams = [.init(batches: [try bootstrap()])]
        let engine = try SyncEngine(catalog: Catalog(url: folder.appendingPathComponent("catalog.sqlite")), remote: remote, account: testAccount())
        try await engine.synchronize(force: true)
        return (engine,remote,folder)
    }
}
