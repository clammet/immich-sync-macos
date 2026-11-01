import CryptoKit
import Foundation

public enum SyncError: Error, LocalizedError {
    case invalidServer, insecureServer, missingAccount, paused, unsupported, unsupportedLocation
    case http(Int, retryAfter: TimeInterval?), invalidResponse, invalidAnchor, conflict, missingItem
    case database(String), credentialStorage, invalidOAuthCallback, passwordChangeRequired
    case mediaMappingRequired, mediaNotIndexed, ambiguousMedia, busy

    public var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter a server URL without credentials, a query, or a fragment."
        case .insecureServer: return "Use HTTPS, or explicitly allow HTTP for a trusted local server."
        case .missingAccount: return "Connect your OpenCloud account in Settings."
        case .paused: return "Sync is paused. Resume it from the menu bar."
        case .unsupported: return "This operation is not supported. Your local content is preserved."
        case .unsupportedLocation: return "Choose a folder inside an OpenCloud space. Moves between spaces are not supported."
        case .http(let code, _): return "The server returned HTTP \(code)." + (code == 401 ? " Sign in again." : "")
        case .invalidResponse: return "The server returned an incomplete or unexpected response. Cached files and pending edits are preserved."
        case .invalidAnchor: return "Finder must restart enumeration from the current catalog."
        case .conflict: return "The item or destination changed on OpenCloud. The server copy was kept and your pending edit is preserved in Recovery."
        case .missingItem: return "The item no longer exists or is not accessible."
        case .database(let message): return "The local sync database could not be accessed: \(message)"
        case .credentialStorage: return "Saved credentials could not be accessed. Reconnect in Settings."
        case .invalidOAuthCallback: return "The browser sign-in response could not be verified. Start sign-in again."
        case .passwordChangeRequired: return "Change your password on the Immich website, then sign in again."
        case .mediaMappingRequired: return "Configure an Immich media root and its exact server path in Settings. Container paths do not identify OpenCloud spaces."
        case .mediaNotIndexed: return "No accessible indexed Immich asset matches one or more selected files. Wait for Immich to index them or correct the mapping. Nothing was uploaded."
        case .ambiguousMedia: return "Multiple Immich assets or mappings match a selected file. Choose an explicit library and unambiguous media root in Settings."
        case .busy: return "Another sync operation is running. Finder will retry."
        }
    }
}

/// A service base URL. Immich's /api prefix is added only by the optional Immich client.
public struct ServerAddress: Equatable, Sendable {
    public let apiURL: URL
    public init(_ value: String, allowHTTP: Bool = false) throws {
        guard var c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { throw SyncError.invalidServer }
        guard scheme == "https" || allowHTTP else { throw SyncError.insecureServer }
        c.scheme = scheme
        while c.path.hasSuffix("/") { c.path.removeLast() }
        guard let url = c.url else { throw SyncError.invalidServer }
        apiURL = url
    }
}

public struct Account: Codable, Equatable, Sendable {
    public var id: String
    public var serverURL: URL
    public var userID: String
    public var displayName: String
    public var sessionID: String
    /// OpenCloud's app-token login name; kept separate from its immutable user ID.
    public var email: String
    public var allowHTTP: Bool
    public var paused: Bool = false
    public var credentialKind: String? = nil
    public init(id: String = UUID().uuidString, serverURL: URL, userID: String,
                displayName: String, email: String, sessionID: String, allowHTTP: Bool) {
        self.id = id; self.serverURL = serverURL; self.userID = userID
        self.displayName = displayName; self.email = email; self.sessionID = sessionID; self.allowHTTP = allowHTTP
    }
}

public enum RemotePath {
    public static func validate(_ parts: [String]) throws {
        guard parts.count <= 256, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
            !$0.contains("/") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw SyncError.invalidResponse }
    }
    public static func parse(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var result = parts
        if result.first == "" { result.removeFirst() }
        if result.last == "" { result.removeLast() }
        try validate(result)
        return result
    }
    public static func contains(_ root: [String], _ path: [String]) -> Bool {
        path.count >= root.count && zip(root,path).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
    public static func equal(_ left: [String],_ right: [String]) -> Bool { left.count == right.count && contains(left,right) }
    public static func key(_ parts: [String]) -> Data { Data(parts.joined(separator: "\0").utf8) }
    public static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct CloudSpace: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let rootID: String
    public let davURL: URL
    public init(id: String, name: String, rootID: String, davURL: URL) {
        self.id = id; self.name = name; self.rootID = rootID; self.davURL = davURL
    }
}

/// Paths and ETags come from OpenCloud. Finder names never serve as remote locators.
public struct CloudFile: Codable, Equatable, Sendable {
    public var space: CloudSpace
    public var fileID: String
    public var path: [String]
    public var isDirectory: Bool
    public var etag: String
    public var size: Int64?
    public var modifiedAt: String
    public var permissions: String?
    public var checksum: String?
    public var id: String { "cloud:" + RemotePath.digest(space.id + "\0" + fileID) }
    public var url: URL { path.reduce(space.davURL) { $0.appendingPathComponent($1) } }
    public var name: String { path.last ?? space.name }
    public init(space: CloudSpace, fileID: String, path: [String], isDirectory: Bool, etag: String,
                size: Int64? = nil, modifiedAt: String = "", permissions: String? = nil, checksum: String? = nil) {
        self.space = space; self.fileID = fileID; self.path = path; self.isDirectory = isDirectory
        self.etag = etag; self.size = size; self.modifiedAt = modifiedAt; self.permissions = permissions; self.checksum = checksum
    }
}

public struct ItemRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case root, space, folder, file }
    public static let rootID = "root"
    public var id: String
    public var parentID: String
    public var filename: String
    public var kind: Kind
    public var remote: CloudFile?
    public var modifiedAt: String
    public var isFolder: Bool { kind != .file }
    public var contentVersion: Data { Data((remote?.etag ?? "root").utf8) }
    public var metadataVersion: Data { Data(SHA256.hash(data: Data("\(parentID)|\(filename)|\(modifiedAt)|\(remote?.etag ?? "")|\(remote?.permissions ?? "")".utf8))) }
    public static var root: ItemRecord { ItemRecord(id: rootID, parentID: rootID, filename: "OpenCloud", kind: .root, modifiedAt: "1") }
    public static func record(_ file: CloudFile, parentID: String) -> ItemRecord {
        ItemRecord(id: file.id, parentID: parentID, filename: localName(file.name),
                   kind: file.path.isEmpty ? .space : file.isDirectory ? .folder : .file, remote: file, modifiedAt: file.modifiedAt)
    }
    /// Preserve every representable name, including dotfiles, whitespace, case, and Unicode.
    public static func localName(_ name: String) -> String {
        var result = name.unicodeScalars.map { "/".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) ? "_" : String($0) }.joined()
        if result.isEmpty || result == "." || result == ".." { result = "_" }
        if result.utf8.count > 255 { result = collisionName(result, identity: String(RemotePath.digest(name).prefix(12))) }
        return result
    }
    public static func collisionName(_ name: String, identity: String) -> String {
        let ext = (name as NSString).pathExtension
        let suffix = " [\(identity)]" + (ext.isEmpty ? "" : "." + String(ext.prefix(20)))
        var stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        while (stem + suffix).utf8.count > 255 && !stem.isEmpty { stem.removeLast() }
        return stem + suffix
    }
}

public enum FileDigest {
    public static func sha256(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        return Data(hash.finalize())
    }
    public static func sha1(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = Insecure.SHA1()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        return Data(hash.finalize())
    }
}
