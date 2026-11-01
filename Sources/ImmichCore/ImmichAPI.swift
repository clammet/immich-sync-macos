import Foundation

public struct SessionLogin: Decodable, Sendable {
    public let accessToken: String
    public let userId: String
    public let name: String
    public let userEmail: String
    public let shouldChangePassword: Bool
}
public struct LoginSession: Decodable, Sendable { public let id: String; public let current: Bool }
public struct IndexedAsset: Codable, Equatable, Sendable {
    public let id: String
    public let originalPath: String
    public let libraryId: String?
    public let checksum: String
    public let type: String
    public let isTrashed: Bool
    public let visibility: String?
}
public struct ImmichLibrary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let importPaths: [String]
    public let exclusionPatterns: [String]
}
public struct ImmichDiscovery: Codable, Sendable {
    public var libraries: [ImmichLibrary]
    public var samplePaths: [String]
    public var libraryAccessDenied: Bool
    public var explanation: String {
        libraryAccessDenied ? "Library configuration requires additional Immich permissions. Sample asset paths are shown below. Configure the OpenCloud media root and its exact path inside the Immich server."
        : "These paths belong to the Immich server or container. Immich does not expose an OpenCloud space identifier. Confirm the media roots and server-path mappings below. Exclusion patterns and indexing status still apply."
    }
}
public protocol ImmichMediaRemote: Sendable {
    func discover() async throws -> ImmichDiscovery
    func indexedAssets(path: String, libraryID: String?) async throws -> [IndexedAsset]
    func createAlbum(name: String, assetIDs: [String]) async throws -> URL
    func createSharingLink(assetIDs: [String]) async throws -> URL
}

/// Optional, read-only access to media originals. No upload, trash, or sync API is exposed.
public final class ImmichAPI: ImmichMediaRemote, @unchecked Sendable {
    public let serverURL: URL
    private let token: @Sendable () throws -> String?
    private let apiKey: Bool
    private let session: URLSession
    public init(serverURL: URL, token: @escaping @Sendable () throws -> String? = { nil }, apiKey: Bool = false, session: URLSession? = nil) {
        self.serverURL = serverURL.lastPathComponent == "api" ? serverURL : serverURL.appendingPathComponent("api")
        self.token = token; self.apiKey = apiKey; self.session = session ?? HTTPClient.session()
    }
    public func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        var r = URLRequest(url: path.split(separator: "/").reduce(serverURL) { $0.appendingPathComponent(String($1)) })
        r.httpMethod = method; r.httpBody = body
        if let token = try token() { r.setValue(apiKey ? token : "Bearer " + token,forHTTPHeaderField: apiKey ? "x-api-key" : "Authorization") }
        r.setValue("application/json",forHTTPHeaderField: "Accept")
        r.setValue("OpenCloud Sync",forHTTPHeaderField: "deviceModel")
        r.setValue("macOS",forHTTPHeaderField: "deviceType")
        if body != nil { r.setValue("application/json",forHTTPHeaderField: "Content-Type") }
        return r
    }
    private func json<T: Decodable>(_ path: String, method: String = "GET", body: [String:Any]? = nil) async throws -> T {
        let r = try request(path,method: method,body: body.map { try JSONSerialization.data(withJSONObject: $0) })
        let (bytes,response) = try await session.data(for: r)
        try HTTPClient.validate(response)
        return try JSONDecoder().decode(T.self,from: bytes)
    }
    public func login(email: String,password: String) async throws -> SessionLogin { try await json("auth/login",method: "POST",body: ["email":email,"password":password]) }
    public func currentSessionID() async throws -> String {
        let sessions: [LoginSession] = try await json("sessions")
        let current = sessions.filter(\.current)
        guard current.count == 1 else { throw SyncError.invalidResponse }; return current[0].id
    }
    public struct Identity: Decodable { public let id: String; public let name: String; public let email: String }
    public func identity() async throws -> Identity { try await json("users/me") }
    public func logout() async throws {
        guard !apiKey else { return }
        let (_,response) = try await session.data(for: request("auth/logout",method: "POST")); try HTTPClient.validate(response)
    }
    public func authorizeOAuth(_ challenge: OAuthChallenge) async throws -> URL {
        struct Authorization: Decodable { let url: URL }
        let result: Authorization = try await json("oauth/authorize",method: "POST",body: ["redirectUri":OAuthChallenge.redirectURI,"state":challenge.state,"codeChallenge":challenge.challenge])
        guard result.url.scheme == "https" || (serverURL.scheme == "http" && result.url.scheme == "http") else { throw SyncError.invalidResponse }; return result.url
    }
    public func finishOAuth(callback: URL, challenge: OAuthChallenge) async throws -> SessionLogin {
        try challenge.validate(callback)
        return try await json("oauth/callback",method: "POST",body: ["url":callback.absoluteString,"state":challenge.state,"codeVerifier":challenge.verifier])
    }
    private struct Search: Decodable {
        struct Assets: Decodable { let items: [IndexedAsset]; let nextCursor: String? }
        let assets: Assets
    }
    public func discover() async throws -> ImmichDiscovery {
        var libraries: [ImmichLibrary] = [], denied = false
        do { libraries = try await json("libraries") }
        catch SyncError.http(403, _) { denied = true }
        // The regular user's asset search can still provide exact paths without admin access.
        let sample: Search = try await json("search/metadata",method: "POST",body: ["size":25,"withExif":false])
        return ImmichDiscovery(libraries: libraries,samplePaths: sample.assets.items.map(\.originalPath),libraryAccessDenied: denied)
    }
    public func indexedAssets(path: String, libraryID: String?) async throws -> [IndexedAsset] {
        var filter: [String:Any] = ["originalPath":["eq":path]]
        if let libraryID { filter["libraryId"] = ["eq":libraryID] }
        var cursor: String?, seen = Set<String>(), result: [IndexedAsset] = []
        repeat {
            var body: [String:Any] = ["filter":filter,"size":100,"withExif":false]
            if let cursor { body["cursor"] = cursor }
            let response: Search = try await json("search/metadata",method: "POST",body: body)
            // Exact local validation is essential even when a server implements a broader search.
            result += response.assets.items.filter { $0.originalPath.utf8.elementsEqual(path.utf8) && !$0.isTrashed && $0.visibility != "locked" &&
                ["IMAGE","VIDEO"].contains($0.type) && (libraryID == nil || $0.libraryId == libraryID) }
            cursor = response.assets.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw SyncError.invalidResponse }
        } while cursor != nil
        return result
    }
    public func createAlbum(name: String, assetIDs: [String]) async throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !assetIDs.isEmpty else { throw SyncError.mediaNotIndexed }
        struct Album: Decodable { let id: String }
        let album: Album = try await json("albums",method: "POST",body: ["albumName":name,"assetIds":assetIDs])
        return serverURL.deletingLastPathComponent().appendingPathComponent("albums").appendingPathComponent(album.id)
    }
    public func createSharingLink(assetIDs: [String]) async throws -> URL {
        guard !assetIDs.isEmpty else { throw SyncError.mediaNotIndexed }
        struct Link: Decodable { let key: String }
        let result: Link = try await json("shared-links",method: "POST",body: ["type":"INDIVIDUAL","assetIds":assetIDs,"allowUpload":false,"allowDownload":true,"showMetadata":false])
        guard !result.key.isEmpty else { throw SyncError.invalidResponse }
        return serverURL.deletingLastPathComponent().appendingPathComponent("share").appendingPathComponent(result.key)
    }
}
