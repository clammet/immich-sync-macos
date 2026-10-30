import Foundation

public protocol ImmichRemote: Sendable {
    func synchronize(reset: Bool, started: @escaping @Sendable () async throws -> Void,
                     receive: @escaping @Sendable ([SyncEvent]) async throws -> Void) async throws
    func acknowledge(_ acks: [String]) async throws
    func mediaTypes() async throws -> MediaTypes
    func asset(_ id: String) async throws -> Asset
    func upload(_ file: URL, filename: String, progress: Progress) async throws -> Asset
    func download(_ asset: Asset, into directory: URL, progress: Progress) async throws -> URL
    func thumbnail(_ assetID: String, large: Bool) async throws -> Data
    func createAlbum(name: String) async throws -> Album
    func renameAlbum(_ id: String, name: String) async throws -> Album
    func deleteAlbum(_ id: String) async throws
    func add(_ assetID: String, to albumID: String) async throws
    func remove(_ assetID: String, from albumID: String) async throws
    func copyAssociations(from sourceID: String, to targetID: String) async throws
    func trash(_ assetID: String) async throws
}

private final class ConnectionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class TransferDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress.totalUnitCount = max(1, totalBytesExpectedToSend)
        progress.completedUnitCount = totalBytesSent
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Replaying a mutation through a redirect is ambiguous, even on the same host.
        completionHandler(nil)
    }
}

public final class ImmichAPI: ImmichRemote, @unchecked Sendable {
    public let serverURL: URL
    private let token: @Sendable () throws -> String?
    private let session: URLSession

