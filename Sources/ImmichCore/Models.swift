import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum SyncError: Error, LocalizedError {
    case invalidServer, insecureServer, missingAccount, paused, unsupported, unsupportedLocation
    case http(Int, retryAfter: TimeInterval?), invalidResponse, incompleteListing, conflict, missingItem
    case database(String), keychain(Int32), incompatibleServer, trashDisabled

    public var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter a server URL without a username, password, query, or fragment."
        case .insecureServer: return "Use HTTPS, or explicitly allow HTTP for a trusted local server."
        case .missingAccount: return "Connect your Immich account in Settings."
        case .paused: return "Sync is paused. Resume it from the menu bar."
        case .unsupported: return "This file type is not supported by your Immich server. It stays on this Mac and is not backed up."
        case .unsupportedLocation: return "Use All Photos for media, or create an album directly inside Albums. Nested albums are not supported by Immich."
        case .http(let code, _):
            switch code {
            case 401: return "The API key was rejected. Update it in Settings."
            case 403: return "The API key is missing a required permission. See the setup instructions."
            case 413: return "The server or reverse proxy rejected this file's size."
            case 507: return "The Immich account or server has no storage available."
            default: return "Immich returned HTTP \(code)."
            }
        case .invalidResponse: return "The server returned an unexpected response. Check the server URL and version."
        case .incompleteListing: return "Immich returned an incomplete listing. The last complete library has been retained."
        case .conflict: return "This item changed on Immich. Your local edit has been preserved; resolve the conflict before retrying."
        case .missingItem: return "This item no longer exists on Immich."
        case .database(let message): return "The local sync database could not be accessed: \(message)"
        case .keychain(let code): return "Keychain access failed (\(code)). Unlock your login keychain and try again."
        case .incompatibleServer: return "Immich Sync requires Immich 2.5 or later."
        case .trashDisabled: return "Enable Immich trash with a retention period before syncing edits or deletions. The original has been kept."
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
    public var serverMajor: Int
    public var serverMinor: Int
    public var allowHTTP: Bool
    public var paused: Bool = false

    public init(id: String = UUID().uuidString, serverURL: URL, userID: String,
                displayName: String, serverMajor: Int, serverMinor: Int, allowHTTP: Bool) {
        self.id = id; self.serverURL = serverURL; self.userID = userID
        self.displayName = displayName; self.serverMajor = serverMajor
        self.serverMinor = serverMinor; self.allowHTTP = allowHTTP
    }
    public var usesCursorSearch: Bool { serverMajor > 3 || (serverMajor == 3 && serverMinor >= 2) }
}

public struct ServerVersion: Decodable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
}

public struct ImmichUser: Decodable, Sendable {
    public let id: String
    public let name: String
}

public struct Asset: Codable, Equatable, Sendable {
    public let id: String
    public let ownerId: String
    public let originalFileName: String
    public let originalMimeType: String?
    public let checksum: String
    public let type: String
    public let fileCreatedAt: String
    public let fileModifiedAt: String
    public let updatedAt: String
    public let isTrashed: Bool
    public let isOffline: Bool?
    public let visibility: String?
    public let libraryId: String?
    public let exifInfo: Exif?

    public struct Exif: Codable, Equatable, Sendable { public let fileSizeInByte: Int64? }
    public var contentVersion: Data { Data(checksum.utf8) }
    public var isMutable: Bool { libraryId == nil && isOffline != true }
    public var size: Int64? { exifInfo?.fileSizeInByte }
}

public struct Album: Codable, Equatable, Sendable {
    public let id: String
    public let albumName: String
    public let updatedAt: String
    public let ownerId: String?
    public let assetCount: Int
}

public struct SearchResponse: Decodable, Sendable {
    public let assets: SearchAssets
    public struct SearchAssets: Decodable, Sendable {
        public let items: [Asset]
        public let nextPage: String?
        public let nextCursor: String?
        public let total: Int
    }
}

public struct MediaTypes: Codable, Equatable, Sendable {
    public let image: [String]
    public let video: [String]
    public init(image: [String], video: [String]) { self.image = image; self.video = video }

    // Immich currently reports extensions; accept MIME types too for server compatibility.
    public func supports(filename: String) -> Bool {
        guard !filename.hasPrefix("."), !filename.hasSuffix("~") else { return false }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        let supported = Set((image + video).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        if supported.contains(ext) { return true }
        if supported.contains("image/" + ext) || supported.contains("video/" + ext) { return true }
        guard let mime = UTType(filenameExtension: ext)?.preferredMIMEType else { return false }
        return supported.contains(mime.lowercased())
    }
}

public struct RemoteSnapshot: Sendable {
    public var assets: [Asset]
    public var albums: [Album]
    public var memberships: [String: [String]]
    public var mediaTypes: MediaTypes
    public init(assets: [Asset], albums: [Album], memberships: [String: [String]], mediaTypes: MediaTypes) {
        self.assets = assets; self.albums = albums; self.memberships = memberships; self.mediaTypes = mediaTypes
    }
}

public struct ItemRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case root, library, albums, album, asset, ignoredFile, ignoredFolder }
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
    public var metadataVersion: Data { Data(SHA256.hash(data: Data("\(parentID)|\(filename)|\(modifiedAt)".utf8))) }
    public var isMutable: Bool { asset?.isMutable ?? (kind == .album) }

    public static func assetID(_ assetID: String, albumID: String? = nil) -> String {
        albumID.map { "member:\($0):\(assetID)" } ?? "asset:\(assetID)"
    }
    public static func albumID(_ id: String) -> String { "album:\(id)" }

    public static func records(from snapshot: RemoteSnapshot) -> [ItemRecord] {
        var records = [
            ItemRecord(id: rootID, parentID: rootID, filename: "Immich", kind: .root, modifiedAt: "1"),
            ItemRecord(id: libraryID, parentID: rootID, filename: "All Photos", kind: .library, modifiedAt: "1"),
            ItemRecord(id: albumsID, parentID: rootID, filename: "Albums", kind: .albums, modifiedAt: "1")
        ]
        let assets = Dictionary(snapshot.assets.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for asset in assets.values {
            records.append(record(asset: asset))
        }
        for album in snapshot.albums {
            records.append(ItemRecord(id: albumID(album.id), parentID: albumsID,
                filename: safeName(album.albumName, identity: album.id), kind: .album,
                albumID: album.id, modifiedAt: album.updatedAt))
            for assetID in Set(snapshot.memberships[album.id] ?? []) {
                if let asset = assets[assetID] { records.append(record(asset: asset, albumID: album.id)) }
            }
        }
        return records.sorted { $0.id < $1.id }
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
