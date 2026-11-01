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
        let file = try directory.appendingPathComponent("opencloud-account.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: file))
    }
    public static func save(_ account: Account) throws {
        let folder = try directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: folder.appendingPathComponent("opencloud-account.json"), options: .atomic)
    }
    public static func immichAccount() throws -> Account? {
        let file = try directory.appendingPathComponent("immich-actions-account.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: file))
    }
    public static func saveImmich(_ account: Account) throws {
        try JSONEncoder().encode(account).write(to: directory.appendingPathComponent("immich-actions-account.json"), options: .atomic)
    }
    public static func clearImmich() throws {
        let file = try directory.appendingPathComponent("immich-actions-account.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public static func clearAccount() throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("opencloud-account.json"))
    }
    public static func catalogURL(accountID: String) throws -> URL {
        // Only identifiers created by this app may be used as path components.
        guard UUID(uuidString: accountID) != nil else { throw SyncError.missingAccount }
        return try directory.appendingPathComponent(accountID, isDirectory: true).appendingPathComponent("opencloud-catalog.sqlite")
    }
}

public struct SyncStatus: Codable, Sendable {
    public var lastSync: Date?
    public var fileCount: Int
    public var folderCount: Int
    public var message: String?
    public var syncing: Bool
    public var mutationOutcome: MutationOutcome?
    public init(lastSync: Date? = nil, fileCount: Int = 0, folderCount: Int = 0, message: String? = nil, syncing: Bool = false) {
        self.lastSync = lastSync; self.fileCount = fileCount; self.folderCount = folderCount; self.message = message; self.syncing = syncing
    }
}

public struct ActionResult: Codable, Sendable {
    public var title: String
    public var urls: [URL]
    public var createdAt: Date
    public init(title: String, urls: [URL]) { self.title = title; self.urls = urls; createdAt = Date() }
}
