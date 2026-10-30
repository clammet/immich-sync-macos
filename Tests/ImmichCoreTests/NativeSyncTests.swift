import Foundation
import XCTest
@testable import ImmichCore

final class NativeSyncTests: XCTestCase {
    func testFragmentedUTF8AndBackfillCheckpointDecode() throws {
        let bytes = try wireLine("AssetV2", assetData(name: "café 📷.jpg"))
        var decoder = SyncLineDecoder(); var decoded: [SyncEvent] = []
        for byte in bytes { if let value = try decoder.append(byte) { decoded.append(value) } }
        try decoder.finish()
        XCTAssertEqual(decoded.count, 1)
        guard case .asset(let asset) = decoded[0].payload else { return XCTFail("Expected asset") }
        XCTAssertEqual(asset.originalFileName, "café 📷.jpg")
        let marker = try event("SyncAckV1", checkpoint: "AlbumToAssetBackfillV1")
        XCTAssertEqual(marker.ackKind, "AlbumToAssetBackfillV1")
    }
    func testUnknownEntityAndMismatchedAckAreRejected() throws {
        XCTAssertThrowsError(try event("AssetV1", assetData()))
        XCTAssertThrowsError(try event("FutureEntityV9"))
        XCTAssertThrowsError(try event("AssetV2", assetData(), checkpoint: "AlbumV2"))
        XCTAssertThrowsError(try event("SyncAckV1", checkpoint: "SyncCompleteV1"))
    }
    func testPartialLineAndOversizedLineAreRejected() throws {
        var decoder = SyncLineDecoder()
        for byte in Data("{\"type\":".utf8) { _ = try decoder.append(byte) }
        XCTAssertThrowsError(try decoder.finish())
        var oversized = SyncLineDecoder()
        for _ in 0..<1_048_576 { _ = try oversized.append(32) }
        XCTAssertThrowsError(try oversized.append(32))
    }
    func testBootstrapPublishesOnlyAtCompletionAndSurvivesReopen() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        let messages = try bootstrap()
        try apply(catalog, Array(messages.dropLast()))
        XCTAssertThrowsError(try catalog.item("asset:one"))
        XCTAssertFalse(try catalog.pendingAcknowledgements().isEmpty)
        let reopened = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        try reopened.prepareSession("mac-session")
        XCTAssertFalse(try reopened.needsServerReset)
        try apply(reopened, [messages.last!])
        XCTAssertEqual(try reopened.item("asset:one").asset?.size, 4096)
        XCTAssertEqual(try reopened.item("member:album:one").parentID, "album:album")
    }
    func testAcknowledgementsAreCommittedWithDataAndReplayIsIdempotent() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        let events = try bootstrap()
        try apply(catalog, events)
        let anchor = try catalog.anchor()
        let pending = try catalog.pendingAcknowledgements()
        try apply(catalog, events)
        XCTAssertEqual(try catalog.anchor(), anchor)
        XCTAssertEqual(try catalog.pendingAcknowledgements(), pending)
        try catalog.acknowledged(pending, sessionID: "mac-session")
        XCTAssertTrue(try catalog.pendingAcknowledgements().isEmpty)
    }
    func testInvalidBatchRollsBackDataAndCheckpointTogether() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        let bad = try [event("AssetV2", assetData()), event("SyncCompleteV1"), event("AssetV2", assetData("extra"))]
        XCTAssertThrowsError(try apply(catalog, bad))
        XCTAssertTrue(try catalog.pendingAcknowledgements().isEmpty)
        try apply(catalog, [event("SyncCompleteV1")])
        XCTAssertThrowsError(try catalog.item("asset:one"))
    }
    func testResetKeepsVisibleLibraryAndLocalFilesUntilReplacementCompletes() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        let ignored = ItemRecord(id: "ignored:" + UUID().uuidString, parentID: "album:album", filename: "notes.pdf", kind: .ignoredFile, modifiedAt: "1")
        try catalog.saveLocal(ignored)
        try catalog.requestReset(sessionID: "mac-session"); try catalog.acceptedReset(sessionID: "mac-session")
        try apply(catalog, [event("AssetV2", assetData("new"), sequence: 2)])
        XCTAssertNotNil(try catalog.item("asset:one"))
        XCTAssertThrowsError(try catalog.item("asset:new"))
        try apply(catalog, [event("SyncCompleteV1", sequence: 2)])
        XCTAssertThrowsError(try catalog.item("asset:one"))
        XCTAssertNotNil(try catalog.item("asset:new"))
        XCTAssertEqual(try catalog.item(ignored.id).parentID, ItemRecord.libraryID)
    }
    func testSessionChangeClearsCheckpointsAndRejectsOldWriter() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try catalog.prepareSession("new-session")
        XCTAssertTrue(try catalog.needsServerReset)
        XCTAssertTrue(try catalog.pendingAcknowledgements().isEmpty)
        XCTAssertThrowsError(try apply(catalog, [event("AssetDeleteV1", ["assetId": "one"]) ]))
        XCTAssertThrowsError(try catalog.acknowledged([], sessionID: "mac-session"))
        XCTAssertNotNil(try catalog.item("asset:one"))
    }
    func testTrashRestoreAndPermanentDeleteKeepMembershipCorrect() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try apply(catalog, [event("AssetV2", assetData(trashed: true), sequence: 2),event("SyncCompleteV1", sequence: 2)])
        XCTAssertThrowsError(try catalog.item("asset:one")); XCTAssertThrowsError(try catalog.item("member:album:one"))
        try apply(catalog, [event("AssetV2", assetData(), sequence: 3),event("SyncCompleteV1", sequence: 3)])
        XCTAssertNotNil(try catalog.item("member:album:one"))
        try apply(catalog, [event("AssetDeleteV1", ["assetId": "one"], sequence: 4),event("SyncCompleteV1", sequence: 4)])
        XCTAssertThrowsError(try catalog.item("asset:one"))
        try apply(catalog, [event("AssetV2", assetData(), sequence: 5),event("SyncCompleteV1", sequence: 5)])
        XCTAssertThrowsError(try catalog.item("member:album:one"))
    }
    func testOwnershipAndMembershipChangesUpdateOnlyTheirAppearances() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder); try apply(catalog, bootstrap())
        try apply(catalog, [event("AlbumToAssetDeleteV1", ["albumId": "album", "assetId": "one"], sequence: 2)])
        XCTAssertThrowsError(try catalog.item("member:album:one")); XCTAssertNotNil(try catalog.item("asset:one"))
        try apply(catalog, [event("AlbumToAssetBackfillV1", ["albumId": "album", "assetId": "one"], sequence: 3)])
        XCTAssertNotNil(try catalog.item("member:album:one"))
        try apply(catalog, [event("AlbumUserV1", ["albumId": "album", "userId": "owner", "role": "viewer"], sequence: 4)])
        XCTAssertThrowsError(try catalog.item("album:album")); XCTAssertThrowsError(try catalog.item("member:album:one"))
        XCTAssertNotNil(try catalog.item("asset:one"))
    }
    func testExifBeforeAssetAndVisibilityUpdates() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        try apply(catalog, [event("AssetExifV1", ["assetId": "one", "fileSizeInByte": 100]),event("AssetV2", assetData()),event("SyncCompleteV1")])
        XCTAssertEqual(try catalog.item("asset:one").asset?.size, 100)
        var locked = assetData(); locked["visibility"] = "locked"
        try apply(catalog, [event("AssetV2", locked, sequence: 2)])
        XCTAssertThrowsError(try catalog.item("asset:one"))
    }
    func testIdleSyncDoesNotInvalidateFinderPagesOrEmitChanges() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        try apply(catalog, [event("AssetV2", assetData("a")),event("AssetV2", assetData("b")),event("SyncCompleteV1")])
        let first = try catalog.page(parentID: ItemRecord.libraryID, after: nil, expected: nil, limit: 1)
        try apply(catalog, [event("SyncCompleteV1", sequence: 2)])
        XCTAssertEqual(try catalog.anchor(), first.anchor)
        XCTAssertTrue(try catalog.changes(since: first.anchor).changes.isEmpty)
        XCTAssertEqual(try catalog.page(parentID: ItemRecord.libraryID, after: first.next, expected: first.anchor, limit: 1).items.count, 1)
    }
    func testSingleAssetDeltaDoesNotRepublishLargeLibrary() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try initializedCatalog(folder)
        var initial = try (0..<2000).map { try event("AssetV2", assetData("asset-\($0)"), sequence: $0 + 1) }
        initial.append(try event("SyncCompleteV1", sequence: 2001)); try apply(catalog, initial)
        let before = try catalog.anchor()
        try apply(catalog, [event("AssetV2", assetData("asset-5", name: "changed.jpg"), sequence: 2002),event("SyncCompleteV1", sequence: 2002)])
        let changes = try catalog.changes(since: before).changes
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes[0].id, "asset:asset-5")
    }
    func testEngineAcknowledgesOnlyDurableDataAndReplaysFailedAck() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let account = testAccount(); let catalog = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
        let remote = FakeRemote(); remote.streams = [.init(batches: [try bootstrap()])]; remote.failAck = true
        remote.afterAck = { XCTAssertNotNil(try catalog.item("asset:one")); XCTAssertFalse(try catalog.pendingAcknowledgements().isEmpty) }
        let engine = try SyncEngine(catalog: catalog, remote: remote, account: account)
        do { try await engine.synchronize(force: true); XCTFail("Expected failed acknowledgement") } catch SyncError.http { }
        XCTAssertFalse(try catalog.pendingAcknowledgements().isEmpty)
        remote.afterAck = nil
        try await engine.synchronize()
        XCTAssertEqual(remote.ackAttempts[0], remote.ackAttempts[1])
        XCTAssertTrue(try catalog.pendingAcknowledgements().isEmpty)
        XCTAssertEqual(remote.resets, [true,false])
    }
    func testEngineHandlesServerRequestedResetThroughNativeBootstrap() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let remote = FakeRemote()
        remote.streams = [.init(batches: [try bootstrap()]),.init(batches: [], failure: .syncReset),.init(batches: [try bootstrap("new", sequence: 2)])]
        let engine = try SyncEngine(catalog: Catalog(url: folder.appendingPathComponent("catalog.sqlite")), remote: remote, account: testAccount())
        try await engine.synchronize(force: true); try await engine.synchronize(force: true)
        XCTAssertEqual(remote.resets, [true,false,true])
        XCTAssertThrowsError(try engine.catalog.item("asset:one")); XCTAssertNotNil(try engine.catalog.item("asset:new"))
    }
}
