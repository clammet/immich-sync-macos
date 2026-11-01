import Foundation
import XCTest
@testable import ImmichCore

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int,[String:String],Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var normalized = request
            if normalized.httpBody == nil, let stream = normalized.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(), buffer = [UInt8](repeating: 0,count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer,maxLength: buffer.count)
                    guard count > 0 else { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
                normalized.httpBody = bytes
            }
            let (status,headers,bytes) = try Self.handler!(normalized)
            client?.urlProtocol(self,didReceive: HTTPURLResponse(url: request.url!,statusCode: status,httpVersion: nil,headerFields: headers)!,cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self,didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError: error) }
    }
    override func stopLoading() {}
}
func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]; return URLSession(configuration: config)
}
func davRow(_ href: String, id: String = "file", folder: Bool = false, etag: String = "v1", extra: String = "") -> String {
    """
    <d:response><d:href>\(href)</d:href><d:propstat><d:prop><oc:fileid>\(id)</oc:fileid><d:getetag>&quot;\(etag)&quot;</d:getetag><d:resourcetype>\(folder ? "<d:collection/>" : "")</d:resourcetype><d:getcontentlength>4</d:getcontentlength><oc:permissions>RDNVWCK</oc:permissions>\(extra)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    """
}
func dav(_ rows: String) -> Data { Data("<d:multistatus xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\">\(rows)</d:multistatus>".utf8) }

