import CryptoKit
import Foundation

public enum SyncError: Error, LocalizedError {
    case invalidServer, insecureServer, missingAccount, paused, unsupported, unsupportedLocation
    case http(Int, retryAfter: TimeInterval?), invalidResponse, invalidAnchor, conflict, missingItem
    case database(String), credentialStorage, incompatibleServer, trashDisabled
    case invalidSyncStream, syncReset, invalidOAuthCallback, passwordChangeRequired, serverOrganization

    public var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter a server URL without a username, password, query, or fragment."
        case .insecureServer: return "Use HTTPS, or explicitly allow HTTP for a trusted local server."
        case .missingAccount: return "Connect your Immich account in Settings."
        case .paused: return "Sync is paused. Resume it from the menu bar."
        case .unsupported: return "This file type is not supported by your Immich server. It stays on this Mac and is not backed up."
        case .unsupportedLocation: return "Drop media into Folder View, or create an album directly inside Albums. Nested albums stay on this Mac."
        case .serverOrganization: return "Immich controls Folder View through its storage template. Server folders and original filenames cannot be renamed or moved here. Your local content is preserved."
        case .http(let code, _):
            switch code {
            case 401: return "Sign in again. The credentials were rejected or the session has expired."
            case 403: return "This account cannot perform the requested operation."
            case 413: return "The server or reverse proxy rejected this file's size."
            case 507: return "The Immich account or server has no storage available."
            default: return "Immich returned HTTP \(code)."
            }
        case .invalidResponse: return "The server returned an unexpected response. Check the server URL and version."
        case .invalidAnchor: return "The Finder enumeration must restart from the current catalog."
        case .conflict: return "This item changed on Immich. Your local edit has been preserved; resolve the conflict before retrying."
        case .missingItem: return "This item no longer exists on Immich."
        case .database(let message): return "The local sync database could not be accessed: \(message)"
        case .credentialStorage: return "The saved sign-in credentials could not be accessed safely. Sign in again in Settings."
        case .incompatibleServer: return "This build requires Immich \(SyncContract.serverVersion)."
        case .trashDisabled: return "Enable Immich trash with a retention period before syncing edits or deletions. The original has been kept."
        case .invalidSyncStream: return "Immich returned an incomplete or unsupported sync stream. Saved changes will resume at the last committed checkpoint."
        case .syncReset: return "Immich requested a new initial synchronization."
        case .invalidOAuthCallback: return "The browser sign-in response could not be verified. Please start sign-in again."
        case .passwordChangeRequired: return "Change your password in Immich on the web, then sign in again."
        }
    }
}

public struct ServerAddress: Equatable, Sendable {
    public let apiURL: URL

    public init(_ value: String, allowHTTP: Bool = false) throws {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw SyncError.invalidServer }
        guard scheme == "https" || allowHTTP else { throw SyncError.insecureServer }
        components.scheme = scheme
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/api") { path += "/api" }
        components.path = path
        guard let url = components.url else { throw SyncError.invalidServer }
        apiURL = url
    }
}

public struct Account: Codable, Equatable, Sendable {
    public var id: String
    public var serverURL: URL
    public var userID: String
    public var displayName: String
    public var sessionID: String
    public var email: String
    public var allowHTTP: Bool
    public var paused: Bool = false

    public init(id: String = UUID().uuidString, serverURL: URL, userID: String,
                displayName: String, email: String, sessionID: String, allowHTTP: Bool) {
        self.id = id; self.serverURL = serverURL; self.userID = userID
        self.displayName = displayName; self.email = email
        self.sessionID = sessionID; self.allowHTTP = allowHTTP
    }
}

public struct ServerVersion: Decodable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: Int?
    public init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }
    public func requireSupported() throws {
        guard prerelease == nil, "\(major).\(minor).\(patch)" == SyncContract.serverVersion else { throw SyncError.incompatibleServer }
    }
}

public struct SessionLogin: Decodable, Sendable {
    public let accessToken: String
    public let userId: String
    public let name: String
    public let userEmail: String
    public let shouldChangePassword: Bool
}

public struct LoginSession: Decodable, Sendable {
    public let id: String
    public let current: Bool
}

