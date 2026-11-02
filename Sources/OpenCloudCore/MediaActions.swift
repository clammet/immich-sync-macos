import Foundation

/// A user-confirmed association. POSIX paths on the Immich server are never resolved on this Mac.
public struct MediaMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var spaceID: String
    public var cloudRoot: [String]
    public var immichRoot: String
    public var libraryID: String?
    public init(spaceID: String,cloudRoot: [String],immichRoot: String,libraryID: String? = nil) throws {
        try RemotePath.validate(cloudRoot)
        guard !spaceID.isEmpty, immichRoot.hasPrefix("/"), !immichRoot.hasSuffix("//") else { throw SyncError.mediaMappingRequired }
        let root = try RemotePath.parse(immichRoot)
        self.spaceID = spaceID; self.cloudRoot = cloudRoot; self.immichRoot = "/" + root.joined(separator: "/"); self.libraryID = libraryID?.isEmpty == true ? nil : libraryID
    }
    public func serverPath(for file: CloudFile) -> String? {
        guard file.space.id == spaceID, RemotePath.contains(cloudRoot,file.path) else { return nil }
        return (immichRoot == "/" ? "" : immichRoot) + "/" + file.path.dropFirst(cloudRoot.count).joined(separator: "/")
    }
}

public struct MediaSelection: Sendable { public let assetIDs: [String]; public let skipped: Int }
public final class MediaActions: Sendable {
    private let remote: any ImmichMediaRemote
    public init(remote: any ImmichMediaRemote) { self.remote = remote }
    public func resolve(itemIDs: [String], catalog: Catalog, mappings: [MediaMapping]) async throws -> MediaSelection {
        guard !mappings.isEmpty else { throw SyncError.mediaMappingRequired }
        let records = try catalog.descendants(itemIDs)
        let treeIDs = Set(records.map(\.id))
        guard try !catalog.recoveryOperations().contains(where: { treeIDs.contains($0.sourceID ?? "") || treeIDs.contains($0.parentID) }) else { throw SyncError.conflict }
        let explicit = Set(itemIDs)
        var ids = Set<String>(), skipped = 0
        for record in records where !record.isFolder {
            try Task.checkCancellation()
            guard let file = record.remote else { continue }
            let matches = mappings.filter { $0.serverPath(for: file) != nil }
            let depth = matches.map { $0.cloudRoot.count }.max()
            let specific = matches.filter { $0.cloudRoot.count == depth }
            guard specific.count <= 1 else { throw SyncError.ambiguousMedia }
            guard let mapping = specific.first, let path = mapping.serverPath(for: file) else {
                if explicit.contains(record.id) { throw SyncError.mediaMappingRequired }
                skipped += 1; continue
            }
            let assets = try await remote.indexedAssets(path: path,libraryID: mapping.libraryID)
            guard assets.count <= 1 else { throw SyncError.ambiguousMedia }
            guard let asset = assets.first else {
                if explicit.contains(record.id) { throw SyncError.mediaNotIndexed }
                skipped += 1; continue
            }
            // Immich external libraries use SHA1("path:" + originalPath), not a
            // content digest. Only native assets have a comparable checksum.
            if asset.libraryId == nil, let checksum = file.checksum {
                let expected = Data(base64Encoded: asset.checksum)?.map { String(format: "%02x",$0) }.joined()
                guard expected?.lowercased() == checksum.lowercased() else { throw SyncError.mediaNotIndexed }
            }
            ids.insert(asset.id)
        }
        guard !ids.isEmpty else { throw SyncError.mediaNotIndexed }
        return MediaSelection(assetIDs: ids.sorted(),skipped: skipped)
    }
    public func perform(itemIDs: [String],catalog: Catalog,mappings: [MediaMapping],albumName: String?) async throws -> ActionResult {
        let selection = try await resolve(itemIDs: itemIDs,catalog: catalog,mappings: mappings)
        let url: URL
        if let albumName { url = try await remote.createAlbum(name: albumName,assetIDs: selection.assetIDs) }
        else { url = try await remote.createSharingLink(assetIDs: selection.assetIDs) }
        let action = albumName == nil ? "Immich sharing link" : "Immich album"
        return ActionResult(title: "\(action): \(selection.assetIDs.count) indexed assets; \(selection.skipped) files skipped",urls: [url])
    }
}
