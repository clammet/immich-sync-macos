import CSQLite
import Foundation
import Darwin

public struct SyncAnchor: Codable, Equatable, Sendable {
    public let epoch: String
    public let sequence: Int64
    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public init(data: Data) throws { self = try JSONDecoder().decode(Self.self, from: data) }
    public init(epoch: String, sequence: Int64) { self.epoch = epoch; self.sequence = sequence }
}

public struct CatalogChange: Sendable {
    public let id: String
    public let parentID: String
    public let record: ItemRecord?
}

/// OpenCloud metadata, Finder change history, and recovery operations share a durable SQLite store.
public final class Catalog: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public let localDirectory: URL
    private let syncLockURL: URL
    private let caseSensitiveNames: Bool

    public init(url: URL, caseSensitiveNames: Bool? = nil) throws {
        localDirectory = url.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        syncLockURL = url.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.caseSensitiveNames = caseSensitiveNames ?? ((try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SyncError.database("Could not open the catalog")
        }
        sqlite3_busy_timeout(database, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, parent TEXT NOT NULL, payload BLOB NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS item_parent ON items(parent,id)")
        try execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, parent TEXT NOT NULL, payload BLOB)")
        try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS pins (id TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS item_names (id TEXT PRIMARY KEY, parent TEXT NOT NULL, name TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS item_name_parent ON item_names(parent,name)")
        try execute("CREATE TABLE IF NOT EXISTS snapshot (token TEXT, id TEXT, payload BLOB NOT NULL, PRIMARY KEY(token,id))")
        try execute("CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try transaction {
            if try stateUnlocked("epoch", as: String.self) == nil { try setStateUnlocked("epoch", value: UUID().uuidString) }
            try upsertItem(.root)
        }
    }
    deinit { sqlite3_close(database) }

    /// Also serializes separate extension processes. A lock is never held across a DB transaction.
    public func acquireSyncLock() throws -> Int32 {
        let fd = open(syncLockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SyncError.database("Could not open sync lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SyncError.busy }
        return fd
    }
    public func releaseSyncLock(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> SyncError { .database(String(cString: sqlite3_errmsg(database))) }
    private func statement(_ sql: String, text: [String] = [], blobs: [Int32: Data] = [:]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (index, value) in text.enumerated() { sqlite3_bind_text(result, Int32(index + 1), value, -1, transient) }
        for (index, value) in blobs {
            _ = value.withUnsafeBytes { sqlite3_bind_blob(result, index, $0.baseAddress, Int32(value.count), transient) }
        }
        return result
    }
    private func run(_ sql: String, text: [String] = [], blobs: [Int32: Data] = [:]) throws {
        let query = try statement(sql, text: text, blobs: blobs)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }
    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try work(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func bytes(_ query: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(query, column))
        guard let pointer = sqlite3_column_blob(query, column), count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    private func string(_ query: OpaquePointer, _ column: Int32) -> String { String(cString: sqlite3_column_text(query, column)) }
    private func one<T: Decodable>(_ sql: String, text: [String], as type: T.Type) throws -> T? {
        let query = try statement(sql, text: text)
        defer { sqlite3_finalize(query) }
        let code = sqlite3_step(query)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw failure() }
        return try decoder.decode(type, from: bytes(query, 0))
    }
    private func strings(_ sql: String, text: [String] = []) throws -> [String] {
        let query = try statement(sql, text: text)
        defer { sqlite3_finalize(query) }
        var result: [String] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure() }
            result.append(string(query, 0))
        }
    }
    private func records(_ sql: String, text: [String] = []) throws -> [ItemRecord] {
        let query = try statement(sql, text: text)
        defer { sqlite3_finalize(query) }
        var result: [ItemRecord] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure() }
            result.append(try decoder.decode(ItemRecord.self, from: bytes(query, 0)))
        }
    }
    private func stateUnlocked<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try one("SELECT value FROM state WHERE key=?", text: [key], as: type)
    }
    private func setStateUnlocked<T: Encodable>(_ key: String, value: T) throws {
        try run("INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", text: [key], blobs: [2: try encoder.encode(value)])
    }
    public func state<T: Decodable>(_ key: String, as type: T.Type) throws -> T? { try lock.withLock { try stateUnlocked(key, as: type) } }
    public func setState<T: Encodable>(_ key: String, value: T) throws { try lock.withLock { try setStateUnlocked(key, value: value) } }
    private func itemUnlocked(_ id: String) throws -> ItemRecord? { try one("SELECT payload FROM items WHERE id=?", text: [id], as: ItemRecord.self) }
    public func item(_ id: String) throws -> ItemRecord {
        try lock.withLock { guard let record = try itemUnlocked(id) else { throw SyncError.missingItem }; return record }
    }
    private func nameKey(_ name: String) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        return caseSensitiveNames ? normalized : normalized.folding(options: [.caseInsensitive],locale: Locale(identifier: "en_US_POSIX"))
    }
    private func upsertItem(_ proposed: ItemRecord) throws {
        var record = proposed
        let old = try itemUnlocked(record.id)
        var attempt = 0
        while !(try strings("SELECT id FROM item_names WHERE parent=? AND name=? AND id<>? LIMIT 1", text: [record.parentID,nameKey(record.filename),record.id])).isEmpty {
            attempt += 1
            record.filename = ItemRecord.collisionName(proposed.filename, identity: String(RemotePath.digest(record.id).prefix(12)) + (attempt == 1 ? "" : "-\(attempt)"))
        }
        let payload = try encoder.encode(record)
        try run("INSERT OR REPLACE INTO items(id,parent,payload) VALUES(?,?,?)", text: [record.id,record.parentID], blobs: [3:payload])
        try run("INSERT OR REPLACE INTO item_names(id,parent,name) VALUES(?,?,?)", text: [record.id,record.parentID,nameKey(record.filename)])
        guard old != record else { return }
        if let old, old.parentID != record.parentID {
            try run("INSERT INTO events(id,parent,payload) VALUES(?,?,?)", text: [record.id,old.parentID], blobs: [3:payload])
        }
        try run("INSERT INTO events(id,parent,payload) VALUES(?,?,?)", text: [record.id,record.parentID], blobs: [3:payload])
    }
    private func retireItem(_ id: String) throws {
        guard let record = try itemUnlocked(id), id != ItemRecord.rootID else { return }
        try run("DELETE FROM items WHERE id=?", text: [id])
        try run("DELETE FROM item_names WHERE id=?", text: [id])
        try run("INSERT INTO events(id,parent,payload) VALUES(?,?,NULL)", text: [id,record.parentID])
    }
    public func children(_ id: String) throws -> [ItemRecord] {
        try lock.withLock { try records("SELECT payload FROM items WHERE parent=? AND id<>parent ORDER BY id", text: [id]) }
    }
    public func descendants(_ ids: [String]) throws -> [ItemRecord] {
        try lock.withLock {
            var result: [String:ItemRecord] = [:]
            for id in ids {
                for record in try records("WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT i.id FROM items i JOIN tree t ON i.parent=t.id WHERE i.id<>i.parent) SELECT payload FROM items WHERE id IN (SELECT id FROM tree)", text: [id]) { result[record.id] = record }
            }
            return result.values.sorted { $0.id < $1.id }
        }
    }
    public func beginSnapshot() throws -> String {
        try lock.withLock { try execute("DELETE FROM snapshot"); return UUID().uuidString }
    }
    public func stage(_ records: [ItemRecord], token: String) throws {
        try lock.withLock {
            try transaction {
                for record in records {
                    try run("INSERT INTO snapshot(token,id,payload) VALUES(?,?,?)", text: [token,record.id], blobs: [3:try encoder.encode(record)])
                }
            }
        }
    }
    /// Only complete, validated remote scans replace the visible tree. Recovery is independent.
    public func publishSnapshot(_ token: String) throws {
        try lock.withLock {
            try transaction {
                let desired = try records("SELECT payload FROM snapshot WHERE token=? ORDER BY id", text: [token])
                let ids = Set(desired.map(\.id))
                for id in try strings("SELECT id FROM items WHERE id<>'root'") where !ids.contains(id) { try retireItem(id) }
                // Clear the name index to allow authoritative swaps of names or parents.
                try execute("DELETE FROM item_names WHERE id<>'root'")
                for record in desired { try upsertItem(record) }
                var status = try stateUnlocked("status", as: SyncStatus.self) ?? SyncStatus()
                status.fileCount = desired.filter { !$0.isFolder }.count
                status.folderCount = desired.filter(\.isFolder).count
                status.lastSync = Date(); status.message = nil; status.syncing = false; status.mutationOutcome = nil
                try setStateUnlocked("status", value: status)
                try execute("DELETE FROM snapshot")
                try execute("DELETE FROM events WHERE seq < (SELECT MAX(seq)-50000 FROM events)")
            }
        }
    }
    public func commit(_ file: CloudFile, parentID: String) throws -> ItemRecord {
        try lock.withLock {
            try transaction {
                let old = try itemUnlocked(file.id)?.remote
                try upsertItem(.record(file, parentID: parentID))
                // Descendants retain IDs when a directory is moved or renamed.
                if file.isDirectory, let old {
                    for var child in try records("SELECT payload FROM items WHERE id<>'root'") {
                        guard var remote = child.remote, remote.space.id == old.space.id,
                              remote.path.count > old.path.count, RemotePath.contains(old.path,remote.path) else { continue }
                        remote.path = file.path + remote.path.dropFirst(old.path.count)
                        child.remote = remote
                        try upsertItem(child)
                    }
                }
                return try itemUnlocked(file.id)!
            }
        }
    }
    public func removeTree(_ id: String) throws {
        try lock.withLock {
            try transaction {
                for child in try strings("WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT i.id FROM items i JOIN tree t ON i.parent=t.id WHERE i.id<>i.parent) SELECT id FROM tree", text: [id]) { try retireItem(child) }
            }
        }
    }
    public func mediaMappings(for account: Account) throws -> [MediaMapping] {
        try lock.withLock {
            let identity = RemotePath.digest(account.serverURL.absoluteString + "\0" + account.userID)
            guard try stateUnlocked("mediaMappingIdentity",as: String.self) == identity else { return [] }
            return try stateUnlocked("mediaMappings",as: [MediaMapping].self) ?? []
        }
    }
    public func saveMediaMappings(_ mappings: [MediaMapping],for account: Account) throws {
        try lock.withLock {
            try transaction {
                try setStateUnlocked("mediaMappings",value: mappings)
                try setStateUnlocked("mediaMappingIdentity",value: RemotePath.digest(account.serverURL.absoluteString + "\0" + account.userID))
            }
        }
    }
    public func operation(_ id: String) throws -> PendingEdit? {
        try lock.withLock { try one("SELECT payload FROM operations WHERE id=?", text: [id], as: PendingEdit.self) }
    }
    public func saveOperation(_ operation: PendingEdit) throws {
        try lock.withLock { try run("INSERT OR REPLACE INTO operations(id,payload) VALUES(?,?)", text: [operation.id], blobs: [2:try encoder.encode(operation)]) }
    }
    public func recoveryOperations() throws -> [PendingEdit] {
        try lock.withLock {
            let ids = try strings("SELECT id FROM operations ORDER BY id")
            return try ids.compactMap { try one("SELECT payload FROM operations WHERE id=?", text: [$0], as: PendingEdit.self) }
        }
    }
    public func finishOperation(_ id: String) throws { try lock.withLock { try run("DELETE FROM operations WHERE id=?", text: [id]) } }

    private func anchorUnlocked() throws -> SyncAnchor {
        let values = try strings("SELECT COALESCE(MAX(seq),0) FROM events")
        return SyncAnchor(epoch: try stateUnlocked("epoch", as: String.self)!, sequence: Int64(values[0]) ?? 0)
    }
    public func anchor() throws -> SyncAnchor { try lock.withLock { try anchorUnlocked() } }
    public func changes(since anchor: SyncAnchor, limit: Int = 500) throws -> (changes: [CatalogChange], anchor: SyncAnchor, more: Bool) {
        try lock.withLock {
            let current = try anchorUnlocked()
            let first = Int64(try strings("SELECT COALESCE(MIN(seq),0) FROM events")[0]) ?? 0
            guard anchor.epoch == current.epoch, anchor.sequence >= max(0,first-1), anchor.sequence <= current.sequence else { throw SyncError.invalidAnchor }
            let query = try statement("SELECT seq,id,parent,payload FROM events WHERE seq > ? ORDER BY seq LIMIT ?")
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int64(query, 1, anchor.sequence); sqlite3_bind_int(query, 2, Int32(limit))
            var result: [CatalogChange] = []; var sequence = anchor.sequence
            while true {
                let code = sqlite3_step(query)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw failure() }
                sequence = sqlite3_column_int64(query, 0)
                let record = sqlite3_column_type(query, 3) == SQLITE_NULL ? nil : try decoder.decode(ItemRecord.self, from: bytes(query, 3))
                result.append(CatalogChange(id: string(query, 1), parentID: string(query, 2), record: record))
            }
            return (result, SyncAnchor(epoch: current.epoch, sequence: sequence), sequence < current.sequence)
        }
    }
    public func page(parentID: String?, after: String?, expected: SyncAnchor?, limit: Int = 200) throws -> (items: [ItemRecord], anchor: SyncAnchor, next: String?) {
        try lock.withLock {
            let anchor = try anchorUnlocked()
            if let expected, expected != anchor { throw SyncError.invalidAnchor }
            let sql = parentID == nil
                ? "SELECT payload FROM items WHERE id > ? ORDER BY id LIMIT ?"
                : "SELECT payload FROM items WHERE id > ? AND parent=? ORDER BY id LIMIT ?"
            var arguments = [after ?? ""]
            if let parentID { arguments.append(parentID) }
            arguments.append(String(limit + 1))
            var items = try records(sql, text: arguments)
            let more = items.count > limit
            if more { items.removeLast() }
            return (items,anchor,more ? items.last?.id : nil)
        }
    }
    public func pin(_ id: String, value: Bool?) throws {
        try lock.withLock {
            try transaction {
                if let value { try run("INSERT OR REPLACE INTO pins(id,value) VALUES(?,?)", text: [id,value ? "1" : "0"]) }
                else { try run("DELETE FROM pins WHERE id=?", text: [id]) }
                try run("INSERT INTO events(id,parent,payload) SELECT id,parent,payload FROM items WHERE id=?", text: [id])
            }
        }
    }
    public func pinned(_ id: String) throws -> Bool? {
        try lock.withLock {
            guard let value = try strings("SELECT value FROM pins WHERE id=?", text: [id]).first else { return nil }
            return value == "1"
        }
    }
}
