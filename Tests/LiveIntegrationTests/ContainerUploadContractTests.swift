import CryptoKit
import Foundation
import XCTest
@testable import ImmichCore

/// These are ordinary failing assertions, deliberately separate from functional
/// E2E coverage. Raw PUT requests here reproduce #866's historical baseline;
/// production uploads and every fixture use TUS exclusively.
final class ContainerUploadContractTests: ContainerTestCase {
    private struct Reply { let status: Int; let http: HTTPURLResponse; let bytes: Data }
    private let session = HTTPClient.session()

    private func call(_ method: String, url: URL, bytes: Data? = nil, headers: [String:String] = [:]) async throws -> Reply {
        var request = try api.request(url: url,method: method)
        request.httpBody = bytes
        for (name,value) in headers { request.setValue(value,forHTTPHeaderField: name) }
        let (data,response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return Reply(status: http.statusCode,http: http,bytes: data)
    }
    private func tus(name: String, bytes: Data, condition: [String:String], withBody: Bool = true) async throws -> Reply {
        let filename = folder.remote!.path + [name]
        let digest = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x",$0) }.joined()
        var headers = condition
        headers["Tus-Resumable"] = "1.0.0"
        headers["Upload-Length"] = String(bytes.count)
        headers["Upload-Metadata"] = "filename " + Data(filename.joined(separator: "/").utf8).base64EncodedString()
            + ",checksum " + Data(("SHA1 " + digest).utf8).base64EncodedString()
        if withBody { headers["Content-Type"] = "application/offset+octet-stream" }
        return try await call("POST",url: space.davURL,bytes: withBody ? bytes : nil,headers: headers)
    }
    private func report(_ label: String, statuses: [Int], expected: [Int], final: Reply,
                        finalStatus: Int = 200, finalBytes: Data? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: ["scenario":label,"statuses":statuses,
            "expectedStatuses":expected,"finalStatus":final.status,"expectedFinalStatus":finalStatus,
            "passed":statuses.sorted() == expected.sorted() && final.status == finalStatus && (finalBytes.map { $0 == final.bytes } ?? true),
            "finalContent":String(data: final.bytes,encoding: .utf8) ?? "<binary>"])
        print("PROBE " + String(decoding: data,as: UTF8.self))
    }
    private func probe866(_ label: String, transport: String, existing: Bool, empty: Bool,
                          condition: String, expected: Int) async throws {
        let name = "probe.txt", original = Data("original".utf8), bytes = empty ? Data() : Data("replacement".utf8)
        if existing { _ = try await create(name,bytes: original) }
        let headers = condition == "none" ? ["If-None-Match":"*"] : ["If-Match":condition == "star" ? "*" : "\"outdated\""]
        let response: Reply
        if transport == "TUS" { response = try await tus(name: name,bytes: bytes,condition: headers) }
        else { response = try await call("PUT",url: folder.remote!.url.appendingPathComponent(name),bytes: bytes,headers: headers) }
        let final = try await call("GET",url: folder.remote!.url.appendingPathComponent(name))
        try report(label,statuses: [response.status],expected: [expected],final: final,
                   finalStatus: expected == 412 && !existing ? 404 : 200,
                   finalBytes: expected == 412 ? (existing ? original : nil) : bytes)
        XCTAssertEqual(response.status,expected,label)
        if expected == 412 {
            XCTAssertEqual(final.status,existing ? 200 : 404,label)
            if existing { XCTAssertEqual(final.bytes,original,"A rejected condition must preserve the existing bytes") }
        } else {
            XCTAssertEqual(final.status,200,label)
            XCTAssertEqual(final.bytes,bytes,"A successful upload must publish the new content")
        }
    }

