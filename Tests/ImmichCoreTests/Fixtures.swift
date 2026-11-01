import Foundation
@testable import ImmichCore

let testSpace = CloudSpace(id: "storage$space",name: "Personal",rootID: "storage$space!root",davURL: URL(string: "https://cloud.example/dav/spaces/storage$space/")!)
func cloud(_ id: String,_ path: [String],directory: Bool = false,etag: String = "v1",checksum: String? = nil) -> CloudFile {
    CloudFile(space: testSpace,fileID: id,path: path,isDirectory: directory,etag: "\"\(etag)\"",size: directory ? nil : 4,
              permissions: "RDNVWCK",checksum: checksum)
}
func testAccount() -> Account {
    Account(serverURL: URL(string: "https://cloud.example")!,userID: "user",displayName: "User",email: "user",sessionID: "session",allowHTTP: false)
}

actor CloudServer: OpenCloudRemote {
    var files: [String:CloudFile]
    var failListing: [String]?
    var failMove = false
    var putCount = 0
    var deleteCount = 0
    var rootChange = false
    init(_ files: [CloudFile]) { self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.fileID,$0) }) }
    func setFiles(_ files: [CloudFile]) { self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.fileID,$0) }) }
    func failListing(at path: [String]?) { failListing = path }
    func rejectMove(_ reject: Bool) { failMove = reject }
    func changeRootDuringListing() { rootChange = true }
    func spaces() async throws -> [CloudSpace] { [testSpace] }
    func properties(space: CloudSpace,path: [String]) async throws -> CloudFile {
        guard let file = files.values.first(where: { $0.path == path && $0.space.id == space.id }) else { throw SyncError.missingItem }; return file
    }
    func children(_ folder: CloudFile) async throws -> [CloudFile] {
        if failListing == folder.path { throw URLError(.notConnectedToInternet) }
        let result = files.values.filter { $0.path.count == folder.path.count + 1 && $0.path.starts(with: folder.path) }
        if rootChange && folder.path.isEmpty {
            rootChange = false; var root = folder; root.etag = "\"concurrent\""; files[folder.fileID] = root
        }
        return result.sorted { $0.fileID < $1.fileID }
    }
    func download(_ file: CloudFile,into directory: URL,progress: Progress) async throws -> URL {
        guard files[file.fileID]?.etag == file.etag else { throw SyncError.conflict }
        let url = directory.appendingPathComponent(UUID().uuidString); try Data("data".utf8).write(to: url); return url
    }
    func put(parent: CloudFile,name: String,contents: URL,replacing: CloudFile?,progress: Progress) async throws -> CloudFile {
        let existing = files.values.first { $0.path == parent.path + [name] }
        if let replacing { guard existing?.fileID == replacing.fileID, existing?.etag == replacing.etag else { throw SyncError.conflict } }
        else { guard existing == nil else { throw SyncError.conflict } }
        putCount += 1
        let result = cloud(replacing?.fileID ?? UUID().uuidString,parent.path + [name],etag: "put-\(putCount)")
        files[result.fileID] = result; return result
    }
    func makeDirectory(parent: CloudFile,name: String) async throws -> CloudFile {
        guard !files.values.contains(where: { $0.path == parent.path + [name] }) else { throw SyncError.conflict }
        let result = cloud(UUID().uuidString,parent.path + [name],directory: true); files[result.fileID] = result; return result
    }
    func move(_ file: CloudFile,parent: CloudFile,name: String) async throws -> CloudFile {
        if failMove { throw URLError(.notConnectedToInternet) }
        guard files[file.fileID]?.etag == file.etag, !files.values.contains(where: { $0.path == parent.path + [name] }),
              parent.space.id == file.space.id else { throw SyncError.conflict }
        let oldPath = file.path
        for (id,var child) in files where child.path.starts(with: oldPath) {
            child.path = parent.path + [name] + child.path.dropFirst(oldPath.count); files[id] = child
        }
        return files[file.fileID]!
    }
    func delete(_ file: CloudFile) async throws {
        guard files[file.fileID]?.etag == file.etag else { throw SyncError.conflict }
        deleteCount += 1
        files = files.filter { !$0.value.path.starts(with: file.path) }
    }
    func createLink(_ file: CloudFile) async throws -> URL { URL(string: "https://cloud.example/s/link")! }
    func webURL(_ file: CloudFile) async throws -> URL { URL(string: "https://cloud.example/files/sharing")! }
}

class CatalogTestCase: XCTestCase {
    var directory: URL!
    var catalog: Catalog!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        catalog = try Catalog(url: directory.appendingPathComponent("catalog.sqlite"))
    }
    override func tearDownWithError() throws { catalog = nil; try FileManager.default.removeItem(at: directory) }
    func engine(_ server: CloudServer,check: @escaping @Sendable () throws -> Void = {}) throws -> SyncEngine {
        try SyncEngine(catalog: catalog,remote: server,account: testAccount(),checkRunning: check)
    }
    func contents(_ text: String = "local edit") throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString); try Data(text.utf8).write(to: url); return url
    }
}
import XCTest
