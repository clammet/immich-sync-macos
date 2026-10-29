import Foundation

private actor OperationGate {
    private var busy = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if !busy { busy = true; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }
    func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().1.resume() }
    }
}

/// Serializes remote snapshots with writes across async suspension points.
/// A Swift actor alone would allow a stale listing to overwrite a completed mutation during reentrancy.
public final class SyncEngine: @unchecked Sendable {
    public let catalog: Catalog
    private let remote: any ImmichRemote
    private let gate = OperationGate()
    private let checkRunning: @Sendable () throws -> Void

    public init(catalog: Catalog, remote: any ImmichRemote, checkRunning: @escaping @Sendable () throws -> Void = {}) {
        self.catalog = catalog; self.remote = remote; self.checkRunning = checkRunning
    }

    @discardableResult public func refresh(force: Bool = false) async throws -> Set<String> {
        try await gate.acquire(); defer { Task { await gate.release() } }
        return try await refreshUnlocked(force: force)
    }

    private func refreshUnlocked(force: Bool) async throws -> Set<String> {
        try checkRunning(); try Task.checkCancellation()
        var status = try catalog.state("status", as: SyncStatus.self) ?? SyncStatus()
        if !force, let date = status.lastRefresh, Date().timeIntervalSince(date) < 300 { return [] }
        status.refreshing = true; status.message = nil
        try catalog.setState("status", value: status)
        do {
            let initialAnchor = try catalog.anchor()
            var snapshot = try await remote.snapshot()
            // Offset pagination is not an atomic snapshot. Confirm missing originals individually
            // before publishing removals, so a moving page boundary cannot delete a live placeholder.
            let received = Set(snapshot.assets.map(\.id))
            let old = Dictionary(try catalog.all().compactMap(\.asset).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for known in old.values where !received.contains(known.id) {
                do {
                    let current = try await remote.asset(known.id)
                    if !current.isTrashed, current.visibility != "locked", current.ownerId == known.ownerId { snapshot.assets.append(current) }
                } catch SyncError.missingItem { /* Confirmed remote deletion. */ }
            }
            try Task.checkCancellation()
            let parents = try catalog.replace(with: ItemRecord.records(from: snapshot), expectedAnchor: initialAnchor)
            try catalog.setState("mediaTypes", value: snapshot.mediaTypes)
            try catalog.setState("status", value: SyncStatus(lastRefresh: Date(), assetCount: snapshot.assets.count, albumCount: snapshot.albums.count))
            return parents
        } catch {
            status.refreshing = false; status.message = error.localizedDescription
            try? catalog.setState("status", value: status)
            throw error
        }
    }

    public func download(id: String, directory: URL, progress: Progress, requestedVersion: Data? = nil) async throws -> (URL, ItemRecord) {
        try checkRunning(); try Task.checkCancellation()
        let record = try catalog.item(id)
        if record.kind == .ignoredFile {
            let destination = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: localURL(record.id), to: destination)
            progress.completedUnitCount = progress.totalUnitCount
            return (destination, record)
        }
        guard let known = record.asset else { throw SyncError.unsupported }
        let latest = try await remote.asset(known.id)
        guard latest.ownerId == known.ownerId, !latest.isTrashed else { throw SyncError.missingItem }
        if let requestedVersion, requestedVersion != latest.contentVersion { throw SyncError.conflict }
        let url = try await remote.download(latest, into: directory, progress: progress)
        return (url, ItemRecord.record(asset: latest, albumID: record.albumID))
    }

    public func thumbnail(id: String, large: Bool) async throws -> Data? {
        try checkRunning(); try Task.checkCancellation()
        guard let asset = try catalog.item(id).asset else { return nil }
        return try await remote.thumbnail(asset.id, large: large)
    }

    public func create(parentID: String, filename: String, directory: Bool, contents: URL?, progress: Progress) async throws -> ItemRecord {
        try await gate.acquire(); defer { Task { await gate.release() } }
        try checkRunning(); try Task.checkCancellation()
        if directory {
            guard parentID == ItemRecord.albumsID else {
                return try saveLocal(parentID: parentID, filename: filename, contents: nil)
            }
            let album = try await remote.createAlbum(name: filename)
            _ = try await refreshUnlocked(force: true)
            return try catalog.item(ItemRecord.albumID(album.id))
        }
        let parent = try catalog.item(parentID)
        guard parent.kind == .library || parent.kind == .album || parent.kind == .ignoredFolder || parent.kind == .albums else { throw SyncError.unsupportedLocation }
        let types = try catalog.state("mediaTypes", as: MediaTypes.self) ?? MediaTypes(image: [], video: [])
        if parent.kind == .ignoredFolder || parent.kind == .albums || !types.supports(filename: filename) {
            guard let contents else { throw SyncError.unsupported }
            return try saveLocal(parentID: parentID, filename: filename, contents: contents)
        }
        guard let contents else { throw SyncError.unsupported }
        let asset = try await remote.upload(contents, filename: filename, progress: progress)
        if let albumID = parent.albumID { try await remote.add(asset.id, to: albumID) }
        _ = try await refreshUnlocked(force: true)
        return try catalog.item(ItemRecord.assetID(asset.id, albumID: parent.albumID))
    }

