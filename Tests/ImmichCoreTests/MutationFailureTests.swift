import Foundation
import XCTest
@testable import ImmichCore

final class MutationFailureTests: CatalogTestCase {
    override func tearDownWithError() throws { StubProtocol.handler = nil; try super.tearDownWithError() }

    func testOutcomeWrappingPreservesAuthenticationCancellationAndTransportCauses() throws {
        let auth = MutationFailure(outcome: .rejected,underlyingError: SyncError.http(401,retryAfter: 12))
        let nested = MutationFailure(outcome: .uncertain,underlyingError: auth)
        guard case SyncError.http(401,let retryAfter) = MutationFailure.cause(of: nested) else { return XCTFail("Expected authentication error") }
        XCTAssertEqual(retryAfter,12)
        XCTAssertTrue(MutationFailure.cause(of: MutationFailure(outcome: .interrupted,underlyingError: CancellationError())) is CancellationError)
        let network = MutationFailure(outcome: .interrupted,underlyingError: URLError(.networkConnectionLost))
        XCTAssertEqual((MutationFailure.cause(of: network) as? URLError)?.code,.networkConnectionLost)
    }

    func testMutationResponseRejectionAndLostAcknowledgementHaveDifferentOutcomes() async throws {
        let api = OpenCloudAPI(serverURL: testAccount().serverURL,username: "alice",token: { "token" },session: stubSession())
        let file = cloud("file",["file.txt"])
        StubProtocol.handler = { _ in (412,[:],Data()) }
        do { try await api.delete(file); XCTFail("Expected rejection") }
        catch {
            XCTAssertEqual((error as? MutationFailure)?.outcome,.rejected)
            XCTAssertEqual((error as? MutationFailure)?.recoveryAvailable,false)
            guard case SyncError.conflict = MutationFailure.cause(of: error) else { throw error }
        }
        StubProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        do { try await api.delete(file); XCTFail("Expected lost acknowledgement") }
        catch {
            XCTAssertEqual((error as? MutationFailure)?.outcome,.uncertain)
            XCTAssertEqual((error as? MutationFailure)?.recoveryAvailable,false)
            guard MutationFailure.cause(of: error) is URLError else { throw error }
        }
    }

    func testServerRejectionIsPersistedWithTheExistingRecoveryCopy() async throws {
        let root = cloud("root",[],directory: true)
        _ = try catalog.commit(root,parentID: ItemRecord.rootID)
        StubProtocol.handler = { r in
            if r.httpMethod == "PROPFIND" { return (207,[:],dav(davRow("/dav/spaces/storage%24space/",id: "root",folder: true))) }
            XCTAssertEqual(r.httpMethod,"POST")
            return (412,[:],Data())
        }
        let api = OpenCloudAPI(serverURL: testAccount().serverURL,username: "alice",token: { "token" },session: stubSession())
        let engine = try SyncEngine(catalog: catalog,remote: api,account: testAccount())
        do { _ = try await engine.create(parentID: root.id,filename: "edit.txt",directory: false,contents: contents("edit"),progress: Progress()); XCTFail("Expected rejection") }
        catch { XCTAssertEqual((error as? MutationFailure)?.outcome,.rejected) }
        let reopened = try Catalog(url: directory.appendingPathComponent("catalog.sqlite"))
        let edit = try XCTUnwrap(reopened.recoveryOperations().first)
        let manifest = try JSONDecoder().decode(PendingEdit.self,from: Data(contentsOf: reopened.localDirectory.appendingPathComponent(edit.id).appendingPathComponent("operation.json")))
        XCTAssertEqual(manifest.issue?.outcome,.rejected)
        XCTAssertEqual(manifest.issue?.recoveryAvailable,true)
        XCTAssertEqual(try reopened.state("status",as: SyncStatus.self)?.mutationOutcome,.rejected)
        XCTAssertEqual(try reopened.recoveryOperations().count,1)
        let bytes = reopened.localDirectory.appendingPathComponent(edit.id).appendingPathComponent("content/edit.txt")
        XCTAssertEqual(try Data(contentsOf: bytes),Data("edit".utf8))
        // A successful metadata scan does not erase the pending operation's diagnosis.
        let snapshot = try catalog.beginSnapshot()
        try catalog.stage([.record(root,parentID: ItemRecord.rootID)],token: snapshot)
        try catalog.publishSnapshot(snapshot)
        XCTAssertEqual(try reopened.recoveryOperations().first?.issue?.outcome,.rejected)
    }

    func testOlderRecoveryAndCheckpointRecordsDecodeWithoutOutcomeFields() throws {
        let edit = PendingEdit(id: "old",sourceID: nil,parentID: "root",filename: "old.txt",hash: nil,baseVersion: nil,createdAt: Date())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String:Any])
        object.removeValue(forKey: "issue")
        let decoded = try JSONDecoder().decode(PendingEdit.self,from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.issue)
        let checkpoint = try JSONDecoder().decode(TUSUploadCheckpoint.self,from: Data("{\"fingerprint\":\"old\",\"accepted\":false}".utf8))
        XCTAssertNil(checkpoint.completionAttempted)
        let status = try JSONDecoder().decode(SyncStatus.self,from: Data("{\"fileCount\":0,\"folderCount\":0,\"syncing\":false}".utf8))
        XCTAssertNil(status.mutationOutcome)
    }
}