    public init(serverURL: URL, token: @escaping @Sendable () throws -> String? = { nil }, session: URLSession? = nil) {
        self.serverURL = serverURL; self.token = token
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 24 * 60 * 60
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config, delegate: ConnectionDelegate(), delegateQueue: nil)
        }
    }

    public func version() async throws -> ServerVersion { try await json("server/version") }
    public func mediaTypes() async throws -> MediaTypes { try await json("server/media-types") }

    public func request(_ path: String, method: String = "GET", body: Data? = nil,
                        query: [URLQueryItem] = []) throws -> URLRequest {
        var url = serverURL
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw SyncError.invalidServer }
        if !query.isEmpty { components.queryItems = query }
        guard let finalURL = components.url else { throw SyncError.invalidServer }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method; request.httpBody = body
        if let token = try token() { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ImmichSync/0.2.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("Immich Sync", forHTTPHeaderField: "deviceModel")
        request.setValue("macOS", forHTTPHeaderField: "deviceType")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func data(_ request: URLRequest, retry: Bool = true) async throws -> Data {
        for attempt in 0..<4 {
            do {
                let (data, response) = try await session.data(for: request)
                try Self.validate(response)
                return data
            } catch {
                guard retry, attempt < 3, Self.isTransient(error) else { throw error }
                let delay: TimeInterval
                if case SyncError.http(_, let retryAfter) = error { delay = retryAfter ?? pow(2, Double(attempt)) }
                else { delay = pow(2, Double(attempt)) }
                try await Task.sleep(nanoseconds: UInt64(min(30, max(0.1, delay)) * 1_000_000_000))
            }
        }
        throw SyncError.invalidResponse
    }

    public static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { throw SyncError.missingItem }
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw SyncError.http(response.statusCode, retryAfter: retry)
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case SyncError.http(let status, _) = error { return status == 429 || [500, 502, 503, 504].contains(status) }
        let code = (error as NSError).code
        return (error as NSError).domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost].contains(code)
    }

    private func json<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                    query: [URLQueryItem] = []) async throws -> T {
        let request = try request(path, method: method, body: body.map { try JSONSerialization.data(withJSONObject: $0) }, query: query)
        let bytes = try await data(request, retry: method == "GET")
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    private func mutate(_ path: String, method: String, body: [String: Any]? = nil) async throws {
        let request = try request(path, method: method, body: body.map { try JSONSerialization.data(withJSONObject: $0) })
        _ = try await data(request, retry: false)
    }

    public func login(email: String, password: String) async throws -> SessionLogin {
        try await json("auth/login", method: "POST", body: ["email": email, "password": password])
    }
    public func currentSessionID() async throws -> String {
        let sessions: [LoginSession] = try await json("sessions")
        let current = sessions.filter(\.current)
        guard current.count == 1 else { throw SyncError.invalidResponse }
        return current[0].id
    }
    public func logout() async throws { try await mutate("auth/logout", method: "POST") }
    public func authorizeOAuth(_ challenge: OAuthChallenge) async throws -> URL {
        struct Authorization: Decodable { let url: URL }
        let result: Authorization = try await json("oauth/authorize", method: "POST", body: [
            "redirectUri": OAuthChallenge.redirectURI, "state": challenge.state, "codeChallenge": challenge.challenge])
        guard result.url.scheme == "https" || (serverURL.scheme == "http" && result.url.scheme == "http") else { throw SyncError.invalidResponse }
        return result.url
    }
    public func finishOAuth(callback: URL, challenge: OAuthChallenge) async throws -> SessionLogin {
        try challenge.validate(callback)
        return try await json("oauth/callback", method: "POST", body: [
            "url": callback.absoluteString, "state": challenge.state, "codeVerifier": challenge.verifier])
    }

    public func acknowledge(_ acks: [String]) async throws {
        guard !acks.isEmpty else { return }
        try await mutate("sync/ack", method: "POST", body: ["acks": acks])
    }

    public func synchronize(reset: Bool, started: @escaping @Sendable () async throws -> Void,
                            receive: @escaping @Sendable ([SyncEvent]) async throws -> Void) async throws {
        try await version().requireSupported()
        let body = try JSONSerialization.data(withJSONObject: ["types": SyncContract.requests, "reset": reset])
        var request = try request("sync/stream", method: "POST", body: body)
        request.setValue("application/jsonlines+json", forHTTPHeaderField: "Accept")
        let streamSession = URLSession(configuration: session.configuration, delegate: ConnectionDelegate(), delegateQueue: nil)
        defer { streamSession.invalidateAndCancel() }
        let (bytes, response) = try await streamSession.bytes(for: request)
        try Self.validate(response)
        guard response.mimeType == "application/jsonlines+json" else { throw SyncError.invalidSyncStream }
        try await started()
        var decoder = SyncLineDecoder()
        var batch: [SyncEvent] = []
        var terminal: SyncEvent?
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let event = try decoder.append(byte) else { continue }
            guard terminal == nil else { throw SyncError.invalidSyncStream }
            if event.kind == .reset {
                guard batch.isEmpty else { throw SyncError.invalidSyncStream }
                terminal = event
            } else if event.kind == .complete {
                terminal = event
            } else {
                batch.append(event)
                if batch.count == SyncContract.batchSize {
                    try await receive(batch); batch.removeAll(keepingCapacity: true)
                }
            }
        }
        try decoder.finish()
        guard let terminal else { throw SyncError.invalidSyncStream }
        if terminal.kind == .reset { throw SyncError.syncReset }
        batch.append(terminal)
        try await receive(batch)
    }

    public func asset(_ id: String) async throws -> Asset { try await json("assets/\(id)") }

    public func thumbnail(_ assetID: String, large: Bool) async throws -> Data {
        var request = try request("assets/\(assetID)/thumbnail", query: [URLQueryItem(name: "size", value: large ? "preview" : "thumbnail")])
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await data(request)
    }

    public func download(_ asset: Asset, into directory: URL, progress: Progress) async throws -> URL {
        let request = try request("assets/\(asset.id)/original")
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validate(response)
        // Reject corruption before handing ownership to File Provider.
        guard try FileDigest.sha1(temporary).base64EncodedString() == asset.checksum else { throw SyncError.invalidResponse }
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress.completedUnitCount = progress.totalUnitCount
        return destination
    }

    public func upload(_ file: URL, filename: String, progress: Progress) async throws -> Asset {
        let digest = try FileDigest.sha1(file)
        let boundary = "ImmichSync-" + UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let formatter = ISO8601DateFormatter()
        let created = attributes[.creationDate] as? Date ?? Date()
        let modified = attributes[.modificationDate] as? Date ?? created
        let fields = ["fileCreatedAt": formatter.string(from: created), "fileModifiedAt": formatter.string(from: modified), "filename": filename]
        try Multipart.write(file: file, filename: filename, fields: fields, boundary: boundary, to: temporary)
        var request = try request("assets", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(digest.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "x-immich-checksum")
        let (bytes, response) = try await session.upload(for: request, fromFile: temporary, delegate: TransferDelegate(progress))
        try Self.validate(response)
        struct Uploaded: Decodable { let id: String; let status: String }
        let result = try JSONDecoder().decode(Uploaded.self, from: bytes)
        guard ["created", "duplicate"].contains(result.status.lowercased()) else { throw SyncError.invalidResponse }
        let uploaded = try await asset(result.id)
        guard uploaded.checksum == digest.base64EncodedString(), !uploaded.isTrashed else {
            throw SyncError.invalidResponse
        }
        return uploaded
    }

    public func createAlbum(name: String) async throws -> Album { try await json("albums", method: "POST", body: ["albumName": name]) }
    public func renameAlbum(_ id: String, name: String) async throws -> Album { try await json("albums/\(id)", method: "PATCH", body: ["albumName": name]) }
    public func deleteAlbum(_ id: String) async throws { try await mutate("albums/\(id)", method: "DELETE") }
    public func add(_ assetID: String, to albumID: String) async throws {
        let rows: [MembershipResult] = try await json("albums/\(albumID)/assets", method: "PUT", body: ["ids": [assetID]])
        guard rows.contains(where: { $0.id == assetID && ($0.success || $0.error == "duplicate") }) else { throw SyncError.invalidResponse }
    }
    public func remove(_ assetID: String, from albumID: String) async throws {
        let rows: [MembershipResult] = try await json("albums/\(albumID)/assets", method: "DELETE", body: ["ids": [assetID]])
        guard rows.contains(where: { $0.id == assetID && ($0.success || $0.error == "not_found") }) else { throw SyncError.invalidResponse }
    }
    private struct MembershipResult: Decodable { let id: String; let success: Bool; let error: String? }
    public func copyAssociations(from sourceID: String, to targetID: String) async throws {
        try await mutate("assets/copy", method: "PUT", body: ["sourceId": sourceID, "targetId": targetID,
            "albums": true, "favorite": true, "sharedLinks": false, "sidecar": true, "stack": false])
    }
    public func trash(_ assetID: String) async throws {
        struct Features: Decodable { let trash: Bool }
        struct Config: Decodable { let trashDays: Int }
        let features: Features = try await json("server/features")
        let config: Config = try await json("server/config")
        guard features.trash, config.trashDays > 0 else { throw SyncError.trashDisabled }
        try await mutate("assets", method: "DELETE", body: ["ids": [assetID], "force": false])
    }
}

public enum Multipart {
    public static func write(file: URL, filename: String, fields: [String: String], boundary: String, to output: URL) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw SyncError.invalidResponse }
        let destination = try FileHandle(forWritingTo: output)
        let source = try FileHandle(forReadingFrom: file)
        defer { try? destination.close(); try? source.close() }
        func write(_ text: String) throws { try destination.write(contentsOf: Data(text.utf8)) }
        for key in fields.keys.sorted() {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
        }
        let safeFilename = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(safeFilename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        while let bytes = try source.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            try destination.write(contentsOf: bytes)
        }
        try write("\r\n--\(boundary)--\r\n")
    }
}
