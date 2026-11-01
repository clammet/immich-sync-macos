import Foundation
import XCTest
@testable import ImmichCore

final class TUSUploaderTests: CatalogTestCase {
    private let digest = "a17c9aaa61e80a1bf71d0d850af4e5baa9800bbd"
    private let parent = cloud("root",[],directory: true)
    override func tearDownWithError() throws { StubProtocol.handler = nil; try super.tearDownWithError() }
    private func api(username: String = "alice") -> OpenCloudAPI {
        OpenCloudAPI(serverURL: testAccount().serverURL,username: username,token: { "token" },session: stubSession(),uploadChunkSize: 2)
    }
    private func properties(name: String = "data.bin", checksum: String? = nil) -> Data {
        dav(davRow("/dav/spaces/storage%24space/" + name,extra: "<oc:checksums><oc:checksum>SHA1:\(checksum ?? digest)</oc:checksum></oc:checksums>"))
    }
    private func headers(offset: Int, length: Int = 4) -> [String:String] {
        ["Tus-Resumable":"1.0.0","Upload-Offset":String(offset),"Upload-Length":String(length)]
    }

    func testChunkedUploadUsesExactMetadataOffsetsAndVerifiesFinalChecksum() async throws {
        let source = try contents("data"), progress = Progress()
        let name = "café #%?.bin"
        var chunks: [Data] = [], methods: [String] = []
        StubProtocol.handler = { r in
            methods.append(r.httpMethod!)
            switch r.httpMethod {
            case "POST":
                let value = try XCTUnwrap(r.value(forHTTPHeaderField: "Upload-Metadata"))
                XCTAssertTrue(value.hasPrefix("filename " + Data(name.utf8).base64EncodedString() + ","))
                XCTAssertEqual(r.value(forHTTPHeaderField: "Upload-Length"),"4")
                return (201,["Tus-Resumable":"1.0.0","Location":"/data/session"],Data())
            case "HEAD": return (200,self.headers(offset: 0),Data())
            case "PATCH":
                XCTAssertEqual(r.value(forHTTPHeaderField: "Upload-Offset"),String(chunks.count * 2))
                XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"),"application/offset+octet-stream")
                chunks.append(try XCTUnwrap(r.httpBody))
                return (204,self.headers(offset: chunks.count * 2),Data())
            case "PROPFIND": return (207,[:],self.properties(name: "caf%C3%A9%20%23%25%3F.bin"))
            default: XCTFail("Unexpected method \(r.httpMethod ?? "")"); throw SyncError.invalidResponse
            }
        }
        let file = try await api().upload(parent: parent,name: name,contents: source,replacing: nil,progress: progress)
        XCTAssertEqual(file.path,[name])
        XCTAssertEqual(chunks,[Data("da".utf8),Data("ta".utf8)])
        XCTAssertEqual(methods,["POST","HEAD","PATCH","PATCH","PROPFIND"])
        XCTAssertEqual(progress.completedUnitCount,4)
    }