    private struct EditJournal: Codable {
        var targetID: String
        var source: ItemRecord
        var associationsCopied: Bool = false
        var sourceTrashed: Bool = false
    }

    public func modify(id: String, baseContentVersion: Data, filename: String?, parentID: String?,
                       contents: URL?, progress: Progress) async throws -> ItemRecord {
        try await gate.acquire(); defer { Task { await gate.release() } }
        try checkRunning(); try Task.checkCancellation()
        let record: ItemRecord
        if let found = try? catalog.item(id) { record = found }
        else if let contents, let assetID = id.split(separator: ":").last,
                let edit = try catalog.state("edit:\(assetID):\(FileDigest.sha1(contents).base64EncodedString())", as: EditJournal.self) {
            record = edit.source
        } else { throw SyncError.missingItem }
        if record.isLocalOnly {
            let destination = parentID ?? record.parentID
            let name = filename ?? record.filename
            let types = try catalog.state("mediaTypes", as: MediaTypes.self) ?? MediaTypes(image: [], video: [])
            let parent = try catalog.item(destination)
            if record.kind == .ignoredFile, types.supports(filename: name), parent.kind == .library || parent.kind == .album {
                let uploaded = try await remote.upload(contents ?? localURL(id), filename: name, progress: progress)
                if let albumID = parent.albumID { try await remote.add(uploaded.id, to: albumID) }
                try removeLocal(record)
                _ = try await refreshUnlocked(force: true)
                return try catalog.item(ItemRecord.assetID(uploaded.id, albumID: parent.albumID))
            }
            return try saveLocal(parentID: destination, filename: name, contents: contents,
                existing: record)
        }
        if record.kind == .album {
            guard parentID == nil || parentID == ItemRecord.albumsID else { throw SyncError.unsupportedLocation }
            if let filename, let albumID = record.albumID {
                let suffix = " [\(albumID)]"
                let name = filename.hasSuffix(suffix) ? String(filename.dropLast(suffix.count)) : filename
                try await remote.renameAlbum(albumID, name: name)
            }
            _ = try await refreshUnlocked(force: true)
            return try catalog.item(id)
        }
        guard let original = record.asset, original.isMutable else { throw SyncError.unsupported }
        // Immich intentionally has no original filename rename endpoint. Do not pretend it does.
        guard filename == nil || filename == record.filename else { throw SyncError.unsupported }
        var targetAlbumID = record.albumID
        if let parentID {
            let destination = try catalog.item(parentID)
            guard destination.kind == .album || destination.kind == .library else { throw SyncError.unsupportedLocation }
            targetAlbumID = destination.albumID
        }
        var asset = original
        if let contents {
            let types = try catalog.state("mediaTypes", as: MediaTypes.self) ?? MediaTypes(image: [], video: [])
            guard types.supports(filename: original.originalFileName) else { throw SyncError.unsupported }
            let hash = try FileDigest.sha1(contents).base64EncodedString()
            let journalKey = "edit:\(original.id):\(hash)"
            var journal = try catalog.state(journalKey, as: EditJournal.self)
            if journal == nil {
                let current = try await remote.asset(original.id)
                guard !current.isTrashed, current.contentVersion == baseContentVersion else { throw SyncError.conflict }
                asset = try await remote.upload(contents, filename: original.originalFileName, progress: progress)
                if asset.id != original.id {
                    journal = EditJournal(targetID: asset.id, source: record)
                    try catalog.setState(journalKey, value: journal!)
                }
            }
            if var edit = journal {
                asset = try await remote.asset(edit.targetID)
                guard !asset.isTrashed, asset.checksum == hash else { throw SyncError.conflict }
                if !edit.associationsCopied {
                    try checkRunning(); try Task.checkCancellation()
                    try await remote.copyAssociations(from: original.id, to: asset.id)
                    edit.associationsCopied = true
                    try catalog.setState(journalKey, value: edit)
                }
                if !edit.sourceTrashed {
                    try checkRunning(); try Task.checkCancellation()
                    let current: Asset?
                    do { current = try await remote.asset(original.id) } catch SyncError.missingItem { current = nil }
                    if let current, !current.isTrashed {
                        guard current.contentVersion == baseContentVersion else { throw SyncError.conflict }
                        // Immich has no conditional delete. This final check narrows the race;
                        // the old original always goes to recoverable trash, never force delete.
                        try await remote.trash(original.id)
                    }
                    edit.sourceTrashed = true
                    try catalog.setState(journalKey, value: edit)
                }
            }
        }
        if targetAlbumID != record.albumID {
            if let targetAlbumID { try await remote.add(asset.id, to: targetAlbumID) }
            if let oldAlbumID = record.albumID { try await remote.remove(asset.id, from: oldAlbumID) }
        }
        _ = try await refreshUnlocked(force: true)
        return try catalog.item(ItemRecord.assetID(asset.id, albumID: targetAlbumID))
    }

