import CryptoKit
import Foundation
@testable import ImmichCore

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func testAccount(sessionID: String = "mac-session") -> Account {
    Account(serverURL: URL(string: "https://photos.example.com/api")!, userID: "owner", displayName: "Test",
        email: "test@example.com", sessionID: sessionID, allowHTTP: false)
}
func makeAsset(_ id: String = "one", checksum: String = "original", libraryID: String? = nil, trashed: Bool = false, path: String? = nil) -> Asset {
    Asset(id: id, ownerId: "owner", originalFileName: "photo.jpg", checksum: checksum,
        type: "IMAGE", fileCreatedAt: "2026-01-01T00:00:00Z", fileModifiedAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z", isTrashed: trashed, visibility: "timeline", libraryId: libraryID, exifInfo: nil, originalPath: path)
}
func makeAlbum(_ id: String = "album", name: String = "Holiday") -> Album {
    Album(id: id, albumName: name, updatedAt: "2026-01-01T00:00:00Z", albumUsers: [.init(role: "owner", user: .init(id: "owner"))])
}
func wireLine(_ kind: String, _ data: [String: Any] = [:], sequence: Int = 1, checkpoint: String? = nil) throws -> Data {
    let id = String(format: "00000000-0000-7000-8000-%012d", sequence)
    let ack = kind == "SyncResetV1" ? "SyncResetV1|reset" : (checkpoint ?? kind) + "|" + id
    var line = try JSONSerialization.data(withJSONObject: ["type": kind, "data": data, "ack": ack], options: [.sortedKeys])
    line.append(10)
    return line
}
func event(_ kind: String, _ data: [String: Any] = [:], sequence: Int = 1, checkpoint: String? = nil) throws -> SyncEvent {
    try JSONDecoder().decode(SyncEvent.self, from: wireLine(kind, data, sequence: sequence, checkpoint: checkpoint))
}
func assetData(_ id: String = "one", name: String = "photo.jpg", checksum: String = "original", trashed: Bool = false) -> [String: Any] {
    ["id": id, "ownerId": "owner", "originalFileName": name, "checksum": checksum, "type": "IMAGE",
     "fileCreatedAt": "2026-01-01T00:00:00Z", "fileModifiedAt": "2026-01-01T00:00:00Z", "createdAt": "2026-01-01T00:00:00Z",
     "deletedAt": trashed ? "2026-10-29T00:00:00Z" as Any : NSNull(), "visibility": "timeline", "libraryId": NSNull()]
}
func bootstrap(_ id: String = "one", sequence: Int = 1) throws -> [SyncEvent] {
    try [event("AssetV2", assetData(id), sequence: sequence),
         event("AlbumV2", ["id": "album", "name": "Holiday", "updatedAt": "2026-01-01T00:00:00Z"], sequence: sequence),
         event("AlbumUserV1", ["albumId": "album", "userId": "owner", "role": "owner"], sequence: sequence),
         event("AlbumToAssetV1", ["albumId": "album", "assetId": id], sequence: sequence),
         event("AssetExifV1", ["assetId": id, "fileSizeInByte": 4096], sequence: sequence),
         event("SyncCompleteV1", sequence: sequence)]
}
func initializedCatalog(_ folder: URL, sessionID: String = "mac-session") throws -> Catalog {
    let catalog = try Catalog(url: folder.appendingPathComponent("catalog.sqlite"))
    try catalog.prepareSession(sessionID); try catalog.acceptedReset(sessionID: sessionID)
    return catalog
}
func apply(_ catalog: Catalog, _ events: [SyncEvent], sessionID: String = "mac-session") throws {
    try catalog.apply(events, userID: "owner", sessionID: sessionID)
}

final class FakeRemote: ImmichRemote, @unchecked Sendable {
    struct Stream { var batches: [[SyncEvent]]; var failure: SyncError? = nil }
    var streams: [Stream] = []
    var assets = [makeAsset()]
    var events: [String] = []
    var pathRequests: [[String]] = []
    var pathFails = false
    var downloadCount = 0
    var uploadPath: String? = nil
    var afterDownload: (() throws -> Void)?
    var afterPaths: (() throws -> Void)?
    var resets: [Bool] = []
    var ackAttempts: [[String]] = []
    var failAck = false
    var copyFails = false
    var trashResponseFails = false
    var afterAck: (() throws -> Void)?
    var synchronizeCount: Int { resets.count }
    func synchronize(reset: Bool, started: @escaping @Sendable () async throws -> Void,
                     receive: @escaping @Sendable ([SyncEvent]) async throws -> Void) async throws {
        resets.append(reset)
        try await started()
        let stream = streams.isEmpty ? Stream(batches: [try [event("SyncCompleteV1", sequence: 2)]]) : streams.removeFirst()
        for batch in stream.batches { try await receive(batch) }
        if let failure = stream.failure { throw failure }
    }
    func acknowledge(_ acks: [String]) async throws {
        ackAttempts.append(acks)
        try afterAck?()
        if failAck { failAck = false; throw SyncError.http(503, retryAfter: nil) }
    }
    func mediaTypes() async throws -> MediaTypes { MediaTypes(image: [".jpg", ".heic", ".arw"], video: [".mov"]) }
    func asset(_ id: String) async throws -> Asset {
        guard let asset = assets.first(where: { $0.id == id }) else { throw SyncError.missingItem }; return asset
    }
    func assetPaths(ids: [String]) async throws -> [Asset] {
        pathRequests.append(ids)
        if pathFails { throw SyncError.http(503, retryAfter: nil) }
        let result = assets.filter { ids.contains($0.id) }
        try afterPaths?()
        return result
    }
    func upload(_ file: URL, filename: String, progress: Progress) async throws -> Asset {
        events.append("upload")
        let result = makeAsset("edited", checksum: try FileDigest.sha1(file).base64EncodedString(), path: uploadPath)
        assets.append(result); return result
    }
    func download(_ asset: Asset, into directory: URL, progress: Progress) async throws -> URL {
        downloadCount += 1
        try afterDownload?()
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data("original".utf8).write(to: file)
        return file
    }
    func thumbnail(_ assetID: String, large: Bool) async throws -> Data { Data("preview".utf8) }
    func createAlbum(name: String) async throws -> Album { events.append("create-album"); return makeAlbum("new-album", name: name) }
    func renameAlbum(_ id: String, name: String) async throws -> Album { events.append("rename-album"); return makeAlbum(id, name: name) }
    func deleteAlbum(_ id: String) async throws { events.append("delete-album") }
    func add(_ assetID: String, to albumID: String) async throws { events.append("add:\(assetID):\(albumID)") }
    func remove(_ assetID: String, from albumID: String) async throws { events.append("remove:\(assetID):\(albumID)") }
    func copyAssociations(from sourceID: String, to targetID: String) async throws {
        events.append("copy:\(sourceID):\(targetID)"); if copyFails { throw SyncError.http(503, retryAfter: nil) }
    }
    func trash(_ assetID: String) async throws {
        events.append("trash:\(assetID)")
        assets = assets.map { value in var value = value; if value.id == assetID { value.isTrashed = true }; return value }
        if trashResponseFails { trashResponseFails = false; throw SyncError.http(503, retryAfter: nil) }
    }
}
