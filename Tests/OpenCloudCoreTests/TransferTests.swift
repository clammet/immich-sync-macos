import Foundation
import Network
import XCTest
@testable import OpenCloudCore

/// A loopback HTTP peer tests URLSession's real disk-backed transfer and redirect behavior.
private final class HTTPPeer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "transfer-test-peer")
    let response: Data
    private let lock = NSLock()
    private var requests: [String] = []
    private init(response: Data) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",port: .any)
        listener = try NWListener(using: parameters)
    }
    static func start(status: Int = 200,body: String = "data",headers: String = "ETag: \"v1\"\r\n") async throws -> HTTPPeer {
        let peer = try HTTPPeer(response: Data("HTTP/1.1 \(status) Response\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\(headers)\r\n\(body)".utf8))
        peer.listener.newConnectionHandler = { [weak peer] connection in
            guard let peer else { connection.cancel(); return }
            connection.start(queue: peer.queue)
            peer.read(connection,bytes: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            peer.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: peer.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): peer.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            peer.listener.start(queue: peer.queue)
        }
        return peer
    }
    private func read(_ connection: NWConnection,bytes: Data) {
        connection.receive(minimumIncompleteLength: 1,maximumLength: 8192) { [weak self] next,_,complete,error in
            guard let self else { connection.cancel(); return }
            let bytes = bytes + (next ?? Data())
            if let text = String(data: bytes,encoding: .utf8), text.contains("\r\n\r\n") {
                self.lock.withLock { self.requests.append(text) }
                connection.send(content: self.response,completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil { connection.cancel() }
            else { self.read(connection,bytes: bytes) }
        }
    }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    var received: [String] { lock.withLock { requests } }
    func stop() { listener.cancel() }
}
final class TransferTests: XCTestCase {
    func testOnDemandDownloadUsesConditionalDiskTransferAndChecksIntegrity() async throws {
        let peer = try await HTTPPeer.start(); defer { peer.stop() }
        let api = OpenCloudAPI(serverURL: peer.url,username: "test",token: { "test-token" })
        let space = CloudSpace(id: "space",name: "Space",rootID: "root",davURL: peer.url.appendingPathComponent("dav"))
        let file = CloudFile(space: space,fileID: "file",path: ["document.bin"],isDirectory: false,etag: "\"v1\"",size: 4,checksum: "a17c9aaa61e80a1bf71d0d850af4e5baa9800bbd")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await api.download(file,into: directory,progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(try Data(contentsOf: url),Data("data".utf8))
        XCTAssertTrue(peer.received.first?.lowercased().contains("if-match: \"v1\"") == true)
        var wrong = file; wrong.checksum = String(repeating: "0",count: 40)
        do { _ = try await api.download(wrong,into: directory,progress: Progress()); XCTFail("Expected integrity failure") } catch SyncError.invalidResponse {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count,1)
    }
    func testDownloadRefusesRedirectBeforeFollowingForeignLocation() async throws {
        let peer = try await HTTPPeer.start(status: 302,body: "",headers: "Location: https://other.example/private\r\n"); defer { peer.stop() }
        let api = OpenCloudAPI(serverURL: peer.url,username: "test",token: { "test-token" })
        let space = CloudSpace(id: "space",name: "Space",rootID: "root",davURL: peer.url)
        let file = CloudFile(space: space,fileID: "file",path: ["a.txt"],isDirectory: false,etag: "\"v1\"")
        do { _ = try await api.download(file,into: FileManager.default.temporaryDirectory,progress: Progress()); XCTFail("Expected redirect rejection") }
        catch SyncError.http(302,_) {}
        XCTAssertEqual(peer.received.count,1)
    }
}
