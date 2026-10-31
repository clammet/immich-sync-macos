import Foundation

public enum SharedStore {
    public static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "ImmichAppGroup") as? String ?? "" }
    public static var directory: URL {
        get throws {
            guard !groupID.isEmpty, !groupID.contains("$("),
                  let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { throw SyncError.missingAccount }
            return url
        }
    }
    public static func account() throws -> Account? {
        let file = try directory.appendingPathComponent("session-account.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: file))
    }
    public static func save(_ account: Account) throws {
        let folder = try directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: folder.appendingPathComponent("session-account.json"), options: .atomic)
    }
    public static func clearAccount() throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("session-account.json"))
    }
    public static func catalogURL(accountID: String) throws -> URL {
        // Only identifiers created by this app may be used as path components.
        guard UUID(uuidString: accountID) != nil else { throw SyncError.missingAccount }
        return try directory.appendingPathComponent(accountID, isDirectory: true).appendingPathComponent("session-catalog.sqlite")
    }
}

public struct SyncStatus: Codable, Sendable {
    public var lastSync: Date?
    public var assetCount: Int
    public var albumCount: Int
    public var message: String?
    public var syncing: Bool
    public init(lastSync: Date? = nil, assetCount: Int = 0, albumCount: Int = 0, message: String? = nil, syncing: Bool = false) {
        self.lastSync = lastSync; self.assetCount = assetCount; self.albumCount = albumCount
        self.message = message; self.syncing = syncing
    }
}
