import Foundation

public protocol ImmichRemote: Sendable {
    func snapshot() async throws -> RemoteSnapshot
    func asset(_ id: String) async throws -> Asset
    func upload(_ file: URL, filename: String, progress: Progress) async throws -> Asset
    func download(_ asset: Asset, into directory: URL, progress: Progress) async throws -> URL
    func thumbnail(_ assetID: String, large: Bool) async throws -> Data
    func createAlbum(name: String) async throws -> Album
    func renameAlbum(_ id: String, name: String) async throws
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
        // Never forward an API key to another host, port, or a downgraded HTTP connection.
        guard let old = task.originalRequest?.url, let new = request.url,
              old.scheme == new.scheme, old.host == new.host, old.port == new.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
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
    public let account: Account
    private let key: String
    private let keyProvider: (@Sendable () throws -> String)?
    private let session: URLSession

    public init(account: Account, apiKey: String, session: URLSession? = nil, keyProvider: (@Sendable () throws -> String)? = nil) {
        self.account = account; key = apiKey; self.keyProvider = keyProvider
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
    public func currentUser() async throws -> ImmichUser { try await json("users/me") }
    public func mediaTypes() async throws -> MediaTypes { try await json("server/media-types") }

    public func request(_ path: String, method: String = "GET", body: Data? = nil,
                        query: [URLQueryItem] = []) throws -> URLRequest {
        var url = account.serverURL
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw SyncError.invalidServer }
        if !query.isEmpty { components.queryItems = query }
        guard let finalURL = components.url else { throw SyncError.invalidServer }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method; request.httpBody = body
        request.setValue(try keyProvider?() ?? key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ImmichSync-macOS/0.1", forHTTPHeaderField: "User-Agent")
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
        let bytes = try await data(request, retry: method == "GET" || path == "search/metadata")
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    private func mutate(_ path: String, method: String, body: [String: Any]? = nil) async throws {
        let request = try request(path, method: method, body: body.map { try JSONSerialization.data(withJSONObject: $0) })
        _ = try await data(request, retry: false)
    }

    public func search(albumID: String? = nil) async throws -> [Asset] {
        var items: [String: Asset] = [:]
        var cursor: String?
        var page = 1
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var body: [String: Any] = ["size": 1000, "withExif": true, "withStacked": true]
            if account.usesCursorSearch {
                var filter: [String: Any] = ["trashedAt": ["eq": NSNull()]]
                if let albumID { filter["albumIds"] = ["any": [albumID]] }
                body["filter"] = filter
                body["orderBy"] = ["field": "fileCreatedAt", "direction": "asc"]
                if let cursor { body["cursor"] = cursor }
            } else {
                body["page"] = page; body["order"] = "asc"; body["withDeleted"] = false
                if let albumID { body["albumIds"] = [albumID] }
            }
            let result: SearchResponse = try await json("search/metadata", method: "POST", body: body)
            let batch = result.assets
            for item in batch.items { items[item.id] = item }
            let next = account.usesCursorSearch ? batch.nextCursor : batch.nextPage
            if let next {
                guard !batch.items.isEmpty, seen.insert(next).inserted else { throw SyncError.incompleteListing }
                if account.usesCursorSearch { cursor = next }
                else {
                    guard let nextPage = Int(next), nextPage > page else { throw SyncError.incompleteListing }
                    page = nextPage
                }
            } else {
                // Search totals can be estimates. Never infer deletion from a broken/empty page chain.
                guard batch.total <= items.count || batch.total == 0 else { throw SyncError.incompleteListing }
                break
            }
        } while true
        return items.values.filter { $0.ownerId == account.userID && !$0.isTrashed && $0.visibility != "locked" }
    }

    public func snapshot() async throws -> RemoteSnapshot {
        async let fetchedAssets = search()
        async let fetchedTypes = mediaTypes()
        let query = account.usesCursorSearch
            ? [URLQueryItem(name: "isOwned", value: "true")]
            : []
        let allAlbums: [Album] = try await json("albums", query: query)
        let albums = allAlbums.filter { $0.ownerId == nil ? account.usesCursorSearch : $0.ownerId == account.userID }
        var memberships: [String: [String]] = [:]
        // Bounded by the session connection pool; process albums sequentially to avoid overwhelming self-hosted servers.
        for album in albums { memberships[album.id] = try await search(albumID: album.id).map(\.id) }
        return try await RemoteSnapshot(assets: fetchedAssets, albums: albums, memberships: memberships, mediaTypes: fetchedTypes)
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
        var fields = ["fileCreatedAt": formatter.string(from: created), "fileModifiedAt": formatter.string(from: modified), "filename": filename]
        if account.serverMajor < 3 {
            fields["deviceId"] = "immich-sync-macos"
            fields["deviceAssetId"] = digest.map { String(format: "%02x", $0) }.joined()
        }
        try Multipart.write(file: file, filename: filename, fields: fields, boundary: boundary, to: temporary)
        var request = try request("assets", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(digest.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "x-immich-checksum")
        let (bytes, response) = try await session.upload(for: request, fromFile: temporary, delegate: TransferDelegate(progress))
        try Self.validate(response)
        struct Uploaded: Decodable { let id: String; let status: String }
        let result = try JSONDecoder().decode(Uploaded.self, from: bytes)
        guard ["created", "duplicate", "replaced"].contains(result.status.lowercased()) else { throw SyncError.invalidResponse }
        let uploaded = try await asset(result.id)
        guard uploaded.checksum == digest.base64EncodedString(), uploaded.ownerId == account.userID, !uploaded.isTrashed else {
            throw SyncError.invalidResponse
        }
        return uploaded
    }

    public func createAlbum(name: String) async throws -> Album { try await json("albums", method: "POST", body: ["albumName": name]) }
    public func renameAlbum(_ id: String, name: String) async throws { try await mutate("albums/\(id)", method: "PATCH", body: ["albumName": name]) }
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
