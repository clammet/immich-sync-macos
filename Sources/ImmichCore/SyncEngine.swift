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

/// Serializes native sync and mutations across suspension points.
public final class SyncEngine: @unchecked Sendable {
    public let catalog: Catalog
    private let remote: any ImmichRemote
    private let account: Account
    private var completedStream = false
    private let gate = OperationGate()
    private let checkRunning: @Sendable () throws -> Void

    public init(catalog: Catalog, remote: any ImmichRemote, account: Account,
                checkRunning: @escaping @Sendable () throws -> Void = {}) throws {
        self.catalog = catalog; self.remote = remote; self.account = account; self.checkRunning = checkRunning
        try catalog.prepareSession(account.sessionID)
    }

    @discardableResult public func synchronize(force: Bool = false) async throws -> Bool {
        try await gate.acquire(); defer { Task { await gate.release() } }
        try checkRunning(); try Task.checkCancellation()
        let before = try catalog.anchor()
        var status = try catalog.state("status", as: SyncStatus.self) ?? SyncStatus()
        if !force, let date = status.lastSync, Date().timeIntervalSince(date) < SyncContract.interval,
           try catalog.pendingAcknowledgements().isEmpty { return false }
        status.syncing = true; status.message = nil
        try catalog.setState("status", value: status)
        do {
            _ = try await supportedTypes()
            // A lost ack response must be replayed before the server chooses the next change window.
            try await flushAcknowledgements()
            for attempt in 0..<2 {
                let reset = try catalog.needsServerReset
                completedStream = false
                do {
                    try await remote.synchronize(reset: reset, started: {
                        try self.checkRunning()
                        if reset { try self.catalog.acceptedReset(sessionID: self.account.sessionID) }
                    }, receive: { events in
                        try self.checkRunning(); try Task.checkCancellation()
                        if try self.catalog.apply(events, userID: self.account.userID, sessionID: self.account.sessionID) {
                            self.completedStream = true
                        }
                        try await self.flushAcknowledgements()
                    })
                    guard completedStream else { throw SyncError.invalidSyncStream }
                    return try catalog.anchor() != before
                } catch SyncError.syncReset {
                    try catalog.requestReset(sessionID: account.sessionID)
                    if attempt == 1 { throw SyncError.invalidSyncStream }
                }
            }
            throw SyncError.invalidSyncStream
        } catch {
            var failed = (try? catalog.state("status", as: SyncStatus.self)) ?? status
            failed.syncing = false; failed.message = error.localizedDescription
            try? catalog.setState("status", value: failed)
            throw error
        }
    }

    private func flushAcknowledgements() async throws {
        let pending = try catalog.pendingAcknowledgements()
        if !pending.isEmpty {
            try checkRunning()
            try await remote.acknowledge(pending)
            try catalog.acknowledged(pending, sessionID: account.sessionID)
        }
    }
    private func supportedTypes() async throws -> MediaTypes {
        if let types = try catalog.state("mediaTypes", as: MediaTypes.self) { return types }
        let types = try await remote.mediaTypes()
        try catalog.setState("mediaTypes", value: types)
        return types
    }
    private func commit(_ changes: [LocalChange]) throws {
        try checkRunning(); try Task.checkCancellation()
        try catalog.commitLocal(changes, userID: account.userID, sessionID: account.sessionID)
    }
    private func requireOwned(_ asset: Asset) throws {
        guard asset.ownerId == account.userID else { throw SyncError.invalidResponse }
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
            try commit([.album(album)])
            return try catalog.item(ItemRecord.albumID(album.id))
        }
        let parent = try catalog.item(parentID)
        guard parent.kind == .library || parent.kind == .album || parent.kind == .ignoredFolder || parent.kind == .albums else { throw SyncError.unsupportedLocation }
        let types = try await supportedTypes()
        if parent.kind == .ignoredFolder || parent.kind == .albums || !types.supports(filename: filename) {
            guard let contents else { throw SyncError.unsupported }
            return try saveLocal(parentID: parentID, filename: filename, contents: contents)
        }
        guard let contents else { throw SyncError.unsupported }
        let asset = try await remote.upload(contents, filename: filename, progress: progress)
        try requireOwned(asset)
        if let albumID = parent.albumID { try await remote.add(asset.id, to: albumID) }
        var changes: [LocalChange] = [.asset(asset)]
        if let albumID = parent.albumID { changes.append(.membership(album: albumID, asset: asset.id, present: true)) }
        try commit(changes)
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
            let types = try await supportedTypes()
            let parent = try catalog.item(destination)
            if record.kind == .ignoredFile, types.supports(filename: name), parent.kind == .library || parent.kind == .album {
                let uploaded = try await remote.upload(contents ?? localURL(id), filename: name, progress: progress)
                try requireOwned(uploaded)
                if let albumID = parent.albumID { try await remote.add(uploaded.id, to: albumID) }
                var changes: [LocalChange] = [.asset(uploaded)]
                if let albumID = parent.albumID { changes.append(.membership(album: albumID, asset: uploaded.id, present: true)) }
                try commit(changes)
                try removeLocal(record)
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
                let album = try await remote.renameAlbum(albumID, name: name)
                try commit([.album(album)])
            }
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
            let types = try await supportedTypes()
            guard types.supports(filename: original.originalFileName) else { throw SyncError.unsupported }
            let hash = try FileDigest.sha1(contents).base64EncodedString()
            let journalKey = "edit:\(original.id):\(hash)"
            var journal = try catalog.state(journalKey, as: EditJournal.self)
            if journal == nil {
                let current = try await remote.asset(original.id)
                guard !current.isTrashed, current.contentVersion == baseContentVersion else { throw SyncError.conflict }
                asset = try await remote.upload(contents, filename: original.originalFileName, progress: progress)
                try requireOwned(asset)
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
        var changes: [LocalChange] = asset.id == original.id ? [.asset(asset)] : [.replaceAsset(source: original.id, target: asset)]
        if targetAlbumID != record.albumID {
            if let targetAlbumID { changes.append(.membership(album: targetAlbumID, asset: asset.id, present: true)) }
            if let old = record.albumID { changes.append(.membership(album: old, asset: asset.id, present: false)) }
        }
        try commit(changes)
        return try catalog.item(ItemRecord.assetID(asset.id, albumID: targetAlbumID))
    }