final class APITests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil }
    func testDAVDecodesNamespacesPathsAndChecksumsWithoutTreatingNamesAsURLs() throws {
        let row = davRow("/dav/spaces/storage%24space/a%20%23%25%3F.txt",extra: "<oc:checksums><oc:checksum>SHA1:abcd MD5:other ADLER32:other</oc:checksum></oc:checksums>")
        let file = try XCTUnwrap(DAVDecoder.decode(dav(row),space: testSpace,requestedURL: testSpace.davURL).first)
        XCTAssertEqual(file.path,["a #%?.txt"]); XCTAssertEqual(file.fileID,"file")
        XCTAssertEqual(file.etag,"\"v1\""); XCTAssertEqual(file.checksum,"abcd")
        XCTAssertEqual(file.url.lastPathComponent,"a #%?.txt"); XCTAssertNil(file.url.query); XCTAssertNil(file.url.fragment)
    }
    func testDAVRejectsPartialFailuresForeignRootsEncodedSeparatorsAndMalformedXML() throws {
        let root = "/dav/spaces/storage%24space/"
        for data in [
            dav(davRow(root + "a") + "<d:response><d:href>\(root)b</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response>"),
            dav(davRow("https://other.example/dav/spaces/storage%24space/a")),
            dav(davRow("/dav/spaces/other/a")),
            dav(davRow(root + "a%2Fb")),
            dav(davRow(root + "%2E%2E/secret")),
            Data("<d:multistatus".utf8),
            dav(davRow(root + "a").replacingOccurrences(of: "<d:resourcetype></d:resourcetype>",with: "")),
            dav(davRow(root + "a").replacingOccurrences(of: "&quot;v1&quot;",with: "W/&quot;weak&quot;"))
        ] { XCTAssertThrowsError(try DAVDecoder.decode(data,space: testSpace,requestedURL: testSpace.davURL)) }
    }
    func testOptionalMissingDAVPropertyDoesNotDiscardSuccessfulProperties() throws {
        let row = davRow("/dav/spaces/storage%24space/a").replacingOccurrences(of: "</d:response>",with: "<d:propstat><d:prop><oc:checksums/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>")
        XCTAssertEqual(try DAVDecoder.decode(dav(row),space: testSpace,requestedURL: testSpace.davURL).count,1)
    }
    func testSpaceDiscoveryFollowsPaginationAndNeverSendsCredentialsToForeignNextLink() async throws {
        var count = 0
        StubProtocol.handler = { r in
            count += 1
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"),"Basic " + Data("alice:app-token".utf8).base64EncodedString())
            let next = count == 1 ? ",\"@odata.nextLink\":\"?page=2\"" : ",\"@odata.nextLink\":\"https://attacker.example/graph/page\""
            return (200,[:],Data("{\"value\":[]\(next)}".utf8))
        }
        let api = OpenCloudAPI(serverURL: URL(string: "https://cloud.example")!,username: "alice",token: { "app-token" },session: stubSession())
        do { _ = try await api.spaces(); XCTFail("Expected foreign pagination rejection") } catch {}
        XCTAssertEqual(count,2)
        XCTAssertThrowsError(try api.request(url: URL(string: "https://attacker.example/dav")!))
    }
    func testRemoteUnicodeCollisionsRemainDistinctBeforeLocalNameDisambiguation() async throws {
        StubProtocol.handler = { _ in
            let root = "/dav/spaces/storage%24space/"
            return (207,[:],dav(davRow(root,id: "root",folder: true) + davRow(root + "caf%C3%A9.jpg",id: "one") + davRow(root + "cafe%CC%81.jpg",id: "two")))
        }
        let api = OpenCloudAPI(serverURL: URL(string: "https://cloud.example")!,username: "test",token: { "token" },session: stubSession())
        let children = try await api.children(cloud("root",[],directory: true))
        XCTAssertEqual(children.count,2)
        XCTAssertFalse(RemotePath.equal(children[0].path,children[1].path))
    }
    func testDAVMutationsUseServerPreconditionsAndNoOverwrite() async throws {
        let api = OpenCloudAPI(serverURL: URL(string: "https://cloud.example")!,username: "alice",token: { "token" },session: stubSession())
        let parent = cloud("root",[],directory: true), file = cloud("file",["old.txt"])
        var methods: [String] = []
        StubProtocol.handler = { r in
            methods.append(r.httpMethod!)
            switch r.httpMethod {
            case "MOVE":
                XCTAssertEqual(r.value(forHTTPHeaderField: "If-Match"),"\"v1\"")
                XCTAssertEqual(r.value(forHTTPHeaderField: "Overwrite"),"F")
                XCTAssertEqual(r.value(forHTTPHeaderField: "Destination"),testSpace.davURL.appendingPathComponent("new.txt").absoluteString)
                return (201,[:],Data())
            case "PROPFIND": return (207,[:],dav(davRow("/dav/spaces/storage%24space/new.txt")))
            case "DELETE": XCTAssertEqual(r.value(forHTTPHeaderField: "If-Match"),"\"v1\""); return (412,[:],Data())
            case "MKCOL": XCTAssertEqual(r.value(forHTTPHeaderField: "If-None-Match"),"*"); return (405,[:],Data())
            default: XCTFail("Unexpected method"); return (500,[:],Data())
            }
        }
        let moved = try await api.move(file,parent: parent,name: "new.txt"); XCTAssertEqual(moved.fileID,"file")
        do { try await api.delete(file); XCTFail("Expected stale delete") } catch SyncError.conflict {}
        do { _ = try await api.makeDirectory(parent: parent,name: "exists"); XCTFail("Expected collision") } catch SyncError.conflict {}
        XCTAssertEqual(methods,["MOVE","PROPFIND","DELETE","MKCOL"])
    }
    func testPutCreatesConditionallyAndNeverReplaysRejectedMutations() async throws {
        let api = OpenCloudAPI(serverURL: URL(string: "https://cloud.example")!,username: "alice",token: { "token" },session: stubSession())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("data".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        var requests = 0
        StubProtocol.handler = { r in
            requests += 1; XCTAssertEqual(r.httpMethod,"PUT")
            XCTAssertEqual(r.value(forHTTPHeaderField: "If-None-Match"),"*")
            XCTAssertEqual(r.value(forHTTPHeaderField: "OC-Checksum"),"SHA1:a17c9aaa61e80a1bf71d0d850af4e5baa9800bbd")
            return (412,[:],Data())
        }
        do { _ = try await api.put(parent: cloud("root",[],directory: true),name: "data.bin",contents: url,replacing: nil,progress: Progress()); XCTFail("Expected collision") } catch SyncError.conflict {}
        XCTAssertEqual(requests,1)
        StubProtocol.handler = { r in
            XCTAssertEqual(r.value(forHTTPHeaderField: "If-Match"),"\"v1\""); XCTAssertNil(r.value(forHTTPHeaderField: "If-None-Match"))
            return (412,[:],Data())
        }
        do { _ = try await api.put(parent: cloud("root",[],directory: true),name: "data.bin",contents: url,replacing: cloud("file",["data.bin"]),progress: Progress()); XCTFail("Expected stale update") } catch SyncError.conflict {}
    }
    func testCreateSharingLinksForFilesAndSpaceRootsUsesLibreGraph() async throws {
        let api = OpenCloudAPI(serverURL: URL(string: "https://cloud.example")!,username: "alice",token: { "token" },session: stubSession())
        var paths: [String] = []
        StubProtocol.handler = { r in
            paths.append(r.url!.path); XCTAssertEqual(r.httpMethod,"POST")
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String:String]; XCTAssertEqual(body["type"],"view")
            return (200,[:],Data("{\"link\":{\"webUrl\":\"https://cloud.example/s/example\"}}".utf8))
        }
        _ = try await api.createLink(cloud("file",["file.txt"])); _ = try await api.createLink(cloud("root",[],directory: true))
        XCTAssertEqual(paths,["/graph/v1beta1/drives/storage$space/items/file/createLink","/graph/v1beta1/drives/storage$space/root/createLink"])
    }
}
