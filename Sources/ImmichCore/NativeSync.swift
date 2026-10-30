import CryptoKit
import Foundation
import Security

public enum SyncContract {
    public static let serverVersion = "3.3.5"
    public static let interval: TimeInterval = 60
    public static let batchSize = 256
    // These are the current entity formats in 3.3.5, including upstream formats named V1.
    public static let requests = ["AssetsV2", "AlbumsV2", "AlbumUsersV1", "AlbumToAssetsV1", "AssetExifsV1"]
}

public struct SyncAsset: Decodable, Sendable {
    public let id: String
    public let ownerId: String
    public let originalFileName: String
    public let checksum: String
    public let type: String
    public let fileCreatedAt: String?
    public let fileModifiedAt: String?
    public let createdAt: String?
    public let deletedAt: String?
    public let visibility: String
    public let libraryId: String?

    func asset(version: String, exif: Asset.Exif?) -> Asset {
        Asset(id: id, ownerId: ownerId, originalFileName: originalFileName,
            checksum: checksum, type: type, fileCreatedAt: fileCreatedAt ?? createdAt ?? "",
            fileModifiedAt: fileModifiedAt ?? fileCreatedAt ?? createdAt ?? "", updatedAt: version,
            isTrashed: deletedAt != nil, visibility: visibility, libraryId: libraryId, exifInfo: exif)
    }
}

public struct SyncAlbum: Codable, Sendable {
    public let id: String
    public let name: String
    public let updatedAt: String
}

public struct SyncAlbumUser: Decodable, Sendable {
    public let albumId: String
    public let userId: String
    public let role: String
}

public struct SyncMembership: Codable, Sendable {
    public let albumId: String
    public let assetId: String
}

public struct SyncExif: Codable, Sendable {
    public let assetId: String
    public let fileSizeInByte: Int64?
}

public struct SyncEvent: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case asset = "AssetV2", assetDelete = "AssetDeleteV1", exif = "AssetExifV1"
        case album = "AlbumV2", albumDelete = "AlbumDeleteV1"
        case albumUser = "AlbumUserV1", albumUserBackfill = "AlbumUserBackfillV1", albumUserDelete = "AlbumUserDeleteV1"
        case membership = "AlbumToAssetV1", membershipBackfill = "AlbumToAssetBackfillV1", membershipDelete = "AlbumToAssetDeleteV1"
        case checkpoint = "SyncAckV1", complete = "SyncCompleteV1", reset = "SyncResetV1"
    }
    public enum Payload: Sendable {
        case asset(SyncAsset), assetDelete(String), exif(SyncExif)
        case album(SyncAlbum), albumDelete(String), albumUser(SyncAlbumUser), albumUserDelete(album: String, user: String)
        case membership(SyncMembership, present: Bool), control
    }
    public let kind: Kind
    public let ack: String
    public let ackKind: String
    public let payload: Payload

    private enum Keys: String, CodingKey { case type, data, ack }
    private struct AssetDelete: Decodable { let assetId: String }
    private struct AlbumDelete: Decodable { let albumId: String }
    private struct AlbumUserDelete: Decodable { let albumId: String; let userId: String }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        kind = try values.decode(Kind.self, forKey: .type)
        ack = try values.decode(String.self, forKey: .ack)
        let components = ack.split(separator: "|", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count), let checkpointKind = Kind(rawValue: String(components[0])),
              checkpointKind != .checkpoint else { throw SyncError.invalidSyncStream }
        ackKind = checkpointKind.rawValue
        if kind == .reset {
            guard ack == "SyncResetV1|reset" else { throw SyncError.invalidSyncStream }
        } else {
            guard UUID(uuidString: String(components[1])) != nil,
                  components.count == 2 || UUID(uuidString: String(components[2])) != nil || components[2] == "complete",
                  kind == .checkpoint ? (checkpointKind != .complete && checkpointKind != .reset) : checkpointKind == kind else {
                throw SyncError.invalidSyncStream
            }
        }
        let data = try values.superDecoder(forKey: .data)
        switch kind {
        case .asset: payload = .asset(try SyncAsset(from: data))
        case .assetDelete: payload = .assetDelete(try AssetDelete(from: data).assetId)
        case .exif: payload = .exif(try SyncExif(from: data))
        case .album: payload = .album(try SyncAlbum(from: data))
        case .albumDelete: payload = .albumDelete(try AlbumDelete(from: data).albumId)
        case .albumUser, .albumUserBackfill: payload = .albumUser(try SyncAlbumUser(from: data))
        case .albumUserDelete:
            let value = try AlbumUserDelete(from: data)
            payload = .albumUserDelete(album: value.albumId, user: value.userId)
        case .membership, .membershipBackfill, .membershipDelete:
            payload = .membership(try SyncMembership(from: data), present: kind != .membershipDelete)
        case .checkpoint, .complete, .reset: payload = .control
        }
    }
}

/// Bounded framing: URLSession may split a JSON object, a UTF-8 scalar, or a newline across packets.
public struct SyncLineDecoder {
    private var line = Data()
    private let decoder = JSONDecoder()
    public init() {}
    public mutating func append(_ byte: UInt8) throws -> SyncEvent? {
        if byte == 10 {
            guard !line.isEmpty else { return nil }
            defer { line.removeAll(keepingCapacity: true) }
            do { return try decoder.decode(SyncEvent.self, from: line) }
            catch { throw SyncError.invalidSyncStream }
        }
        guard line.count < 1_048_576 else { throw SyncError.invalidSyncStream }
        line.append(byte)
        return nil
    }
    public func finish() throws { if !line.isEmpty { throw SyncError.invalidSyncStream } }
}

public struct OAuthChallenge: Sendable {
    public static let redirectURI = "immich-sync://oauth"
    public let state: String
    public let verifier: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init() throws {
        state = try Self.random(); verifier = try Self.random()
    }
    public func validate(_ callback: URL) throws {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == "immich-sync", components.host == "oauth", components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let query = components.queryItems,
              query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == state,
              query.filter({ $0.name == "code" }).count == 1,
              query.first(where: { $0.name == "code" })?.value?.isEmpty == false,
              !query.contains(where: { $0.name == "error" }) else { throw SyncError.invalidOAuthCallback }
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SyncError.invalidResponse }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