    func test866TUSCreateOnlyCannotOverwriteExistingFile() async throws {
        try await probe866("866 TUS create-only occupied",transport: "TUS",existing: true,empty: false,condition: "none",expected: 412)
    }
    func test866TUSCreateOnlyCannotEmptyExistingFile() async throws {
        try await probe866("866 TUS empty create-only occupied",transport: "TUS",existing: true,empty: true,condition: "none",expected: 412)
    }
    func test866TUSIfMatchMissingFileIsRejected() async throws {
        try await probe866("866 TUS missing If-Match",transport: "TUS",existing: false,empty: false,condition: "stale",expected: 412)
    }
    func test866TUSEmptyIfMatchMissingFileIsRejected() async throws {
        try await probe866("866 TUS empty missing If-Match",transport: "TUS",existing: false,empty: true,condition: "stale",expected: 412)
    }
    func test866TUSWildcardIfMatchAcceptsExistingFile() async throws {
        try await probe866("866 TUS wildcard If-Match",transport: "TUS",existing: true,empty: false,condition: "star",expected: 201)
    }
    func test866TUSStaleIfMatchRejectsExistingFile() async throws {
        try await probe866("866 TUS stale If-Match",transport: "TUS",existing: true,empty: false,condition: "stale",expected: 412)
    }
    func test866TUSEmptyStaleIfMatchRejectsExistingFile() async throws {
        try await probe866("866 TUS empty stale If-Match",transport: "TUS",existing: true,empty: true,condition: "stale",expected: 412)
    }
    func test866PUTCreateOnlyBaseline() async throws {
        try await probe866("866 PUT create-only occupied",transport: "PUT",existing: true,empty: false,condition: "none",expected: 412)
    }
    func test866PUTEmptyCreateOnlyBaseline() async throws {
        try await probe866("866 PUT empty create-only occupied",transport: "PUT",existing: true,empty: true,condition: "none",expected: 412)
    }
    func test866PUTEmptyIfMatchMissingBaseline() async throws {
        try await probe866("866 PUT empty missing If-Match",transport: "PUT",existing: false,empty: true,condition: "stale",expected: 412)
    }
    func test866PUTIfMatchMissingWithBodyBaseline() async throws {
        try await probe866("866 PUT missing If-Match",transport: "PUT",existing: false,empty: false,condition: "stale",expected: 412)
    }
    func test866PUTWildcardIfMatchBaseline() async throws {
        try await probe866("866 PUT wildcard If-Match",transport: "PUT",existing: true,empty: false,condition: "star",expected: 204)
    }

    func test959ConcurrentCreationWithUploadHasAtMostOneWinner() async throws {
        // Match the upstream report's creation-with-upload route, ten rounds.
        for round in 1...10 {
            let name = "race-\(round).txt"
            let original = try await create(name,bytes: Data("original".utf8))
            let condition = ["If-Match":try XCTUnwrap(original.remote?.etag)]
            async let first = tus(name: name,bytes: Data("writer A".utf8),condition: condition)
            async let second = tus(name: name,bytes: Data("writer B".utf8),condition: condition)
            let replies = try await [first,second]
            let final = try await call("GET",url: folder.remote!.url.appendingPathComponent(name))
            let statuses = replies.map(\.status)
            try report("959 creation-with-upload round \(round)",statuses: statuses,expected: [201,412],final: final)
            XCTAssertEqual(statuses.filter { $0 == 201 }.count,1,"One upload may commit the shared base revision: \(statuses)")
            XCTAssertEqual(statuses.filter { $0 == 412 }.count,1,"The other upload must report a revision conflict")
        }
    }

    func test959SeparateSessionsRecheckRevisionAtFinalPATCH() async throws {
        let name = "two-sessions.txt", a = Data("writer A".utf8), b = Data("writer B".utf8)
        let original = try await create(name,bytes: Data("original".utf8))
        let condition = ["If-Match":try XCTUnwrap(original.remote?.etag)]
        // Both POSTs explicitly succeed before either PATCH. This deterministically
        // exercises the time between the initial Stat and final commit.
        let first = try await tus(name: name,bytes: a,condition: condition,withBody: false)
        let second = try await tus(name: name,bytes: b,condition: condition,withBody: false)
        XCTAssertEqual(first.status,201); XCTAssertEqual(second.status,201)
        let firstURL = try XCTUnwrap(URL(string: XCTUnwrap(first.http.value(forHTTPHeaderField: "Location"))))
        let secondURL = try XCTUnwrap(URL(string: XCTUnwrap(second.http.value(forHTTPHeaderField: "Location"))))
        let headers = ["Tus-Resumable":"1.0.0","Upload-Offset":"0","Content-Type":"application/offset+octet-stream"]
        async let one = call("PATCH",url: firstURL,bytes: a,headers: headers)
        async let two = call("PATCH",url: secondURL,bytes: b,headers: headers)
        let replies = try await [one,two]
        let statuses = replies.map(\.status)
        let final = try await call("GET",url: folder.remote!.url.appendingPathComponent(name))
        try report("959 separate sessions final PATCH",statuses: statuses,expected: [204,412],final: final)
        XCTAssertEqual(statuses.filter { $0 == 204 }.count,1,"Only one session may commit: \(statuses)")
        XCTAssertEqual(statuses.filter { $0 == 412 }.count,1,"The second session must recheck its base revision")
    }
}