    func testLostChunkResponseResumesFromServerOffsetWithNewClientAndNoSecondPOST() async throws {
        let source = try contents("data"), checkpoint = directory.appendingPathComponent("upload.json")
        var posts = 0, offset = 0, chunks: [Data] = [], loseResponse = true
        StubProtocol.handler = { r in
            switch r.httpMethod {
            case "POST": posts += 1; return (201,["Tus-Resumable":"1.0.0","Location":"/data/session"],Data())
            case "HEAD": return (200,self.headers(offset: offset),Data())
            case "PATCH":
                XCTAssertEqual(r.value(forHTTPHeaderField: "Upload-Offset"),String(offset))
                let bytes = try XCTUnwrap(r.httpBody); chunks.append(bytes); offset += bytes.count
                if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
                return (204,self.headers(offset: offset),Data())
            case "PROPFIND": return (207,[:],self.properties())
            default: throw SyncError.invalidResponse
            }
        }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected response loss") }
        catch is URLError { }
        let saved = try JSONDecoder().decode(TUSUploadCheckpoint.self,from: Data(contentsOf: checkpoint))
        XCTAssertNotNil(saved.location); XCTAssertFalse(saved.accepted)
        let mode = try FileManager.default.attributesOfItem(atPath: checkpoint.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o600)
        _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint)
        XCTAssertEqual(posts,1)
        XCTAssertEqual(chunks,[Data("da".utf8),Data("ta".utf8)])
    }

    func testCheckpointRejectsChangedSourceAndAccountBeforeNetworkAccess() async throws {
        let source = try contents("data"), checkpoint = directory.appendingPathComponent("upload.json")
        StubProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected network failure") }
        catch is URLError { }
        StubProtocol.handler = { _ in XCTFail("Checkpoint mismatch must not send a request"); throw SyncError.invalidResponse }
        do { _ = try await api(username: "other").upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected account mismatch") }
        catch SyncError.conflict { }
        try Data("edit".utf8).write(to: source)
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected source mismatch") }
        catch SyncError.conflict { }
    }

    func testLostCreationResponseIsNotReplayed() async throws {
        let source = try contents("data"), checkpoint = directory.appendingPathComponent("upload.json")
        var posts = 0
        StubProtocol.handler = { r in posts += 1; XCTAssertEqual(r.httpMethod,"POST"); throw URLError(.networkConnectionLost) }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected lost response") }
        catch is URLError { }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected ambiguous creation") }
        catch SyncError.conflict { }
        XCTAssertEqual(posts,1)
    }

    func testExpiredUploadIsPreservedWithoutStartingAnotherSession() async throws {
        let source = try contents("data"), checkpoint = directory.appendingPathComponent("upload.json")
        var posts = 0
        StubProtocol.handler = { r in
            if r.httpMethod == "POST" { posts += 1; return (201,["Tus-Resumable":"1.0.0","Location":"/data/session"],Data()) }
            XCTAssertEqual(r.httpMethod,"HEAD"); return (410,[:],Data())
        }
        for _ in 0..<2 {
            do { _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected expired session") }
            catch SyncError.conflict { }
        }
        XCTAssertEqual(posts,1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    func testForeignUploadLocationIsRejectedBeforeSendingCredentials() async throws {
        var requests = 0
        StubProtocol.handler = { r in
            requests += 1; XCTAssertEqual(r.httpMethod,"POST")
            return (201,["Tus-Resumable":"1.0.0","Location":"https://other.example/data/token"],Data())
        }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: contents("data"),replacing: nil,progress: Progress()); XCTFail("Expected foreign Location rejection") }
        catch SyncError.invalidServer { }
        XCTAssertEqual(requests,1)
    }

    func testInvalidOffsetsAndConflictsDoNotReplayUploads() async throws {
        for offset in ["-1","5","invalid"] {
            var requests = 0
            StubProtocol.handler = { r in
                requests += 1
                if r.httpMethod == "POST" { return (201,["Tus-Resumable":"1.0.0","Location":"/data/session"],Data()) }
                var headers = self.headers(offset: 0); headers["Upload-Offset"] = offset
                return (200,headers,Data())
            }
            do { _ = try await api().upload(parent: parent,name: "data.bin",contents: contents("data"),replacing: nil,progress: Progress()); XCTFail("Expected invalid offset") }
            catch SyncError.invalidResponse { }
            XCTAssertEqual(requests,2)
        }
        StubProtocol.handler = { r in
            switch r.httpMethod {
            case "POST": return (201,["Tus-Resumable":"1.0.0","Location":"/data/session"],Data())
            case "HEAD": return (200,self.headers(offset: 0),Data())
            case "PATCH": return (409,[:],Data())
            default: XCTFail("No fallback after conflict"); throw SyncError.invalidResponse
            }
        }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: contents("data"),replacing: nil,progress: Progress()); XCTFail("Expected offset conflict") }
        catch SyncError.conflict { }
    }

    func testPostUploadChecksumMismatchKeepsCheckpointAndNeverReportsSuccess() async throws {
        let checkpoint = directory.appendingPathComponent("upload.json")
        StubProtocol.handler = { r in
            switch r.httpMethod {
            case "POST": return (201,["Tus-Resumable":"1.0.0","Location":"/data/session"],Data())
            case "HEAD": return (200,self.headers(offset: 4),Data())
            case "PROPFIND": return (207,[:],self.properties(checksum: String(repeating: "0",count: 40)))
            default: throw SyncError.invalidResponse
            }
        }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: contents("data"),replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected checksum mismatch") }
        catch SyncError.conflict { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    func testCompletedUploadSurvivesMetadataFailureWithoutAnotherPOSTOrPATCH() async throws {
        let source = try contents("data"), checkpoint = directory.appendingPathComponent("upload.json")
        var metadataFails = true, methods: [String] = []
        StubProtocol.handler = { r in
            methods.append(r.httpMethod!)
            switch r.httpMethod {
            case "POST": return (201,["Tus-Resumable":"1.0.0","Location":"/data/session"],Data())
            case "HEAD": return (200,self.headers(offset: 0),Data())
            case "PATCH":
                let offset = Int(r.value(forHTTPHeaderField: "Upload-Offset")!)! + r.httpBody!.count
                return (204,self.headers(offset: offset),Data())
            case "PROPFIND":
                if metadataFails { metadataFails = false; throw URLError(.networkConnectionLost) }
                return (207,[:],self.properties())
            default: throw SyncError.invalidResponse
            }
        }
        do { _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint); XCTFail("Expected metadata failure") }
        catch is URLError { }
        let saved = try JSONDecoder().decode(TUSUploadCheckpoint.self,from: Data(contentsOf: checkpoint))
        XCTAssertTrue(saved.accepted)
        _ = try await api().upload(parent: parent,name: "data.bin",contents: source,replacing: nil,progress: Progress(),checkpointURL: checkpoint)
        XCTAssertEqual(methods,["POST","HEAD","PATCH","PATCH","PROPFIND","PROPFIND"])
    }

    func testOpenCloudZeroByteCreationStillVerifiesFinalContent() async throws {
        let emptyDigest = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        var methods: [String] = []
        StubProtocol.handler = { r in
            methods.append(r.httpMethod!)
            if r.httpMethod == "POST" {
                XCTAssertEqual(r.value(forHTTPHeaderField: "Upload-Length"),"0")
                XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"),"application/offset+octet-stream")
                return (201,["Tus-Resumable":"1.0.0"],Data())
            }
            XCTAssertEqual(r.httpMethod,"PROPFIND")
            let xml = String(decoding: self.properties(checksum: emptyDigest),as: UTF8.self)
                .replacingOccurrences(of: "<d:getcontentlength>4</d:getcontentlength>",with: "<d:getcontentlength>0</d:getcontentlength>")
            return (207,[:],Data(xml.utf8))
        }
        let file = try await api().upload(parent: parent,name: "data.bin",contents: contents(""),replacing: nil,progress: Progress())
        XCTAssertEqual(file.size,0)
        XCTAssertEqual(methods,["POST","PROPFIND"])
    }
}
