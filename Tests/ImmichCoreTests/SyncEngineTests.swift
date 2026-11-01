import FileProvider
import Foundation
import XCTest
@testable import ImmichCore
import ImmichFileProvider

final class SyncEngineTests: CatalogTestCase {
    let root = cloud("root",[],directory: true)
    func testGenericTreeRetainsNamesAndStableIDsAcrossRemoteMoves() async throws {
        let dir = cloud("folder",["Documents"],directory: true), file = cloud("file",["Documents","notes.txt"])
        let server = CloudServer([root,dir,file]); let engine = try engine(server)
        try await engine.synchronize()
        XCTAssertEqual(try catalog.item(file.id).filename,"notes.txt")
        XCTAssertEqual(try catalog.item(file.id).parentID,dir.id)
        try catalog.pin(file.id,value: true)
        let moved = cloud("file",["report.pdf"],etag: "v2")
        await server.setFiles([root,dir,moved]); try await engine.synchronize(force: true)
        XCTAssertEqual(try catalog.item(file.id).filename,"report.pdf")
        XCTAssertEqual(try catalog.item(file.id).parentID,root.id)
        XCTAssertEqual(try catalog.pinned(file.id),true)
    }
    func testPartialScanAndConcurrentDirectoryChangesNeverPublishDeletions() async throws {
        let dir = cloud("dir",["Photos"],directory: true), file = cloud("file",["old.bin"])
        let server = CloudServer([root,dir,file]); let engine = try engine(server)
        try await engine.synchronize(); let anchor = try catalog.anchor()
        await server.setFiles([root,dir]); await server.failListing(at: ["Photos"])
        do { try await engine.synchronize(force: true); XCTFail("Expected offline failure") } catch {}
        XCTAssertEqual(try catalog.item(file.id).filename,"old.bin"); XCTAssertEqual(try catalog.anchor(),anchor)
        await server.failListing(at: nil); await server.changeRootDuringListing()
        do { try await engine.synchronize(force: true); XCTFail("Expected changed directory") } catch {}
        XCTAssertEqual(try catalog.anchor(),anchor)
        try await engine.synchronize(force: true)
        XCTAssertThrowsError(try catalog.item(file.id))
    }
    func testConflictPreservesEditAcrossCatalogReopenAndRemoteDeletion() async throws {
        let file = cloud("file",["document.txt"]), server = CloudServer([root,cloud("file",["document.txt"],etag: "other-client")])
        _ = try catalog.commit(root,parentID: ItemRecord.rootID); _ = try catalog.commit(file,parentID: root.id)
        let source = try contents("unsynced")
        do { _ = try await engine(server).modify(id: file.id,baseContentVersion: Data(file.etag.utf8),filename: nil,parentID: nil,contents: source,progress: Progress()); XCTFail("Expected conflict") } catch SyncError.conflict {}
        let reopened = try Catalog(url: directory.appendingPathComponent("catalog.sqlite"))
        let edit = try XCTUnwrap(reopened.recoveryOperations().first)
        let saved = reopened.localDirectory.appendingPathComponent(edit.id).appendingPathComponent("content/document.txt")
        XCTAssertEqual(try String(contentsOf: saved),"unsynced")
        let puts = await server.uploadCount; XCTAssertEqual(puts,0)
        await server.setFiles([root]); try await engine(server).synchronize(force: true)
        XCTAssertEqual(try reopened.recoveryOperations().count,1)
        XCTAssertEqual(try String(contentsOf: saved),"unsynced")
    }
    func testOfflineCreateStagesOnceAndRetriesWithoutImmichOrMediaRestrictions() async throws {
        let server = CloudServer([root]); _ = try catalog.commit(root,parentID: ItemRecord.rootID)
        let source = try contents("ordinary file")
        let paused = try engine(server,check: { throw SyncError.paused })
        for _ in 0..<2 {
            do { _ = try await paused.create(parentID: root.id,filename: "operation.json",directory: false,contents: source,progress: Progress()); XCTFail("Expected pause") } catch SyncError.paused {}
        }
        let edit = try XCTUnwrap(catalog.recoveryOperations().first)
        XCTAssertEqual(try catalog.recoveryOperations().count,1)
        let staged = catalog.localDirectory.appendingPathComponent(edit.id).appendingPathComponent("content/operation.json")
        XCTAssertEqual(try String(contentsOf: staged),"ordinary file")
        let created = try await engine(server).create(parentID: root.id,filename: "operation.json",directory: false,contents: source,progress: Progress())
        XCTAssertEqual(created.filename,"operation.json"); XCTAssertTrue(try catalog.recoveryOperations().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testDestinationCollisionNeverOverwritesAndKeepsRecovery() async throws {
        let file = cloud("existing",["report.txt"]), server = CloudServer([root,file]); let engine = try engine(server)
        try await engine.synchronize()
        do { _ = try await engine.create(parentID: root.id,filename: "report.txt",directory: false,contents: contents(),progress: Progress()); XCTFail("Expected collision") } catch SyncError.conflict {}
        XCTAssertEqual(try catalog.item(file.id).remote?.etag,file.etag)
        XCTAssertEqual(try catalog.recoveryOperations().count,1); let puts = await server.uploadCount; XCTAssertEqual(puts,0)
    }
    func testInterruptedContentAndRenameResumesRecordedUploadWithoutUploadingTwice() async throws {
        let file = cloud("file",["before.txt"]), server = CloudServer([root,cloud("file",["before.txt"])])
        let engine = try engine(server); try await engine.synchronize()
        let source = try contents(); await server.rejectMove(true)
        do { _ = try await engine.modify(id: file.id,baseContentVersion: Data(file.etag.utf8),filename: "after.txt",parentID: nil,contents: source,progress: Progress()); XCTFail("Expected offline move") } catch {}
        XCTAssertNotNil(try catalog.recoveryOperations().first?.uploaded)
        await server.rejectMove(false)
        let moved = try await engine.modify(id: file.id,baseContentVersion: Data(file.etag.utf8),filename: "after.txt",parentID: nil,contents: source,progress: Progress())
        XCTAssertEqual(moved.id,file.id); XCTAssertEqual(moved.filename,"after.txt")
        let puts = await server.uploadCount; XCTAssertEqual(puts,1); XCTAssertTrue(try catalog.recoveryOperations().isEmpty)
    }
    func testDirectoryRenameUpdatesDescendantRemotePathsAndPinInheritance() async throws {
        let dir = cloud("dir",["before"],directory: true), file = cloud("file",["before","a.txt"])
        let server = CloudServer([root,dir,file]); let engine = try engine(server); try await engine.synchronize()
        try catalog.pin(dir.id,value: true)
        _ = try await engine.modify(id: dir.id,baseContentVersion: Data(dir.etag.utf8),filename: "after",parentID: nil,contents: nil,progress: Progress())
        XCTAssertEqual(try catalog.item(file.id).remote?.path,["after","a.txt"])
        XCTAssertEqual(try catalog.pinned(dir.id),true)
        XCTAssertEqual(ProviderItem(try catalog.item(file.id)).contentPolicy,.inherited)
        XCTAssertEqual(ProviderItem(try catalog.item(dir.id),pin: true).contentPolicy,.downloadEagerlyAndKeepDownloaded)
    }
    func testDeleteRejectsChangedRevisionAndPendingDescendantEdits() async throws {
        let dir = cloud("dir",["dir"],directory: true), file = cloud("file",["dir","a.txt"])
        let server = CloudServer([root,dir,file]); let engine = try engine(server); try await engine.synchronize()
        let paused = try self.engine(server,check: { throw SyncError.paused })
        do { _ = try await paused.modify(id: file.id,baseContentVersion: Data(file.etag.utf8),filename: nil,parentID: nil,contents: contents(),progress: Progress()); XCTFail("Expected pause") } catch SyncError.paused {}
        do { try await engine.delete(id: dir.id,baseContentVersion: Data(dir.etag.utf8),recursive: true); XCTFail("Expected pending edit guard") } catch SyncError.conflict {}
        let deletions = await server.deleteCount; XCTAssertEqual(deletions,0)
        for pending in try catalog.recoveryOperations() { try catalog.finishOperation(pending.id) }
        await server.setFiles([root,cloud("dir",["dir"],directory: true,etag: "changed"),file])
        do { try await engine.delete(id: dir.id,baseContentVersion: Data(dir.etag.utf8),recursive: true); XCTFail("Expected conflict") } catch SyncError.conflict {}
        XCTAssertNotNil(try catalog.item(file.id))
    }
    func testCrossProcessLeasePreventsOverlappingScansAndMutations() throws {
        let other = try Catalog(url: directory.appendingPathComponent("catalog.sqlite"))
        let lease = try catalog.acquireSyncLock(); defer { catalog.releaseSyncLock(lease) }
        XCTAssertThrowsError(try other.acquireSyncLock()) { error in guard case SyncError.busy = error else { return XCTFail("Expected busy") } }
    }
}
