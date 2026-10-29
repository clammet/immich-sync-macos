import CSQLite
import Foundation

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

/// Only the extension writes the catalog. WAL also permits concurrent status reads by the host app.
public final class Catalog: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder = JSONDecoder()
    public let localDirectory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        localDirectory = url.deletingLastPathComponent().appendingPathComponent("local-only", isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
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
        if try stateUnlocked("epoch", as: String.self) == nil { try setStateUnlocked("epoch", value: UUID().uuidString) }
    }
    deinit { sqlite3_close(database) }

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
    private func bytes(_ query: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(query, column))
        guard let pointer = sqlite3_column_blob(query, column), count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    private func string(_ query: OpaquePointer, _ column: Int32) -> String { String(cString: sqlite3_column_text(query, column)) }
    private func stateUnlocked<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        let query = try statement("SELECT value FROM state WHERE key=?", text: [key])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        return try decoder.decode(type, from: bytes(query, 0))
    }
    private func setStateUnlocked<T: Encodable>(_ key: String, value: T) throws {
        try run("INSERT OR REPLACE INTO state(key,value) VALUES(?,?)", text: [key], blobs: [2: try encoder.encode(value)])
    }
    public func state<T: Decodable>(_ key: String, as type: T.Type) throws -> T? { try lock.withLock { try stateUnlocked(key, as: type) } }
    public func setState<T: Encodable>(_ key: String, value: T) throws { try lock.withLock { try setStateUnlocked(key, value: value) } }

    private func allUnlocked() throws -> [ItemRecord] {
        let query = try statement("SELECT payload FROM items ORDER BY id")
        defer { sqlite3_finalize(query) }
        var records: [ItemRecord] = []
        while sqlite3_step(query) == SQLITE_ROW { records.append(try decoder.decode(ItemRecord.self, from: bytes(query, 0))) }
        return records
    }
    public func all() throws -> [ItemRecord] { try lock.withLock { try allUnlocked() } }
    public func item(_ id: String) throws -> ItemRecord {
        try lock.withLock {
            let query = try statement("SELECT payload FROM items WHERE id=?", text: [id])
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw SyncError.missingItem }
            return try decoder.decode(ItemRecord.self, from: bytes(query, 0))
        }
    }

    /// A complete remote pass is committed in one transaction. Failed pagination never reaches this method.
    @discardableResult public func replace(with records: [ItemRecord], preserveLocal: Bool = true, expectedAnchor: SyncAnchor? = nil) throws -> Set<String> {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                if let expectedAnchor, expectedAnchor != (try anchorUnlocked()) { throw SyncError.incompleteListing }
                let old = Dictionary(uniqueKeysWithValues: try allUnlocked().map { ($0.id, $0) })
                var records = records
                if preserveLocal {
                    let parents = Set(records.map(\.id)).union(old.values.filter(\.isLocalOnly).map(\.id))
                    records += old.values.filter(\.isLocalOnly).map { record in
                        var record = record
                        // Keep local files reachable if an album is removed on the server.
                        if !parents.contains(record.parentID) { record.parentID = ItemRecord.libraryID }
                        return record
                    }
                }
                let next = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                var parents = Set<String>()
                for record in records where old[record.id] != record {
                    let payload = try encoder.encode(record)
                    if let previous = old[record.id], previous.parentID != record.parentID {
                        try run("INSERT INTO events(id,parent,payload) VALUES(?,?,NULL)", text: [record.id, previous.parentID])
                    }
                    try run("INSERT OR REPLACE INTO items(id,parent,payload) VALUES(?,?,?)", text: [record.id, record.parentID], blobs: [3: payload])
                    try run("INSERT INTO events(id,parent,payload) VALUES(?,?,?)", text: [record.id, record.parentID], blobs: [3: payload])
                    parents.insert(record.parentID)
                    if let previous = old[record.id] { parents.insert(previous.parentID) }
                }
                for record in old.values where next[record.id] == nil {
                    try run("DELETE FROM items WHERE id=?", text: [record.id])
                    try run("INSERT INTO events(id,parent,payload) VALUES(?,?,NULL)", text: [record.id, record.parentID])
                    parents.insert(record.parentID)
                }
                try execute("COMMIT")
                return parents
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    private func anchorUnlocked() throws -> SyncAnchor {
        let query = try statement("SELECT COALESCE(MAX(seq),0) FROM events")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return SyncAnchor(epoch: try stateUnlocked("epoch", as: String.self)!, sequence: sqlite3_column_int64(query, 0))
    }
    public func anchor() throws -> SyncAnchor { try lock.withLock { try anchorUnlocked() } }

    public func changes(since anchor: SyncAnchor, limit: Int = 500) throws -> (changes: [CatalogChange], anchor: SyncAnchor, more: Bool) {
        try lock.withLock {
            let current = try anchorUnlocked()
            guard anchor.epoch == current.epoch, anchor.sequence >= 0, anchor.sequence <= current.sequence else { throw SyncError.incompleteListing }
            let query = try statement("SELECT seq,id,parent,payload FROM events WHERE seq > ? ORDER BY seq LIMIT ?")
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int64(query, 1, anchor.sequence); sqlite3_bind_int(query, 2, Int32(limit))
            var changes: [CatalogChange] = []
            var sequence = anchor.sequence
            while sqlite3_step(query) == SQLITE_ROW {
                sequence = sqlite3_column_int64(query, 0)
                let record = sqlite3_column_type(query, 3) == SQLITE_NULL ? nil : try decoder.decode(ItemRecord.self, from: bytes(query, 3))
                changes.append(CatalogChange(id: string(query, 1), parentID: string(query, 2), record: record))
            }
            return (changes, SyncAnchor(epoch: current.epoch, sequence: sequence), sequence < current.sequence)
        }
    }

    /// Paged enumeration and its anchor are read under one lock, preventing a mixed snapshot.
    public func page(parentID: String?, after: String?, expected: SyncAnchor?, limit: Int = 200) throws -> (items: [ItemRecord], anchor: SyncAnchor, next: String?) {
        try lock.withLock {
            let anchor = try anchorUnlocked()
            if let expected, expected != anchor { throw SyncError.incompleteListing }
            let sql = parentID == nil
                ? "SELECT id,payload FROM items WHERE id > ? ORDER BY id LIMIT ?"
                : "SELECT id,payload FROM items WHERE id > ? AND parent=? ORDER BY id LIMIT ?"
            let query = try statement(sql, text: parentID.map { [after ?? "", $0] } ?? [after ?? ""])
            defer { sqlite3_finalize(query) }
            sqlite3_bind_int(query, parentID == nil ? 2 : 3, Int32(limit + 1))
            var records: [ItemRecord] = []
            while sqlite3_step(query) == SQLITE_ROW { records.append(try decoder.decode(ItemRecord.self, from: bytes(query, 1))) }
            let hasMore = records.count > limit
            if hasMore { records.removeLast() }
            return (records, anchor, hasMore ? records.last?.id : nil)
        }
    }

    public func pin(_ id: String, value: Bool?) throws {
        try lock.withLock {
            if let value { try run("INSERT OR REPLACE INTO pins(id,value) VALUES(?,?)", text: [id, value ? "1" : "0"]) }
            else { try run("DELETE FROM pins WHERE id=?", text: [id]) }
            // Emit an update even though the server record has not changed.
            let query = try statement("INSERT INTO events(id,parent,payload) SELECT id,parent,payload FROM items WHERE id=?", text: [id])
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }
    public func pinned(_ id: String) throws -> Bool? {
        try lock.withLock {
            let query = try statement("SELECT value FROM pins WHERE id=?", text: [id])
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { return nil }
            return sqlite3_column_int(query, 0) != 0
        }
    }
}