    public func delete(id: String, baseContentVersion: Data?, recursive: Bool) async throws {
        try await gate.acquire(); defer { Task { await gate.release() } }
        try checkRunning(); try Task.checkCancellation()
        let record: ItemRecord
        do { record = try catalog.item(id) } catch SyncError.missingItem { return }
        if record.isLocalOnly {
            let descendants = try catalog.all().filter { $0.parentID == id }
            guard recursive || descendants.isEmpty else { throw SyncError.unsupportedLocation }
            // Local-only trees have no remote counterparts. Retire their rows before removing stored bytes.
            var remove = Set([id])
            let all = try catalog.all()
            var grew = true
            while grew {
                let before = remove.count
                for child in all where remove.contains(child.parentID) { remove.insert(child.id) }
                grew = before != remove.count
            }
            try catalog.replace(with: all.filter { !remove.contains($0.id) }, preserveLocal: false)
            for local in all where remove.contains(local.id) && local.kind == .ignoredFile { try? FileManager.default.removeItem(at: localURL(local.id)) }
            return
        }
        if record.kind == .album, let albumID = record.albumID {
            if !recursive, try catalog.all().contains(where: { $0.parentID == id }) { throw SyncError.unsupportedLocation }
            // Deleting an album never deletes the photos inside it.
            do { try await remote.deleteAlbum(albumID) } catch SyncError.missingItem { }
        } else if let asset = record.asset, asset.isMutable {
            if let albumID = record.albumID {
                try await remote.remove(asset.id, from: albumID)
            } else {
                let latest: Asset
                do { latest = try await remote.asset(asset.id) } catch SyncError.missingItem { return }
                if !latest.isTrashed {
                    guard baseContentVersion == nil || latest.contentVersion == baseContentVersion else { throw SyncError.conflict }
                    try await remote.trash(asset.id)
                }
            }
        } else { throw SyncError.unsupported }
        _ = try await refreshUnlocked(force: true)
    }

    private func localURL(_ id: String) throws -> URL {
        guard id.hasPrefix("ignored:"), UUID(uuidString: String(id.dropFirst(8))) != nil else { throw SyncError.missingItem }
        return catalog.localDirectory.appendingPathComponent(String(id.dropFirst(8)))
    }

    private func saveLocal(parentID: String, filename: String, contents: URL?, existing: ItemRecord? = nil) throws -> ItemRecord {
        let parent = try catalog.item(parentID)
        guard parent.isFolder, parent.kind != .root else { throw SyncError.unsupportedLocation }
        var all = try catalog.all()
        let hash = try contents.map { try FileDigest.sha1($0).base64EncodedString() } ?? existing?.localHash
        if existing == nil, let match = all.first(where: { $0.isLocalOnly && $0.parentID == parentID && $0.filename == filename && $0.localHash == hash }) {
            return match
        }
        var record = existing ?? ItemRecord(id: "ignored:" + UUID().uuidString, parentID: parentID, filename: filename,
            kind: contents == nil ? .ignoredFolder : .ignoredFile, modifiedAt: "")
        record.parentID = parentID; record.filename = filename
        record.modifiedAt = ISO8601DateFormatter().string(from: Date())
        if let contents {
            try FileManager.default.createDirectory(at: catalog.localDirectory, withIntermediateDirectories: true)
            let staging = catalog.localDirectory.appendingPathComponent(UUID().uuidString + ".staging")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: contents, to: staging)
            let destination = try localURL(record.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else { try FileManager.default.moveItem(at: staging, to: destination) }
            record.localHash = hash
            record.localSize = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
        }
        all.removeAll { $0.id == record.id }; all.append(record)
        try catalog.replace(with: all, preserveLocal: false)
        return record
    }
    private func removeLocal(_ record: ItemRecord) throws {
        try catalog.replace(with: catalog.all().filter { $0.id != record.id }, preserveLocal: false)
        if record.kind == .ignoredFile { try? FileManager.default.removeItem(at: localURL(record.id)) }
    }
}
