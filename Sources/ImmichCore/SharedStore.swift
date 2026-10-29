import Foundation
import Security

public enum SharedStore {
    public static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "ImmichAppGroup") as? String ?? "group.app.immich.sync" }
    public static var directory: URL {
        get throws {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { throw SyncError.missingAccount }
            return url
        }
    }
    public static func account() throws -> Account? {
        let file = try directory.appendingPathComponent("account.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: file))
    }
    public static func save(_ account: Account) throws {
        let folder = try directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: folder.appendingPathComponent("account.json"), options: .atomic)
    }
    public static func clearAccount() throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("account.json"))
    }
    public static func catalogURL(accountID: String) throws -> URL {
        // Only identifiers created by this app may be used as path components.
        guard UUID(uuidString: accountID) != nil else { throw SyncError.missingAccount }
        return try directory.appendingPathComponent(accountID, isDirectory: true).appendingPathComponent("catalog.sqlite")
    }
}

public enum CredentialStore {
    private static var accessGroup: String? { Bundle.main.object(forInfoDictionaryKey: "ImmichKeychainGroup") as? String }
    private static func query(_ accountID: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.immich.sync.api-key", kSecAttrAccount as String: accountID,
            kSecUseDataProtectionKeychain as String: true]
        if let accessGroup, !accessGroup.isEmpty { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
    public static func save(_ key: String, accountID: String) throws {
        let query = query(accountID)
        let attrs: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw SyncError.keychain(added) }
        } else if status != errSecSuccess { throw SyncError.keychain(status) }
    }
    public static func read(accountID: String) throws -> String {
        var query = query(accountID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw SyncError.keychain(status) }
        guard let bytes = result as? Data, let key = String(data: bytes, encoding: .utf8) else { throw SyncError.missingAccount }
        return key
    }
    public static func delete(accountID: String) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncError.keychain(status) }
    }
}

public struct SyncStatus: Codable, Sendable {
    public var lastRefresh: Date?
    public var assetCount: Int
    public var albumCount: Int
    public var message: String?
    public var refreshing: Bool
    public init(lastRefresh: Date? = nil, assetCount: Int = 0, albumCount: Int = 0, message: String? = nil, refreshing: Bool = false) {
        self.lastRefresh = lastRefresh; self.assetCount = assetCount; self.albumCount = albumCount
        self.message = message; self.refreshing = refreshing
    }
}