public struct Asset: Codable, Equatable, Sendable {
    public let id: String
    public let ownerId: String
    public let originalFileName: String
    public let checksum: String
    public let type: String
    public let fileCreatedAt: String
    public let fileModifiedAt: String
    public let updatedAt: String
    public var isTrashed: Bool
    public let visibility: String?
    public let libraryId: String?
    public var exifInfo: Exif?
    public var originalPath: String? = nil

    public struct Exif: Codable, Equatable, Sendable { public let fileSizeInByte: Int64? }
    public var contentVersion: Data { Data(checksum.utf8) }
    public var isMutable: Bool { libraryId == nil }
    public var size: Int64? { exifInfo?.fileSizeInByte }
}

public struct Album: Codable, Equatable, Sendable {
    public let id: String
    public let albumName: String
    public let updatedAt: String
    public let albumUsers: [User]
    public struct User: Codable, Equatable, Sendable {
        public let role: String
        public let user: Identity
        public struct Identity: Codable, Equatable, Sendable { public let id: String }
    }
}

public struct MediaTypes: Codable, Equatable, Sendable {
    public let image: [String]
    public let video: [String]
    public init(image: [String], video: [String]) { self.image = image; self.video = video }

    public func supports(filename: String) -> Bool {
        guard !filename.hasPrefix("."), !filename.hasSuffix("~") else { return false }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        let supported = Set((image + video).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        return supported.contains(ext)
    }
}

public struct ItemRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case root, library, albums, album, folder, externalFolder, asset, ignoredFile, ignoredFolder }
    public static let rootID = "root"
    public static let libraryID = "all-photos"
    public static let albumsID = "albums"
    public var id: String
    public var parentID: String
    public var filename: String
    public var kind: Kind
    public var asset: Asset?
    public var albumID: String?
    public var modifiedAt: String
    public var localHash: String? = nil
    public var localSize: Int64? = nil
    public var isLocalOnly: Bool { kind == .ignoredFile || kind == .ignoredFolder }
    public var isFolder: Bool { kind != .asset && kind != .ignoredFile }
    public var contentVersion: Data { asset?.contentVersion ?? Data((localHash ?? "folder").utf8) }
    public var metadataVersion: Data { Data(SHA256.hash(data: Data("\(kind.rawValue)|\(parentID)|\(filename)|\(modifiedAt)".utf8))) }
    public var isMutable: Bool { asset?.isMutable ?? (kind == .album) }

    public static func assetID(_ assetID: String, albumID: String? = nil) -> String {
        albumID.map { "member:\($0):\(assetID)" } ?? "asset:\(assetID)"
    }
    public static func albumID(_ id: String) -> String { "album:\(id)" }

    public static var containers: [ItemRecord] {
        [
            ItemRecord(id: rootID, parentID: rootID, filename: "Immich", kind: .root, modifiedAt: "1"),
            ItemRecord(id: libraryID, parentID: rootID, filename: "Folder View", kind: .library, modifiedAt: "1"),
            ItemRecord(id: albumsID, parentID: rootID, filename: "Albums", kind: .albums, modifiedAt: "1")
        ]
    }

    public static func record(asset: Asset, albumID: String? = nil) -> ItemRecord {
        ItemRecord(id: assetID(asset.id, albumID: albumID), parentID: albumID.map(Self.albumID) ?? libraryID,
            filename: safeName(asset.originalFileName, identity: asset.id, preserveExtension: true),
            kind: .asset, asset: asset, albumID: albumID, modifiedAt: asset.updatedAt)
    }

    // A remote identity suffix prevents case-insensitive collisions and is stable across every device.
    public static func safeName(_ name: String, identity: String, preserveExtension: Bool = false) -> String {
        let cleaned = name.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || "/:".unicodeScalars.contains($0) ? "_" : String($0)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
        let ext = preserveExtension ? (base as NSString).pathExtension : ""
        var stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        if stem.hasPrefix(".") { stem = "_" + stem.dropFirst() }
        let suffix = " [\(identity)]" + (ext.isEmpty ? "" : "." + String(ext.prefix(20)))
        while (stem + suffix).utf8.count > 240 && !stem.isEmpty { stem.removeLast() }
        return stem + suffix
    }
}

public enum FileDigest {
    public static func sha1(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = Insecure.SHA1()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return Data(hash.finalize())
    }
}
