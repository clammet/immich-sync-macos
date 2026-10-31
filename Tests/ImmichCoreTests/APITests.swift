import Foundation
import XCTest
@testable import ImmichCore

final class APITests: XCTestCase {
    func testPasswordLoginCreatesSessionWithoutPersistedCredentialOrAPIKeyHeader() async throws {
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/auth/login")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            let body = try requestBody(request)
            XCTAssertEqual(body["email"] as? String, "test@example.com")
            XCTAssertEqual(body["password"] as? String, "password")
            return .json(["accessToken": "session-token", "userId": "owner", "name": "Test", "userEmail": "test@example.com", "shouldChangePassword": false])
        }
        let login = try await api(authenticated: false).login(email: "test@example.com", password: "password")
        XCTAssertEqual(login.accessToken, "session-token"); XCTAssertEqual(login.userId, "owner")
    }
    func testBearerSessionAuthenticatesRequestsAndLogout() async throws {
        MockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            if request.url!.path.hasSuffix("sessions") { return .json([["id": "mac-session", "current": true],["id": "phone-session", "current": false]]) }
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertTrue(request.url!.path.hasSuffix("auth/logout"))
            return .json(["successful": true])
        }
        let client = api(); let id = try await client.currentSessionID()
        XCTAssertEqual(id, "mac-session"); try await client.logout()
    }
    func testOAuthSendsStateAndPKCEAndVerifiesCallbackBeforeExchange() async throws {
        let challenge = try OAuthChallenge(); var exchanges = 0
        MockProtocol.handler = { request in
            let body = try requestBody(request)
            if request.url!.path.hasSuffix("authorize") {
                XCTAssertEqual(body["codeChallenge"] as? String, challenge.challenge)
                XCTAssertEqual(body["state"] as? String, challenge.state)
                XCTAssertEqual(body["redirectUri"] as? String, "immich-sync://oauth")
                return .json(["url": "https://identity.example.com/authorize"])
            }
            exchanges += 1
            XCTAssertEqual(body["codeVerifier"] as? String, challenge.verifier)
            return .json(["accessToken": "session-token", "userId": "owner", "name": "Test", "userEmail": "test@example.com", "shouldChangePassword": false])
        }
        let client = api(authenticated: false)
        let url = try await client.authorizeOAuth(challenge)
        XCTAssertEqual(url.host, "identity.example.com")
        do { _ = try await client.finishOAuth(callback: URL(string: "immich-sync://oauth?state=wrong&code=code")!, challenge: challenge); XCTFail("Expected invalid state") }
        catch SyncError.invalidOAuthCallback { }
        XCTAssertEqual(exchanges, 0)
        _ = try await client.finishOAuth(callback: URL(string: "immich-sync://oauth?state=\(challenge.state)&code=code")!, challenge: challenge)
        XCTAssertEqual(exchanges, 1)
    }
    func testNativeStreamUsesCurrentContractAndDecodesFragmentedRecords() async throws {
        let data = try wireLine("AssetV2", assetData(name: "café.jpg")) + wireLine("SyncCompleteV1")
        MockProtocol.handler = { request in
            if let version = versionResponse(request) { return version }
            XCTAssertEqual(request.url?.path, "/prefix/api/sync/stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let body = try requestBody(request)
            XCTAssertEqual(body["reset"] as? Bool, true)
            let types = body["types"] as! [String]
            XCTAssertTrue(types.contains("AssetsV2")); XCTAssertFalse(types.contains("AssetsV1"))
            return Reply(chunks: data.map { Data([$0]) })
        }
        let received = EventCollector()
        try await api().synchronize(reset: true, started: {}, receive: { received.append($0) })
        XCTAssertEqual(received.events.map(\.kind), [.asset,.complete])
    }
    func testStreamCommitIsBoundedAndMissingCompletionFails() async throws {
        var data = Data()
        for i in 0..<257 { data.append(try wireLine("AssetV2", assetData("asset-\(i)"), sequence: i+1)) }
        MockProtocol.handler = { request in versionResponse(request) ?? Reply(chunks: [data]) }
        let received = EventCollector()
        do { try await api().synchronize(reset: false, started: {}, receive: { received.append($0) }); XCTFail("Expected incomplete stream") }
        catch SyncError.invalidSyncStream { }
        XCTAssertEqual(received.events.count, SyncContract.batchSize)
        XCTAssertFalse(received.events.contains(where: { $0.kind == .complete }))
    }
    func testTruncatedAndUnexpectedMessagesNeverPublishCompletion() async throws {
        for data in [Data("<html>login</html>\n".utf8),try wireLine("AssetV1", assetData()),Data("{\"type\":\"SyncCompleteV1\"".utf8),
                     try wireLine("SyncCompleteV1") + wireLine("AssetV2", assetData())] {
            MockProtocol.handler = { request in versionResponse(request) ?? Reply(chunks: [data]) }
            let received = EventCollector()
            do { try await api().synchronize(reset: false, started: {}, receive: { received.append($0) }); XCTFail("Expected protocol failure") }
            catch SyncError.invalidSyncStream { }
            XCTAssertFalse(received.events.contains(where: { $0.kind == .complete }))
        }
    }
    func testResetMessageRequestsNewBootstrapWithoutAcknowledgingCompletion() async throws {
        let data = try wireLine("SyncResetV1")
        MockProtocol.handler = { request in versionResponse(request) ?? Reply(chunks: [data]) }
        let received = EventCollector()
        do { try await api().synchronize(reset: false, started: {}, receive: { received.append($0) }); XCTFail("Expected reset") }
        catch SyncError.syncReset { }
        XCTAssertTrue(received.events.isEmpty)
    }
    func testExpiredSessionStopsStreamWithoutAcknowledgeOrRetry() async throws {
        var attempts = 0
        MockProtocol.handler = { request in
            if let version = versionResponse(request) { return version }
            attempts += 1; return Reply(status: 401, mime: "application/json", chunks: [Data("{}".utf8)])
        }
        do { try await api().synchronize(reset: false, started: { XCTFail("Must not start") }, receive: { _ in XCTFail("Must not publish") }); XCTFail("Expected reauthentication") }
        catch SyncError.http(let code, _) { XCTAssertEqual(code, 401) }
        XCTAssertEqual(attempts, 1)
    }
    func testAcknowledgementsUseSessionAndExactOpaqueTokens() async throws {
        let ack = "AssetV2|00000000-0000-7000-8000-000000000001"
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/sync/ack")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            XCTAssertEqual(try requestBody(request)["acks"] as? [String], [ack])
            return Reply(status: 204, mime: "application/json", chunks: [])
        }
        try await api().acknowledge([ack])
    }
    func testDisabledTrashNeverSendsDeletion() async throws {
        var deleted = false
        MockProtocol.handler = { request in
            if request.httpMethod == "DELETE" { deleted = true }
            return request.url!.path.hasSuffix("features") ? .json(["trash": false]) : .json(["trashDays": 0])
        }
        do { try await api().trash("one"); XCTFail("Expected disabled trash") } catch SyncError.trashDisabled { }
        XCTAssertFalse(deleted)
    }
    func testThumbnailDoesNotDownloadOriginal() async throws {
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/assets/one/thumbnail")
            return Reply(status: 200, mime: "image/jpeg", chunks: [Data("preview".utf8)])
        }
        let bytes = try await api().thumbnail("one", large: false)
        XCTAssertEqual(bytes, Data("preview".utf8))
    }
    func testExactIDPathLookupUsesStructuredFiltersAndCursorAndIncludesStackedAssets() async throws {
        let first = "11111111-1111-4111-8111-111111111111", second = "22222222-2222-4222-8222-222222222222"
        var requests = 0
        MockProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/prefix/api/search/metadata")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try requestBody(request)
            XCTAssertEqual(body["size"] as? Int, 100)
            XCTAssertEqual(body["withStacked"] as? Bool, true)
            XCTAssertEqual(body["withExif"] as? Bool, false)
            XCTAssertNil(body["id"]); XCTAssertNil(body["page"]); XCTAssertNil(body["withDeleted"])
            let branches = (body["filter"] as! [String: Any])["or"] as! [[String: [String: String]]]
            XCTAssertEqual(branches.map { $0["id"]!["eq"]! }, [first,second])
            XCTAssertEqual(body["cursor"] as? String, requests == 1 ? nil : "opaque-cursor")
            let asset = makeAsset(requests == 1 ? first : second, path: requests == 1 ? "/upload/tmp.jpg" : "/data/library/2026/server.jpg")
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(asset))
            return .json(["assets": ["items": [object], "nextCursor": requests == 1 ? "opaque-cursor" as Any : NSNull()]])
        }
        let assets = try await api().assetPaths(ids: [first,second])
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(assets.map(\.originalPath), ["/upload/tmp.jpg","/data/library/2026/server.jpg"])
    }
    func testPathLookupRejectsUnexpectedDuplicateAndNonadvancingPages() async throws {
        for scenario in 0..<3 {
            var requests = 0
            MockProtocol.handler = { _ in
                requests += 1
                let id = scenario == 0 ? "unexpected" : "one"
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeAsset(id, path: "/data/file.jpg")))
                return .json(["assets": ["items": scenario == 2 ? [] : [object], "nextCursor": "same-cursor"]])
            }
            do { _ = try await api().assetPaths(ids: ["one","two"]); XCTFail("Expected invalid response") }
            catch SyncError.invalidResponse { }
            XCTAssertLessThanOrEqual(requests, 2)
        }
        MockProtocol.handler = { _ in XCTFail("Invalid batches must not reach server"); return .json([:]) }
        for ids in [[],["same","same"],(0..<101).map(String.init)] {
            do { _ = try await api().assetPaths(ids: ids); XCTFail("Expected invalid batch") }
            catch SyncError.invalidResponse { }
        }
    }
    func testReadOnlyMetadataPostRetriesTransientFailure() async throws {
        var requests = 0
        MockProtocol.handler = { _ in
            requests += 1
            if requests == 1 { return Reply(status: 503, mime: "application/json", chunks: []) }
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeAsset(path: "/data/file.jpg")))
            return .json(["assets": ["items": [object],"nextCursor": NSNull()]])
        }
        let assets = try await api().assetPaths(ids: ["one"])
        XCTAssertEqual(requests, 2); XCTAssertEqual(assets.first?.originalPath, "/data/file.jpg")
    }
    func testUploadReusesChecksumVerificationLookupToCaptureServerPath() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("new.jpg"); try Data("media".utf8).write(to: file)
        let checksum = try FileDigest.sha1(file).base64EncodedString()
        var requests: [String] = []
        MockProtocol.handler = { request in
            requests.append(request.httpMethod! + " " + request.url!.path)
            if request.httpMethod == "POST" { return .json(["id": "one","status": "created"]) }
            return .json(try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeAsset(checksum: checksum, path: "/upload/owner/temporary.jpg"))))
        }
        let asset = try await api().upload(file, filename: "new.jpg", progress: Progress())
        XCTAssertEqual(asset.originalPath, "/upload/owner/temporary.jpg")
        XCTAssertEqual(requests, ["POST /prefix/api/assets","GET /prefix/api/assets/one"])
    }
    private func api(authenticated: Bool = true) -> ImmichAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        return ImmichAPI(serverURL: URL(string: "https://photos.example.com/prefix/api")!,
            token: { authenticated ? "session-token" : nil }, session: URLSession(configuration: config))
    }
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    var bytes = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? SyncError.invalidResponse }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
}
private func versionResponse(_ request: URLRequest) -> Reply? {
    request.url?.path.hasSuffix("server/version") == true ? .json(["major": 3, "minor": 3, "patch": 5]) : nil
}
private struct Reply {
    var status = 200
    var mime = "application/jsonlines+json"
    var chunks: [Data]
    static func json(_ object: Any) -> Reply { Reply(mime: "application/json", chunks: [try! JSONSerialization.data(withJSONObject: object)]) }
}
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncEvent] = []
    var events: [SyncEvent] { lock.withLock { values } }
    func append(_ events: [SyncEvent]) { lock.withLock { values.append(contentsOf: events) } }
}
private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> Reply)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": reply.mime])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
