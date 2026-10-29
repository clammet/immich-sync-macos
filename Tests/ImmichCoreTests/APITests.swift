import Foundation
import XCTest
@testable import ImmichCore

final class APITests: XCTestCase {
    func testLegacySearchFollowsEveryPageAndSendsAPIKey() async throws {
        var pages: [Int] = []
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/search/metadata")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
            let body = try self.requestBody(request)
            let page = body["page"] as! Int; pages.append(page)
            XCTAssertEqual(body["withStacked"] as? Bool, true)
            return (200, try self.response(items: [makeAsset("\(page)")], nextPage: page == 1 ? "2" : nil, total: 2))
        }
        let assets = try await api(major: 2, minor: 5).search()
        XCTAssertEqual(Set(assets.map(\.id)), ["1", "2"])
        XCTAssertEqual(pages, [1, 2])
    }

    func testCurrentSearchUsesOpaqueCursorAndAlbumFilter() async throws {
        var count = 0
        MockProtocol.handler = { request in
            count += 1
            let body = try self.requestBody(request)
            XCTAssertNil(body["page"])
            if count == 2 { XCTAssertEqual(body["cursor"] as? String, "opaque-token") }
            let filter = body["filter"] as! [String: Any]
            XCTAssertEqual((filter["albumIds"] as? [String: [String]])?["any"], ["album-id"])
            return (200, try self.response(items: [makeAsset("\(count)")], nextCursor: count == 1 ? "opaque-token" : nil, total: 2))
        }
        let assets = try await api(major: 3, minor: 2).search(albumID: "album-id")
        XCTAssertEqual(assets.count, 2); XCTAssertEqual(count, 2)
    }

    func testRepeatedCursorFailsInsteadOfPublishingPartialLibrary() async throws {
        MockProtocol.handler = { _ in (200, try self.response(items: [makeAsset("one")], nextCursor: "loop", total: 3)) }
        do { _ = try await api(major: 3, minor: 2).search(); XCTFail("Expected incomplete listing") }
        catch SyncError.incompleteListing { }
    }

    func testPermissionFailureDoesNotRetry() async throws {
        var count = 0
        MockProtocol.handler = { _ in count += 1; return (403, Data("{}".utf8)) }
        do { _ = try await api(major: 2, minor: 5).search(); XCTFail("Expected permission failure") }
        catch SyncError.http(let code, _) { XCTAssertEqual(code, 403) }
        XCTAssertEqual(count, 1)
    }

    func testDisabledTrashNeverSendsDeletion() async throws {
        var deleted = false
        MockProtocol.handler = { request in
            if request.httpMethod == "DELETE" { deleted = true }
            return (200, Data((request.url!.path.hasSuffix("features") ? "{\"trash\":false}" : "{\"trashDays\":0}").utf8))
        }
        do { try await api(major: 2, minor: 5).trash("one"); XCTFail("Expected disabled trash error") }
        catch SyncError.trashDisabled { }
        XCTAssertFalse(deleted)
    }

    func testAssetParserAcceptsOptionalMetadataAndVideoDurationDifferences() throws {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeAsset("video"))) as! [String: Any]
        value["type"] = "VIDEO"; value["duration"] = 1234; value["isOffline"] = nil
        let result = try JSONDecoder().decode(Asset.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(result.type, "VIDEO"); XCTAssertNil(result.isOffline); XCTAssertTrue(result.isMutable)
    }

    func testThumbnailUsesDerivativeWithoutFetchingOriginal() async throws {
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/prefix/api/assets/one/thumbnail")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "thumbnail")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/*")
            return (200, Data("small-preview".utf8))
        }
        let bytes = try await api(major: 2, minor: 5).thumbnail("one", large: false)
        XCTAssertEqual(bytes, Data("small-preview".utf8))
    }

    private func api(major: Int, minor: Int) -> ImmichAPI {
        let account = Account(serverURL: URL(string: "https://photos.example.com/prefix/api")!, userID: "owner", displayName: "Test", serverMajor: major, serverMinor: minor, allowHTTP: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return ImmichAPI(account: account, apiKey: "test-key", session: URLSession(configuration: config))
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
    private func response(items: [Asset], nextPage: String? = nil, nextCursor: String? = nil, total: Int) throws -> Data {
        let values = try items.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        return try JSONSerialization.data(withJSONObject: ["assets": ["items": values, "nextPage": nextPage as Any? ?? NSNull(),
            "nextCursor": nextCursor as Any? ?? NSNull(), "total": total]])
    }
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
