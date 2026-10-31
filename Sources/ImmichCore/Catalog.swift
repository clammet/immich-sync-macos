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

public enum LocalChange: Sendable {
    case asset(Asset), album(Album), deleteAlbum(String), trashAsset(String)
    case membership(album: String, asset: String, present: Bool)
    case replaceAsset(source: String, target: Asset)
}

/// Native remote entities, durable acknowledgements, and Finder changes share one SQLite transaction.
public final class Catalog: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public let localDirectory: URL

    private struct Replica: Codable {
        var sessionID: String
        var active: Int
        var working: Int
        var bootstrapping: Bool
        var needsReset: Bool
    }

    public init(url: URL) throws {
        localDirectory = url.deletingLastPathComponent().appendingPathComponent("local-only", isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SyncError.database("Could not open the catalog")
        }
        sqlite3_busy_timeout(database, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, parent TEXT NOT NULL, asset TEXT, album TEXT, local INTEGER NOT NULL, generation INTEGER, payload BLOB NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS item_parent ON items(parent,id)")
        try execute("CREATE INDEX IF NOT EXISTS item_parent_local ON items(parent,local)")
        try execute("CREATE INDEX IF NOT EXISTS item_asset ON items(asset)")
        try execute("CREATE INDEX IF NOT EXISTS item_album ON items(album)")
        try execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, parent TEXT NOT NULL, payload BLOB)")
        try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS pins (id TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS remote_assets (generation INTEGER, id TEXT, payload BLOB NOT NULL, PRIMARY KEY(generation,id))")
        try execute("CREATE TABLE IF NOT EXISTS remote_albums (generation INTEGER, id TEXT, payload BLOB NOT NULL, PRIMARY KEY(generation,id))")
        try execute("CREATE TABLE IF NOT EXISTS remote_exif (generation INTEGER, asset TEXT, payload BLOB NOT NULL, PRIMARY KEY(generation,asset))")
        try execute("CREATE TABLE IF NOT EXISTS album_users (generation INTEGER, album TEXT, user TEXT, role TEXT NOT NULL, PRIMARY KEY(generation,album,user))")
        try execute("CREATE TABLE IF NOT EXISTS memberships (generation INTEGER, album TEXT, asset TEXT, PRIMARY KEY(generation,album,asset))")
        try execute("CREATE INDEX IF NOT EXISTS membership_asset ON memberships(generation,asset,album)")
        try execute("CREATE TABLE IF NOT EXISTS path_work (generation INTEGER, id TEXT, revision TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, due REAL NOT NULL DEFAULT 0, PRIMARY KEY(generation,id))")
        try execute("CREATE INDEX IF NOT EXISTS path_work_due ON path_work(generation,due,id)")
        try execute("CREATE TABLE IF NOT EXISTS item_names (id TEXT PRIMARY KEY, parent TEXT NOT NULL, name TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS item_name_parent ON item_names(parent,name)")
        try execute("CREATE TABLE IF NOT EXISTS checkpoints (kind TEXT PRIMARY KEY, ack TEXT NOT NULL, pending INTEGER NOT NULL)")
        try transaction {
            if try stateUnlocked("epoch", as: String.self) == nil { try setStateUnlocked("epoch", value: UUID().uuidString) }
            for record in ItemRecord.containers { try upsertItem(record, generation: nil) }
        }
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
    public func localChildren(_ id: String) throws -> [ItemRecord] { try lock.withLock { try records("SELECT payload FROM items WHERE parent=? AND local=1", text: [id]) } }
    public func hasChildren(_ id: String) throws -> Bool { try lock.withLock { try !strings("SELECT id FROM items WHERE parent=? AND id<>? LIMIT 1", text: [id,id]).isEmpty } }

    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private func upsertItem(_ proposed: ItemRecord, generation: Int?) throws {
        var record = proposed
        let old = try itemUnlocked(record.id)
        var attempt = 0
        while !(try strings("SELECT id FROM item_names WHERE parent=? AND name=? AND id<>? LIMIT 1", text: [record.parentID,Self.nameKey(record.filename),record.id])).isEmpty {
            attempt += 1
            // Never rename/overwrite another sibling, particularly a local-only import.
            record.filename = ItemRecord.safeName(proposed.filename,
                identity: String(FolderProjection.digest(record.id).prefix(16)) + (attempt == 1 ? "" : "-\(attempt)"), preserveExtension: !record.isFolder)
        }
        // Keep a previously assigned collision suffix when its contender has disappeared.
        if let old, old.parentID == record.parentID, old.filename != proposed.filename,
           old.filename == ItemRecord.safeName(proposed.filename, identity: String(FolderProjection.digest(record.id).prefix(16)), preserveExtension: !record.isFolder),
           try strings("SELECT id FROM item_names WHERE parent=? AND name=? AND id<>? LIMIT 1", text: [old.parentID,Self.nameKey(old.filename),old.id]).isEmpty {
            record.filename = old.filename
        }
        let payload = try encoder.encode(record)
        let query = try statement("INSERT OR REPLACE INTO items(id,parent,asset,album,local,generation,payload) VALUES(?,?,?,?,?,?,?)", text: [record.id, record.parentID], blobs: [7: payload])
        defer { sqlite3_finalize(query) }
        if let asset = record.asset?.id { sqlite3_bind_text(query, 3, asset, -1, transient) }
        if let album = record.albumID { sqlite3_bind_text(query, 4, album, -1, transient) }
        sqlite3_bind_int(query, 5, record.isLocalOnly ? 1 : 0)
        if let generation { sqlite3_bind_int64(query, 6, Int64(generation)) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        try run("INSERT OR REPLACE INTO item_names(id,parent,name) VALUES(?,?,?)", text: [record.id,record.parentID,Self.nameKey(record.filename)])
        guard old != record else { return }
        if let old, old.parentID != record.parentID {
            // A move is an update in the working set, including across page boundaries.
            // Container enumerators translate this old-parent notification to a departure.
            try run("INSERT INTO events(id,parent,payload) VALUES(?,?,?)", text: [record.id,old.parentID], blobs: [3: payload])
        }
        try run("INSERT INTO events(id,parent,payload) VALUES(?,?,?)", text: [record.id,record.parentID], blobs: [3: payload])
    }
    private func retireItem(_ id: String) throws {
        guard let record = try itemUnlocked(id) else { return }
        if record.kind == .album {
            for var local in try records("SELECT payload FROM items WHERE parent=? AND local=1", text: [id]) {
                local.parentID = ItemRecord.libraryID
                try upsertItem(local, generation: nil)
            }
        }
        try run("DELETE FROM items WHERE id=?", text: [id])
        try run("DELETE FROM item_names WHERE id=?", text: [id])
        try run("INSERT INTO events(id,parent,payload) VALUES(?,?,NULL)", text: [id,record.parentID])
    }

    public func prepareSession(_ sessionID: String) throws {
        try lock.withLock {
            try transaction {
                let old = try stateUnlocked("replica", as: Replica.self)
                guard old?.sessionID != sessionID else { return }
                let active = old?.active ?? 0
                try clearGeneration(active + 1)
                try execute("DELETE FROM checkpoints")
                try setStateUnlocked("replica", value: Replica(sessionID: sessionID, active: active, working: active + 1, bootstrapping: true, needsReset: true))
            }
        }
    }
    public var needsServerReset: Bool { get throws { try lock.withLock { try replica().needsReset } } }
    public var isBootstrapping: Bool { get throws { try lock.withLock { try replica().bootstrapping } } }
    public func acceptedReset(sessionID: String) throws {
        try lock.withLock {
            var replica = try replica(); guard replica.sessionID == sessionID else { throw SyncError.missingAccount }; replica.needsReset = false
            try setStateUnlocked("replica", value: replica)
        }
    }
    public func requestReset(sessionID: String) throws {
        try lock.withLock {
            try transaction {
                var replica = try replica()
                guard replica.sessionID == sessionID else { throw SyncError.missingAccount }
                replica.working = replica.active + 1; replica.bootstrapping = true; replica.needsReset = true
                try clearGeneration(replica.working)
                try execute("DELETE FROM checkpoints")
                try setStateUnlocked("replica", value: replica)
            }
        }
    }
    private func replica() throws -> Replica {
        guard let value = try stateUnlocked("replica", as: Replica.self) else { throw SyncError.missingAccount }
        return value
    }
    private func clearGeneration(_ generation: Int) throws {
        for table in ["remote_assets", "remote_albums", "remote_exif", "album_users", "memberships", "path_work"] {
            try run("DELETE FROM \(table) WHERE generation=?", text: [String(generation)])
        }
    }
    public func pendingAcknowledgements() throws -> [String] { try lock.withLock { try strings("SELECT ack FROM checkpoints WHERE pending=1 ORDER BY kind") } }
    public func acknowledged(_ acks: [String], sessionID: String) throws {
        try lock.withLock {
            try transaction {
                guard try replica().sessionID == sessionID else { throw SyncError.missingAccount }
                for ack in acks { try run("UPDATE checkpoints SET pending=0 WHERE ack=?", text: [ack]) }
            }
        }
    }

    @discardableResult public func apply(_ events: [SyncEvent], userID: String, sessionID: String) throws -> Bool {
        try lock.withLock {
            try transaction {
                var replica = try replica()
                guard replica.sessionID == sessionID else { throw SyncError.missingAccount }
                guard !replica.needsReset else { throw SyncError.invalidSyncStream }
                let generation = replica.working
                var assets = Set<String>(), albums = Set<String>()
                var complete = false
                for event in events {
                    guard !complete, event.kind != .reset else { throw SyncError.invalidSyncStream }
                    switch event.payload {
                    case .asset(let value):
                        let exif: SyncExif? = try one("SELECT payload FROM remote_exif WHERE generation=? AND asset=?", text: [String(generation),value.id], as: SyncExif.self)
                        var asset = value.asset(version: event.ack, exif: exif.map { Asset.Exif(fileSizeInByte: $0.fileSizeInByte) })
                        // Native AssetV2 omits paths. Retain the last resolved path until enrichment.
                        asset.originalPath = try storedAsset(value.id, generation: generation)?.originalPath
                            ?? storedAsset(value.id, generation: replica.active)?.originalPath
                        try storeAsset(asset, generation: generation)
                        if Self.eligible(asset, userID: userID) {
                            try enqueuePath(value.id, generation: generation)
                        } else {
                            try run("DELETE FROM path_work WHERE generation=? AND id=?", text: [String(generation),value.id])
                        }
                        assets.insert(value.id)
                    case .assetDelete(let id):
                        try run("DELETE FROM path_work WHERE generation=? AND id=?", text: [String(generation),id])
                        try run("DELETE FROM remote_assets WHERE generation=? AND id=?", text: [String(generation),id])
                        try run("DELETE FROM remote_exif WHERE generation=? AND asset=?", text: [String(generation),id])
                        try run("DELETE FROM memberships WHERE generation=? AND asset=?", text: [String(generation),id])
                        assets.insert(id)
                    case .exif(let value):
                        try run("INSERT OR REPLACE INTO remote_exif(generation,asset,payload) VALUES(?,?,?)", text: [String(generation),value.assetId], blobs: [3: try encoder.encode(value)])
                        if var asset = try storedAsset(value.assetId, generation: generation) {
                            asset.exifInfo = Asset.Exif(fileSizeInByte: value.fileSizeInByte)
                            try storeAsset(asset, generation: generation)
                        }
                        assets.insert(value.assetId)
                    case .album(let value):
                        try storeAlbum(value, generation: generation); albums.insert(value.id)
                    case .albumDelete(let id):
                        try removeAlbum(id, generation: generation); albums.insert(id)
                    case .albumUser(let value):
                        guard ["owner", "editor", "viewer"].contains(value.role) else { throw SyncError.invalidSyncStream }
                        try run("INSERT OR REPLACE INTO album_users(generation,album,user,role) VALUES(?,?,?,?)", text: [String(generation),value.albumId,value.userId,value.role])
                        albums.insert(value.albumId)
                    case .albumUserDelete(let album, let user):
                        try run("DELETE FROM album_users WHERE generation=? AND album=? AND user=?", text: [String(generation),album,user])
                        albums.insert(album)
                    case .membership(let value, let present):
                        try membership(value.albumId, asset: value.assetId, present: present, generation: generation)
                        assets.insert(value.assetId)
                    case .control: complete = event.kind == .complete
                    }
                    try run("INSERT OR REPLACE INTO checkpoints(kind,ack,pending) VALUES(?,?,1)", text: [event.ackKind,event.ack])
                }
                if replica.bootstrapping {
                    if complete {
                        try publish(generation: generation, userID: userID)
                        let previous = replica.active
                        replica.active = generation; replica.bootstrapping = false
                        try setStateUnlocked("replica", value: replica)
                        if previous != generation { try clearGeneration(previous) }
                    }
                } else {
                    for id in albums { try projectAlbum(id, generation: generation, userID: userID) }
                    for id in assets { try projectAsset(id, generation: generation, userID: userID) }
                }
                if complete { try updateCounts(completed: true) }
                try pruneEvents()
                return complete
            }
        }
    }

    private func enqueuePath(_ id: String, generation: Int) throws {
        try run("INSERT OR REPLACE INTO path_work(generation,id,revision,attempts,due) VALUES(?,?,?,0,0)", text: [String(generation),id,UUID().uuidString])
    }
    public func pathWork(sessionID: String, userID: String, now: Date = Date(), limit: Int = 100) throws -> [AssetPathWork] {
        try lock.withLock {
            let replica = try replica()
            guard replica.sessionID == sessionID else { throw SyncError.missingAccount }
            // Replacement generations are enriched after publication; their queued IDs are durable
            // throughout bootstrap. Never resolve IDs against the old visible generation by accident.
            while true {
                let query = try statement("SELECT id,revision FROM path_work WHERE generation=? AND due<=? ORDER BY due,id LIMIT ?",
                    text: [String(replica.active),String(now.timeIntervalSince1970),String(min(100,max(1,limit)))])
                var candidates: [AssetPathWork] = []
                do {
                    defer { sqlite3_finalize(query) }
                    while true {
                        let code = sqlite3_step(query)
                        if code == SQLITE_DONE { break }
                        guard code == SQLITE_ROW else { throw failure() }
                        candidates.append(AssetPathWork(id: string(query,0), generation: replica.active, revision: string(query,1)))
                    }
                }
                var result: [AssetPathWork] = []
                for candidate in candidates {
                    if let asset = try storedAsset(candidate.id, generation: replica.active), Self.eligible(asset, userID: userID) {
                        result.append(candidate)
                    } else {
                        try run("DELETE FROM path_work WHERE generation=? AND id=? AND revision=?", text: [String(replica.active),candidate.id,candidate.revision])
                    }
                }
                if !result.isEmpty || candidates.isEmpty { return result }
            }
        }
    }
    /// Only enrich paths. Native entities remain authoritative for existence, scope and content.
    /// Revision/session checks reject responses overlapping an update, deletion or replacement reset.
    public func resolvedPaths(_ responses: [Asset], work: [AssetPathWork], userID: String, sessionID: String, now: Date = Date()) throws {
        try lock.withLock {
            try transaction {
                let replica = try replica()
                guard replica.sessionID == sessionID else { throw SyncError.missingAccount }
                let values = Dictionary(responses.map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first })
                for entry in work {
                    guard entry.generation == replica.active,
                          try strings("SELECT revision FROM path_work WHERE generation=? AND id=?", text: [String(entry.generation),entry.id]).first == entry.revision else { continue }
                    if var asset = try storedAsset(entry.id, generation: entry.generation), Self.eligible(asset, userID: userID),
                       let response = values[entry.id], Self.eligible(response, userID: userID), response.libraryId == asset.libraryId,
                       response.checksum == asset.checksum, let path = response.originalPath, !path.isEmpty {
                        asset.originalPath = path
                        try storeAsset(asset, generation: entry.generation)
                        try projectAsset(entry.id, generation: entry.generation, userID: userID)
                        try run("DELETE FROM path_work WHERE generation=? AND id=? AND revision=?", text: [String(entry.generation),entry.id,entry.revision])
                    } else { try deferPath(entry, now: now) }
                }
                try pruneEvents()
            }
        }
    }
    private func deferPath(_ entry: AssetPathWork, now: Date) throws {
        let args = [String(entry.generation),entry.id,entry.revision]
        let attempts = Int(try strings("SELECT attempts FROM path_work WHERE generation=? AND id=? AND revision=?", text: args).first ?? "0") ?? 0
        let delay = min(3600, 5 * pow(2, Double(min(attempts,10))))
        try run("UPDATE path_work SET attempts=attempts+1,due=? WHERE generation=? AND id=? AND revision=?",
            text: [String(now.timeIntervalSince1970 + delay)] + args)
    }
    public func failedPaths(_ work: [AssetPathWork], sessionID: String, now: Date = Date()) throws {
        try lock.withLock {
            try transaction {
                guard try replica().sessionID == sessionID else { throw SyncError.missingAccount }
                for entry in work { try deferPath(entry, now: now) }
            }
        }
    }

    private func storeAsset(_ asset: Asset, generation: Int) throws {
        try run("INSERT OR REPLACE INTO remote_assets(generation,id,payload) VALUES(?,?,?)", text: [String(generation),asset.id], blobs: [3: try encoder.encode(asset)])
    }
    private func storedAsset(_ id: String, generation: Int) throws -> Asset? {
        try one("SELECT payload FROM remote_assets WHERE generation=? AND id=?", text: [String(generation),id], as: Asset.self)
    }
    private func storeAlbum(_ album: SyncAlbum, generation: Int) throws {
        try run("INSERT OR REPLACE INTO remote_albums(generation,id,payload) VALUES(?,?,?)", text: [String(generation),album.id], blobs: [3: try encoder.encode(album)])
    }
    private func removeAlbum(_ id: String, generation: Int) throws {
        try run("DELETE FROM remote_albums WHERE generation=? AND id=?", text: [String(generation),id])
        try run("DELETE FROM album_users WHERE generation=? AND album=?", text: [String(generation),id])
        try run("DELETE FROM memberships WHERE generation=? AND album=?", text: [String(generation),id])
    }
    private func membership(_ album: String, asset: String, present: Bool, generation: Int) throws {
        let sql = present ? "INSERT OR IGNORE INTO memberships(generation,album,asset) VALUES(?,?,?)" : "DELETE FROM memberships WHERE generation=? AND album=? AND asset=?"
        try run(sql, text: [String(generation),album,asset])
    }
    private func ownsAlbum(_ id: String, generation: Int, userID: String) throws -> Bool {
        !(try strings("SELECT album FROM album_users WHERE generation=? AND album=? AND user=? AND role='owner'", text: [String(generation),id,userID])).isEmpty
    }
    private static func eligible(_ asset: Asset, userID: String) -> Bool {
        asset.ownerId == userID && ["IMAGE", "VIDEO"].contains(asset.type) && !asset.isTrashed && asset.visibility != "locked"
    }
    private func pruneFolders(from id: String) throws {
        var parent = id
        while var folder = try itemUnlocked(parent), folder.kind == .folder || folder.kind == .externalFolder {
            let hasChildren = try !strings("SELECT id FROM items WHERE parent=? LIMIT 1", text: [parent]).isEmpty
            let hasRemote = try !strings("SELECT id FROM items WHERE parent=? AND local=0 LIMIT 1", text: [parent]).isEmpty
            let next = folder.parentID
            if !hasChildren { try retireItem(parent) }
            else if !hasRemote {
                // Preserve local descendants and the hierarchy they were dropped into.
                folder.kind = .ignoredFolder
                try upsertItem(folder, generation: nil)
            } else { break }
            parent = next
        }
    }
    private func projectAsset(_ id: String, generation: Int, userID: String) throws {
        let existing = try records("SELECT payload FROM items WHERE asset=?", text: [id])
        var desired: [ItemRecord] = []
        if let asset = try storedAsset(id, generation: generation), Self.eligible(asset, userID: userID) {
            let projection = FolderProjection.folders(for: asset)
            for folder in projection.folders {
                try upsertItem(ItemRecord(id: folder.id, parentID: folder.parent, filename: folder.name, kind: folder.kind, modifiedAt: "1"), generation: nil)
            }
            var main = ItemRecord.record(asset: asset)
            main.parentID = projection.folders.last!.id
            main.filename = ItemRecord.safeName(projection.filename, identity: asset.id, preserveExtension: true)
            desired.append(main)
            let albums = try strings("SELECT m.album FROM memberships m JOIN album_users u ON u.generation=m.generation AND u.album=m.album JOIN remote_albums a ON a.generation=m.generation AND a.id=m.album WHERE m.generation=? AND m.asset=? AND u.user=? AND u.role='owner'", text: [String(generation),id,userID])
            for album in albums { desired.append(ItemRecord.record(asset: asset, albumID: album)) }
        }
        let keep = Set(desired.map(\.id))
        for item in existing where !keep.contains(item.id) { try retireItem(item.id) }
        for record in desired { try upsertItem(record, generation: generation) }
        for parent in Set(existing.map(\.parentID)) { try pruneFolders(from: parent) }
    }
    private func projectAlbum(_ id: String, generation: Int, userID: String, populateMembers: Bool = true) throws {
        let old = try itemUnlocked(ItemRecord.albumID(id))
        if let album: SyncAlbum = try one("SELECT payload FROM remote_albums WHERE generation=? AND id=?", text: [String(generation),id], as: SyncAlbum.self), try ownsAlbum(id, generation: generation, userID: userID) {
            try upsertItem(ItemRecord(id: ItemRecord.albumID(id), parentID: ItemRecord.albumsID,
                filename: ItemRecord.safeName(album.name, identity: id), kind: .album, albumID: id, modifiedAt: album.updatedAt), generation: generation)
            if old == nil, populateMembers {
                for asset in try strings("SELECT asset FROM memberships WHERE generation=? AND album=?", text: [String(generation),id]) {
                    try projectAsset(asset, generation: generation, userID: userID)
                }
            }
        } else {
            for item in try strings("SELECT id FROM items WHERE album=? AND local=0", text: [id]) { try retireItem(item) }
        }
    }
    private func publish(generation: Int, userID: String) throws {
        for album in try strings("SELECT id FROM remote_albums WHERE generation=?", text: [String(generation)]) {
            try projectAlbum(album, generation: generation, userID: userID, populateMembers: false)
        }
        // Iterate source rows without retaining the entire library in memory.
        let query = try statement("SELECT id FROM remote_assets WHERE generation=?", text: [String(generation)])
        defer { sqlite3_finalize(query) }
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            try projectAsset(string(query, 0), generation: generation, userID: userID)
        }
        while true {
            let stale = try strings("SELECT id FROM items WHERE generation IS NOT NULL AND generation<>? LIMIT 256", text: [String(generation)])
            if stale.isEmpty { break }
            for id in stale {
                let parent = try itemUnlocked(id)?.parentID
                try retireItem(id)
                if let parent { try pruneFolders(from: parent) }
            }
        }
    }

    public func commitLocal(_ changes: [LocalChange], userID: String, sessionID: String) throws {
        try lock.withLock {
            try transaction {
                let replica = try replica()
                guard replica.sessionID == sessionID else { throw SyncError.missingAccount }
                let generations = Set([replica.active,replica.working])
                var assets = Set<String>(), albums = Set<String>()
                for generation in generations {
                    for change in changes {
                        switch change {
                        case .asset(let asset):
                            try storeAsset(asset, generation: generation); assets.insert(asset.id)
                            if asset.originalPath == nil, Self.eligible(asset, userID: userID) { try enqueuePath(asset.id, generation: generation) }
                        case .album(let album):
                            try storeAlbum(SyncAlbum(id: album.id, name: album.albumName, updatedAt: album.updatedAt), generation: generation)
                            for user in album.albumUsers {
                                try run("INSERT OR REPLACE INTO album_users(generation,album,user,role) VALUES(?,?,?,?)", text: [String(generation),album.id,user.user.id,user.role])
                            }
                            albums.insert(album.id)
                        case .deleteAlbum(let id): try removeAlbum(id, generation: generation); albums.insert(id)
                        case .membership(let album, let asset, let present):
                            try membership(album, asset: asset, present: present, generation: generation); assets.insert(asset)
                        case .trashAsset(let id):
                            if var asset = try storedAsset(id, generation: generation) {
                                asset.isTrashed = true; try storeAsset(asset, generation: generation)
                            }
                            try run("DELETE FROM path_work WHERE generation=? AND id=?", text: [String(generation),id])
                            assets.insert(id)
                        case .replaceAsset(let source, let target):
                            try storeAsset(target, generation: generation)
                            if target.originalPath == nil { try enqueuePath(target.id, generation: generation) }
                            try run("DELETE FROM path_work WHERE generation=? AND id=?", text: [String(generation),source])
                            for album in try strings("SELECT album FROM memberships WHERE generation=? AND asset=?", text: [String(generation),source]) {
                                try membership(album, asset: target.id, present: true, generation: generation)
                            }
                            if var old = try storedAsset(source, generation: generation) {
                                old.isTrashed = true; try storeAsset(old, generation: generation)
                            }
                            assets.formUnion([source,target.id])
                        }
                    }
                }
                for change in changes {
                    if case .replaceAsset(let source, let target) = change {
                        for old in try records("SELECT payload FROM items WHERE asset=?", text: [source]) {
                            let id = ItemRecord.assetID(target.id, albumID: old.albumID)
                            try run("INSERT OR IGNORE INTO pins(id,value) SELECT ?,value FROM pins WHERE id=?", text: [id,old.id])
                        }
                    }
                }
                for id in albums { try projectAlbum(id, generation: replica.active, userID: userID) }
                for id in assets { try projectAsset(id, generation: replica.active, userID: userID) }
                try updateCounts(completed: false)
                try pruneEvents()
            }
        }
    }

    public func saveLocal(_ record: ItemRecord) throws {
        guard record.isLocalOnly else { throw SyncError.unsupported }
        try lock.withLock {
            try transaction {
                guard let parent = try itemUnlocked(record.parentID), parent.isFolder, parent.kind != .root else { throw SyncError.unsupportedLocation }
                var ancestor = parent
                while true {
                    guard ancestor.id != record.id else { throw SyncError.unsupportedLocation }
                    if ancestor.parentID == ancestor.id { break }
                    guard let next = try itemUnlocked(ancestor.parentID) else { throw SyncError.unsupportedLocation }
                    ancestor = next
                }
                try upsertItem(record, generation: nil)
            }
        }
    }
    public func removeLocalTree(_ id: String, recursive: Bool) throws -> [ItemRecord] {
        try lock.withLock {
            try transaction {
                let children = try records("WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT i.id FROM items i JOIN tree t ON i.parent=t.id WHERE i.id<>i.parent) SELECT payload FROM items WHERE id IN (SELECT id FROM tree)", text: [id])
                guard children.allSatisfy(\.isLocalOnly), recursive || children.count <= 1 else { throw SyncError.unsupportedLocation }
                for child in children { try retireItem(child.id) }
                return children
            }
        }
    }

    private func updateCounts(completed: Bool) throws {
        var status = try stateUnlocked("status", as: SyncStatus.self) ?? SyncStatus()
        status.assetCount = Int(try strings("SELECT COUNT(*) FROM items WHERE asset IS NOT NULL AND album IS NULL", text: [])[0]) ?? 0
        status.albumCount = Int(try strings("SELECT COUNT(*) FROM items WHERE parent=? AND album IS NOT NULL", text: [ItemRecord.albumsID])[0]) ?? 0
        if completed { status.lastSync = Date(); status.syncing = false; status.message = nil }
        try setStateUnlocked("status", value: status)
    }
    private func pruneEvents() throws { try execute("DELETE FROM events WHERE seq < (SELECT MAX(seq)-50000 FROM events)") }
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
