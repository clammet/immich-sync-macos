import Foundation
@testable import ImmichCore

/// Forwards every request to the real container. The first accepted PATCH loses
/// only its client response, exercising durable resumption after an uncertain ACK.
final class TUSLostReplyProtocol: URLProtocol, @unchecked Sendable {
    final class Fault: @unchecked Sendable {
        private let lock = NSLock()
        private var dropped = false
        private var posts = 0
        private var offsets: [String] = []
        func received(_ request: URLRequest, response: HTTPURLResponse) -> Bool {
            lock.withLock {
                if request.httpMethod == "POST", request.value(forHTTPHeaderField: "Tus-Resumable") != nil { posts += 1 }
                if request.httpMethod == "PATCH" {
                    offsets.append(request.value(forHTTPHeaderField: "Upload-Offset") ?? "missing")
                    if !dropped, response.statusCode == 204 { dropped = true; return true }
                }
                return false
            }
        }
        var postCount: Int { lock.withLock { posts } }
        var patchOffsets: [String] { lock.withLock { offsets } }
    }
    static var fault: Fault?
    private var work: Task<Void,Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        work = Task {
            let session = HTTPClient.session()
            defer { session.invalidateAndCancel() }
            do {
                var forwarded = request
                if let stream = forwarded.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = Data(), buffer = [UInt8](repeating: 0,count: 8192)
                    while true {
                        let count = stream.read(&buffer,maxLength: buffer.count)
                        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                        if count == 0 { break }
                        bytes.append(contentsOf: buffer.prefix(count))
                    }
                    forwarded.httpBodyStream = nil
                    forwarded.httpBody = bytes
                }
                let (data,response) = try await session.data(for: forwarded)
                if let http = response as? HTTPURLResponse, Self.fault?.received(forwarded,response: http) == true {
                    throw URLError(.networkConnectionLost)
                }
                client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self,didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self,didFailWithError: error) }
        }
    }
    override func stopLoading() { work?.cancel() }
}