    public func delete(id: String, baseContentVersion: Data?, recursive: Bool) async throws {
        try await gate.acquire(); defer { Task { await gate.release() } }
        try checkRunning(); try Task.checkCancellation()
        let record: ItemRecord
        do { record = try catalog.item(id) } catch SyncError.missingItem { return }
        if record.isLocalOnly {
            let removed = try catalog.removeLocalTree(id, recursive: recursive)
            for local in removed where local.kind == .ignoredFile { try? FileManager.default.removeItem(at: localURL(local.id)) }
            return
        }
        if record.kind == .album, let albumID = record.albumID {
            if !recursive, try catalog.hasChildren(id) { throw SyncError.unsupportedLocation }
            // Deleting an album never deletes the photos inside it.
            do { try await remote.deleteAlbum(albumID) } catch SyncError.missingItem { }
            try commit([.deleteAlbum(albumID)])
        } else if let asset = record.asset, asset.isMutable {
            if let albumID = record.albumID {
                try await remote.remove(asset.id, from: albumID)
                try commit([.membership(album: albumID, asset: asset.id, present: false)])
            } else {
                let latest: Asset
                do { latest = try await remote.asset(asset.id) }
                catch SyncError.missingItem { try commit([.trashAsset(asset.id)]); return }
                if !latest.isTrashed {
                    guard baseContentVersion == nil || latest.contentVersion == baseContentVersion else { throw SyncError.conflict }
                    try await remote.trash(asset.id)
                }
                try commit([.trashAsset(asset.id)])
            }
        } else { throw SyncError.unsupported }
    }

    private func localURL(_ id: String) throws -> URL {
        guard id.hasPrefix("ignored:"), UUID(uuidString: String(id.dropFirst(8))) != nil else { throw SyncError.missingItem }
        return catalog.localDirectory.appendingPathComponent(String(id.dropFirst(8)))
    }

    private func saveLocal(parentID: String, filename: String, contents: URL?, existing: ItemRecord? = nil) throws -> ItemRecord {
        let parent = try catalog.item(parentID)
        guard parent.isFolder, parent.kind != .root else { throw SyncError.unsupportedLocation }
        let siblings = try catalog.localChildren(parentID)
        let hash = try contents.map { try FileDigest.sha1($0).base64EncodedString() } ?? existing?.localHash
        if existing == nil, let match = siblings.first(where: { $0.isLocalOnly && $0.parentID == parentID && $0.filename == filename && $0.localHash == hash }) {
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
        try catalog.saveLocal(record)
        return record
    }
    private func removeLocal(_ record: ItemRecord) throws {
        _ = try catalog.removeLocalTree(record.id, recursive: false)
        if record.kind == .ignoredFile { try? FileManager.default.removeItem(at: localURL(record.id)) }
    }
}
