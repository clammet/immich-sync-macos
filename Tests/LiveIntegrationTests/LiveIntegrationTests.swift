import Foundation
import XCTest
@testable import ImmichCore

/// Mutates only a UUID-named directory on an explicitly enabled disposable loopback server.
final class LiveIntegrationTests: XCTestCase {
    func testOpenCloudGenericFilesConditionalConflictsAndRecovery() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENCLOUD_INTEGRATION"] == "1" else { throw XCTSkip("Set OPENCLOUD_INTEGRATION=1 and disposable loopback server credentials") }
        let address = try ServerAddress(try XCTUnwrap(env["OPENCLOUD_TEST_SERVER"]),allowHTTP: true)
        guard ["127.0.0.1","localhost","::1"].contains(address.apiURL.host ?? "") else { throw XCTSkip("Live mutations require a disposable loopback server") }
        let username = try XCTUnwrap(env["OPENCLOUD_TEST_USERNAME"]), token = try XCTUnwrap(env["OPENCLOUD_TEST_TOKEN"])
        let api = OpenCloudAPI(serverURL: address.apiURL,username: username,token: { token })
        let second = OpenCloudAPI(serverURL: address.apiURL,username: username,token: { token })
        let spaces = try await api.spaces(), user = try await api.user()
        let space = try XCTUnwrap(spaces.first { space in env["OPENCLOUD_TEST_SPACE"].map { $0 == space.id } ?? true })
        let root = try await api.properties(space: space,path: [])
        let folder = try await api.makeDirectory(parent: root,name: "macos-integration-" + UUID().uuidString)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let content = work.appendingPathComponent("ordinary.txt"); try Data("first version".utf8).write(to: content)
            let file = try await api.put(parent: folder,name: "ordinary.txt",contents: content,replacing: nil,progress: Progress())
            let destination = try await api.download(file,into: work,progress: Progress())
            XCTAssertEqual(try Data(contentsOf: destination),Data("first version".utf8))
            try Data("second client".utf8).write(to: content)
            let newer = try await second.put(parent: folder,name: "ordinary.txt",contents: content,replacing: file,progress: Progress())
            let catalog = try Catalog(url: work.appendingPathComponent("catalog.sqlite"))
            _ = try catalog.commit(folder,parentID: ItemRecord.rootID); _ = try catalog.commit(file,parentID: folder.id)
            let account = Account(serverURL: address.apiURL,userID: user.id,displayName: username,email: username,sessionID: UUID().uuidString,allowHTTP: true)
            let engine = try SyncEngine(catalog: catalog,remote: api,account: account)
            try Data("offline edit".utf8).write(to: content)
            do { _ = try await engine.modify(id: file.id,baseContentVersion: Data(file.etag.utf8),filename: nil,parentID: nil,contents: content,progress: Progress()); XCTFail("Expected server conflict") } catch SyncError.conflict {}
            XCTAssertEqual(try catalog.recoveryOperations().count,1)
            do { _ = try await api.put(parent: folder,name: "ordinary.txt",contents: content,replacing: file,progress: Progress()); XCTFail("Expected conditional write rejection") } catch SyncError.conflict {}
            do { try await api.delete(file); XCTFail("Expected conditional delete rejection") } catch SyncError.conflict {}
            let moved = try await api.move(newer,parent: folder,name: "renamed.txt")
            XCTAssertEqual(moved.fileID,file.fileID)
            let link = try await api.createLink(moved); XCTAssertNotNil(link.host)
            let latestFolder = try await api.properties(space: space,path: folder.path)
            try await api.delete(latestFolder)
        } catch {
            if let latest = try? await api.properties(space: space,path: folder.path) { try? await api.delete(latest) }
            throw error
        }
    }
}
