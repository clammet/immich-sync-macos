import Foundation

public enum SyncContract { public static let interval: TimeInterval = 60 }

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

/// The content file and this manifest are retained until the server result is committed locally.
public struct PendingEdit: Codable, Sendable {
    public let id: String
    public let sourceID: String?
    public let parentID: String
    public let filename: String
    public let hash: String?
    public let baseVersion: Data?
    public let createdAt: Date
    public var uploaded: CloudFile?
}

public final class SyncEngine: @unchecked Sendable {
    public let catalog: Catalog
    private let remote: any OpenCloudRemote
    private let gate = OperationGate()
    private let checkRunning: @Sendable () throws -> Void
    public init(catalog: Catalog, remote: any OpenCloudRemote, account: Account,
                checkRunning: @escaping @Sendable () throws -> Void = {}) throws {
        self.catalog = catalog; self.remote = remote; self.checkRunning = checkRunning
    }
    private func check() throws { try checkRunning(); try Task.checkCancellation() }

    @discardableResult public func synchronize(force: Bool = false) async throws -> Bool {
        try await gate.acquire(); defer { Task { await gate.release() } }
        try check()
        let lease = try catalog.acquireSyncLock(); defer { catalog.releaseSyncLock(lease) }
        var status = try catalog.state("status", as: SyncStatus.self) ?? SyncStatus()
        if !force, let last = status.lastSync, Date().timeIntervalSince(last) < SyncContract.interval { return false }
        let before = try catalog.anchor()
        status.syncing = true; status.message = nil
        try catalog.setState("status",value: status)
        do {
            let token = try catalog.beginSnapshot()
            let spaces = try await remote.spaces()
            var visited = Set<String>()
            for space in spaces {
                let root = try await remote.properties(space: space,path: [])
                guard root.isDirectory else { throw SyncError.invalidResponse }
                try catalog.stage([.record(root,parentID: ItemRecord.rootID)],token: token)
                try await scan(root,token: token,visited: &visited)
            }
            try check()
            // A concurrent change in membership must not publish a partial set of spaces.
            guard try await remote.spaces().sorted(by: { $0.id < $1.id }) == spaces.sorted(by: { $0.id < $1.id }) else { throw SyncError.conflict }
            try catalog.publishSnapshot(token)
            return try catalog.anchor() != before
        } catch {
            status.syncing = false; status.message = error.localizedDescription
            try? catalog.setState("status",value: status)
            throw error
        }
    }
    private func scan(_ folder: CloudFile, token: String, visited: inout Set<String>) async throws {
        try check()
        guard folder.path.count < 256, visited.insert(folder.id).inserted else { throw SyncError.invalidResponse }
        let children = try await remote.children(folder)
        try catalog.stage(children.map { .record($0,parentID: folder.id) },token: token)
        for child in children where child.isDirectory { try await scan(child,token: token,visited: &visited) }
        let after = try await remote.properties(space: folder.space,path: folder.path)
        guard after.fileID == folder.fileID, after.etag == folder.etag else { throw SyncError.conflict }
    }
    private func current(_ record: ItemRecord, version: Data? = nil) async throws -> CloudFile {
        guard let known = record.remote else { throw SyncError.unsupportedLocation }
        let current = try await remote.properties(space: known.space,path: known.path)
        guard current.id == known.id, version.map({ Data(current.etag.utf8) == $0 }) ?? true else { throw SyncError.conflict }
        return current
    }
    public func download(id: String, directory: URL, progress: Progress, requestedVersion: Data? = nil) async throws -> (URL,ItemRecord) {
        try check()
        let record = try catalog.item(id)
        let file = try await current(record,version: requestedVersion ?? record.contentVersion)
        guard !file.isDirectory else { throw SyncError.unsupported }
        let url = try await remote.download(file,into: directory,progress: progress)
        do {
            try check()
            let current = try catalog.item(id)
            guard current.contentVersion == Data(file.etag.utf8) else { throw SyncError.conflict }
            return (url,current)
        }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    public func thumbnail(id: String, large: Bool) async throws -> Data? { nil }

    private func contentURL(_ edit: PendingEdit) -> URL {
        catalog.localDirectory.appendingPathComponent(edit.id,isDirectory: true).appendingPathComponent("content",isDirectory: true).appendingPathComponent(ItemRecord.localName(edit.filename))
    }
    private func save(_ edit: PendingEdit) throws {
        try catalog.saveOperation(edit)
        let directory = catalog.localDirectory.appendingPathComponent(edit.id,isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(edit).write(to: directory.appendingPathComponent("operation.json"),options: .atomic)
    }
    private func stage(sourceID: String?, parentID: String, filename: String, contents: URL?, baseVersion: Data?) throws -> PendingEdit {
        let hash = try contents.map { try FileDigest.sha256($0).map { String(format: "%02x",$0) }.joined() }
        let key = RemotePath.digest([sourceID ?? "create",parentID,filename,hash ?? "directory",baseVersion?.base64EncodedString() ?? ""].joined(separator: "\0"))
        if let existing = try catalog.operation(key) { return existing }
        let edit = PendingEdit(id: key,sourceID: sourceID,parentID: parentID,filename: filename,hash: hash,baseVersion: baseVersion,createdAt: Date())
        let folder = catalog.localDirectory.appendingPathComponent(key,isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        if let contents {
            let staged = contentURL(edit)
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(),withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
            let temporary = folder.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: contents,to: temporary)
            let file = try FileHandle(forWritingTo: temporary)
            try file.synchronize(); try file.close()
            // An interrupted staging operation may leave a file without a database entry.
            if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
            try FileManager.default.moveItem(at: temporary,to: staged)
        }
        try save(edit)
        return edit
    }
    private func finish(_ edit: PendingEdit) throws {
        try catalog.finishOperation(edit.id)
        try? FileManager.default.removeItem(at: catalog.localDirectory.appendingPathComponent(edit.id,isDirectory: true))
    }
    public func create(parentID: String, filename: String, directory: Bool, contents: URL?, progress: Progress) async throws -> ItemRecord {
        try await gate.acquire(); defer { Task { await gate.release() } }
        let lease = try catalog.acquireSyncLock(); defer { catalog.releaseSyncLock(lease) }
        try RemotePath.validate([filename])
        guard directory || contents != nil else { throw SyncError.unsupported }
        // Stage before checking connectivity, pause, or parent availability.
        var edit = try stage(sourceID: nil,parentID: parentID,filename: filename,contents: contents,baseVersion: nil)
        try check()
        let parent = try await current(catalog.item(parentID))
        let file: CloudFile
        if let uploaded = edit.uploaded {
            file = try await remote.properties(space: uploaded.space,path: uploaded.path)
            guard file.id == uploaded.id, file.etag == uploaded.etag else { throw SyncError.conflict }
        } else {
            file = try await directory ? remote.makeDirectory(parent: parent,name: filename) : remote.put(parent: parent,name: filename,contents: contentURL(edit),replacing: nil,progress: progress)
            edit.uploaded = file; try save(edit)
        }
        let record = try catalog.commit(file,parentID: parentID)
        try finish(edit)
        return record
    }
    public func modify(id: String, baseContentVersion: Data, filename: String?, parentID: String?, contents: URL?, progress: Progress) async throws -> ItemRecord {
        try await gate.acquire(); defer { Task { await gate.release() } }
        let lease = try catalog.acquireSyncLock(); defer { catalog.releaseSyncLock(lease) }
        // Preserve bytes even if the remote item was removed while this edit was offline.
        let cached = try? catalog.item(id)
        let targetParent = parentID ?? cached?.parentID ?? ItemRecord.rootID
        let targetName = filename ?? cached?.remote?.name ?? "Recovered edit"
        if let filename { try RemotePath.validate([filename]) }
        var edit = try stage(sourceID: id,parentID: targetParent,filename: targetName,contents: contents,baseVersion: baseContentVersion)
        try check()
        guard let record = cached, let known = record.remote, !known.path.isEmpty else { throw SyncError.conflict }
        var file: CloudFile
        if let uploaded = edit.uploaded {
            file = try await remote.properties(space: uploaded.space,path: uploaded.path)
            guard file.id == uploaded.id, file.etag == uploaded.etag else { throw SyncError.conflict }
        } else {
            do { file = try await current(record,version: baseContentVersion) }
            catch SyncError.missingItem { throw SyncError.conflict }
            if contents != nil {
                let originalParent = try await current(catalog.item(record.parentID))
                file = try await remote.put(parent: originalParent,name: known.name,contents: contentURL(edit),replacing: file,progress: progress)
                edit.uploaded = file; try save(edit)
            }
        }
        let parent = try await current(catalog.item(targetParent))
        let name = filename == nil || filename == record.filename ? known.name : targetName
        if !RemotePath.equal(file.path,parent.path + [name]) {
            file = try await remote.move(file,parent: parent,name: name)
            edit.uploaded = file; try save(edit)
        }
        let updated = try catalog.commit(file,parentID: targetParent)
        try finish(edit)
        return updated
    }
    public func delete(id: String, baseContentVersion: Data?, recursive: Bool) async throws {
        try await gate.acquire(); defer { Task { await gate.release() } }
        try check()
        let lease = try catalog.acquireSyncLock(); defer { catalog.releaseSyncLock(lease) }
        let record: ItemRecord
        do { record = try catalog.item(id) } catch SyncError.missingItem { return }
        let descendants = try catalog.descendants([id])
        let ids = Set(descendants.map(\.id))
        guard recursive || descendants.count <= 1 else { throw SyncError.unsupportedLocation }
        guard try !catalog.recoveryOperations().contains(where: { ids.contains($0.sourceID ?? "") || ids.contains($0.parentID) }) else { throw SyncError.conflict }
        let file = try await current(record,version: baseContentVersion ?? record.contentVersion)
        do { try await remote.delete(file) } catch SyncError.missingItem { }
        try catalog.removeTree(id)
    }
    public func createSharingLink(id: String) async throws -> URL { try check(); return try await remote.createLink(current(catalog.item(id))) }
    public func sharingPage(id: String) async throws -> URL { try check(); return try await remote.webURL(current(catalog.item(id))) }
}
