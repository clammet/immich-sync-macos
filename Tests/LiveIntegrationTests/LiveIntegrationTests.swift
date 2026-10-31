import Foundation
import ImageIO
import XCTest
@testable import ImmichCore

/// Opt-in only: scripts/integration.py supplies an isolated localhost stack and fixtures.
final class LiveIntegrationTests: XCTestCase {
    struct Configuration: Decodable {
        let port: Int
        let email: String
        let adminEmail: String
        let password: String
    }
    struct Seed: Decodable {
        let assets: [String]
        let hidden: String
        let foreign: String
        let album: String
        let external: [String]
        let userID: String
    }

    func testEndToEnd() async throws {
        guard let statePath = ProcessInfo.processInfo.environment["IMMICH_INTEGRATION_STATE"] else {
            throw XCTSkip("Run python3 scripts/integration.py test against the disposable stack")
        }
        let state = URL(fileURLWithPath: statePath, isDirectory: true)
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: state.appendingPathComponent("config.json")))
        let seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: state.appendingPathComponent("seed.json")))
        let base = try ServerAddress("http://127.0.0.1:\(config.port)", allowHTTP: true).apiURL
        let anonymous = ImmichAPI(serverURL: base)
        try await anonymous.version().requireSupported()
        do {
            _ = try await anonymous.login(email: config.email, password: "incorrect-password")
            XCTFail("Rejected password was accepted")
        } catch SyncError.http(401, _) { }
        let login = try await anonymous.login(email: config.email, password: config.password)
        XCTAssertFalse(login.shouldChangePassword)
        XCTAssertEqual(login.userId, seed.userID)
        let api = ImmichAPI(serverURL: base, token: { login.accessToken })
        let sessionID = try await api.currentSessionID()
        let account = Account(serverURL: base, userID: login.userId, displayName: login.name,
                              email: login.userEmail, sessionID: sessionID, allowHTTP: true)
        // Every run gets an isolated local catalog. No App Group or personal File Provider domain is touched.
        let local = state.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let credentials = FileCredentialStore(directory: local.appendingPathComponent("Credentials"))
        try credentials.save(login.accessToken, for: account)
        XCTAssertEqual(try credentials.read(for: account), login.accessToken)
        let credentialDirectory = local.appendingPathComponent("Credentials")
        let permissions = try FileManager.default.attributesOfItem(atPath: credentialDirectory.path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: credentialDirectory, includingPropertiesForKeys: nil) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        }
        XCTAssertEqual(try credentialDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let remote = ObservedRemote(api)
        let catalogURL = local.appendingPathComponent("catalog.sqlite")
        var catalog = try Catalog(url: catalogURL)
        var engine = try SyncEngine(catalog: catalog, remote: remote, account: account)
        _ = try await engine.synchronize(force: true)
        XCTAssertFalse(try catalog.isBootstrapping)
        XCTAssertTrue(try catalog.pendingAcknowledgements().isEmpty)
        for id in seed.assets + seed.external {
            XCTAssertEqual(try catalog.item(ItemRecord.assetID(id)).asset?.id, id)
        }
        XCTAssertThrowsError(try catalog.item(ItemRecord.assetID(seed.hidden)))
        XCTAssertThrowsError(try catalog.item(ItemRecord.assetID(seed.foreign)))
        let initial = try allItems(catalog)
        XCTAssertTrue(initial.contains { $0.kind == .externalFolder })
        for id in seed.external {
            XCTAssertFalse(try catalog.item(ItemRecord.assetID(id)).isMutable)
        }
        XCTAssertEqual(try catalog.item(ItemRecord.assetID(seed.assets[0], albumID: seed.album)).albumID, seed.album)
        print("PASS authentication, credential storage, bootstrap, ownership/locked filtering, folders, membership")

        let downloads = local.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let original = try catalog.item(ItemRecord.assetID(seed.assets[0]))
        let (download, downloadedRecord) = try await engine.download(id: original.id, directory: downloads, progress: progress())
        XCTAssertEqual(downloadedRecord.id, original.id)
        XCTAssertEqual(try FileDigest.sha1(download).base64EncodedString(), original.asset?.checksum)
        XCTAssertEqual(try Data(contentsOf: download), try Data(contentsOf: state.appendingPathComponent("media/synthetic-0.png")))
        var thumbnail: Data?
        for _ in 0..<30 {
            thumbnail = try? await engine.thumbnail(id: original.id, large: false)
            if thumbnail != nil { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let image = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(thumbnail) as CFData, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(image), 0)
        var corrupt = original.asset!
        // A well-formed but wrong server checksum must never produce a delivered file.
        let encoded = try JSONEncoder().encode(corrupt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["checksum"] = Data(repeating: 0, count: 20).base64EncodedString()
        corrupt = try JSONDecoder().decode(Asset.self, from: JSONSerialization.data(withJSONObject: object))
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: downloads.path).count
        do { _ = try await api.download(corrupt, into: downloads, progress: progress()); XCTFail("Corrupt checksum accepted") }
        catch SyncError.invalidResponse { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count, beforeFiles)

        // Settle asynchronous extraction events, then prove an idle native stream does no path search.
        for _ in 0..<10 {
            let calls = remote.pathCalls
            _ = try await engine.synchronize(force: true)
            if calls == remote.pathCalls { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let idleCalls = remote.pathCalls
        let idleAnchor = try catalog.anchor()
        _ = try await engine.synchronize(force: true)
        XCTAssertEqual(remote.pathCalls, idleCalls)
        XCTAssertEqual(try catalog.anchor(), idleAnchor)
        let skipped = try await engine.synchronize()
        XCTAssertFalse(skipped)
        print("PASS byte-exact/checksum-verified downloads, corruption rejection, idle stream/path requests")

        // Server-side changes must be discovered through native sync, independent of local commitLocal.
        let incremental = try await api.upload(state.appendingPathComponent("media/synthetic-5.png"), filename: "incremental.png", progress: progress())
        try await api.add(incremental.id, to: seed.album)
        _ = try await api.renameAlbum(seed.album, name: "Server rename")
        _ = try await engine.synchronize(force: true)
        XCTAssertEqual(try catalog.item(ItemRecord.assetID(incremental.id)).asset?.checksum, incremental.checksum)
        XCTAssertTrue(try catalog.item(ItemRecord.albumID(seed.album)).filename.hasPrefix("Server rename"))
        XCTAssertEqual(try catalog.item(ItemRecord.assetID(incremental.id, albumID: seed.album)).asset?.id, incremental.id)
        try catalog.pin(original.id, value: true)

        let createdAlbum = try await engine.create(parentID: ItemRecord.albumsID, filename: "Client album", directory: true, contents: nil, progress: progress())
        let uploaded = try await engine.create(parentID: createdAlbum.id, filename: "upload.png", directory: false,
                                               contents: state.appendingPathComponent("media/synthetic-6.png"), progress: progress())
        let uploadedAsset = try XCTUnwrap(uploaded.asset)
        XCTAssertEqual(try FileDigest.sha1(state.appendingPathComponent("media/synthetic-6.png")).base64EncodedString(), uploadedAsset.checksum)
        let duplicate = try await api.upload(state.appendingPathComponent("media/synthetic-6.png"), filename: "duplicate.png", progress: progress())
        XCTAssertEqual(duplicate.id, uploadedAsset.id)
        var members = try await membership(api, albumID: createdAlbum.albumID!)
        XCTAssertTrue(members.contains(uploadedAsset.id))
        _ = try await engine.modify(id: createdAlbum.id, baseContentVersion: createdAlbum.contentVersion,
                                    filename: "Client renamed", parentID: nil, contents: nil, progress: progress())
        let serverAlbum = try await json(api, "albums/\(createdAlbum.albumID!)")
        XCTAssertEqual(serverAlbum["albumName"] as? String, "Client renamed")
        let moved = try await engine.modify(id: uploaded.id, baseContentVersion: uploaded.contentVersion, filename: nil,
                                            parentID: ItemRecord.albumID(seed.album), contents: nil, progress: progress())
        members = try await membership(api, albumID: createdAlbum.albumID!)
        XCTAssertFalse(members.contains(uploadedAsset.id))
        members = try await membership(api, albumID: seed.album)
        XCTAssertTrue(members.contains(uploadedAsset.id))
        try await engine.delete(id: moved.id, baseContentVersion: moved.contentVersion, recursive: false)
        let afterMembershipRemoval = try await api.asset(uploadedAsset.id)
        XCTAssertFalse(afterMembershipRemoval.isTrashed)
        try await engine.delete(id: createdAlbum.id, baseContentVersion: nil, recursive: true)
        let albumList = try await jsonValue(api, "albums")
        let serverAlbums = try XCTUnwrap(albumList as? [[String: Any]])
        XCTAssertFalse(serverAlbums.contains { $0["id"] as? String == createdAlbum.albumID })
        let afterAlbumDeletion = try await api.asset(uploadedAsset.id)
        XCTAssertFalse(afterAlbumDeletion.isTrashed)
        print("PASS incremental assets/albums, client upload/deduplication, album rename/move/removal/deletion")

        // A separate login/catalog proves the client mutations actually reached the server.
        let observerLogin = try await anonymous.login(email: config.email, password: config.password)
        let observerAPI = ImmichAPI(serverURL: base, token: { observerLogin.accessToken })
        let observerAccount = Account(serverURL: base, userID: login.userId, displayName: login.name,
            email: login.userEmail, sessionID: try await observerAPI.currentSessionID(), allowHTTP: true)
        let observer = try Catalog(url: local.appendingPathComponent("observer/catalog.sqlite"))
        let observerEngine = try SyncEngine(catalog: observer, remote: observerAPI, account: observerAccount)
        _ = try await observerEngine.synchronize(force: true)
        XCTAssertEqual(try observer.item(ItemRecord.assetID(uploadedAsset.id)).asset?.checksum, uploadedAsset.checksum)
        XCTAssertThrowsError(try observer.item(createdAlbum.id))

        _ = try await json(api, "assets/\(original.asset!.id)", method: "PUT", body: ["isFavorite": true])
        // Interrupt after copy succeeds; the persisted edit journal must resume without another upload.
        remote.loseCopyResponse = true
        let replacement = state.appendingPathComponent("media/synthetic-7.png")
        do {
            _ = try await engine.modify(id: original.id, baseContentVersion: original.contentVersion, filename: nil,
                                        parentID: nil, contents: replacement, progress: progress())
            XCTFail("Expected lost copy response")
        } catch Injected.failure { }
        let uploadsBeforeResume = remote.uploadCalls
        catalog = try Catalog(url: catalogURL)
        engine = try SyncEngine(catalog: catalog, remote: remote, account: account)
        let edited = try await engine.modify(id: original.id, baseContentVersion: original.contentVersion, filename: nil,
                                             parentID: nil, contents: replacement, progress: progress())
        XCTAssertEqual(remote.uploadCalls, uploadsBeforeResume)
        XCTAssertNotEqual(edited.asset?.id, original.asset?.id)
        let trashedSource = try await api.asset(original.asset!.id)
        XCTAssertTrue(trashedSource.isTrashed)
        let editedServer = try await json(api, "assets/\(edited.asset!.id)")
        XCTAssertEqual(editedServer["isFavorite"] as? Bool, true)
        members = try await membership(api, albumID: seed.album)
        XCTAssertTrue(members.contains(edited.asset!.id))
        XCTAssertEqual(try catalog.pinned(edited.id), true)
        try await engine.delete(id: edited.id, baseContentVersion: edited.contentVersion, recursive: false)
        let trashedEdit = try await api.asset(edited.asset!.id)
        XCTAssertTrue(trashedEdit.isTrashed)
        XCTAssertThrowsError(try catalog.item(edited.id))
        _ = try await json(api, "trash/restore/assets", method: "POST", body: ["ids": [edited.asset!.id]])
        _ = try await engine.synchronize(force: true)
        XCTAssertEqual(try catalog.item(edited.id).asset?.id, edited.asset?.id)
        print("PASS replacement edit/copy recovery after catalog restart, associations, pins, trash/restore")

        let localText = local.appendingPathComponent("notes.txt")
        try Data("Local-only notes".utf8).write(to: localText)
        let ignored = try await engine.create(parentID: ItemRecord.libraryID, filename: "notes.txt", directory: false, contents: localText, progress: progress())
        XCTAssertTrue(ignored.isLocalOnly)
        let stableID = ItemRecord.assetID(incremental.id)
        let stableParent = try catalog.item(stableID).parentID
        // Commit a real stream batch but lose the server acknowledgement response.
        _ = try await api.upload(state.appendingPathComponent("media/synthetic-8.png"), filename: "ack-recovery.png", progress: progress())
        remote.loseAckResponse = true
        do { _ = try await engine.synchronize(force: true); XCTFail("Expected lost ack response") }
        catch Injected.failure { }
        XCTAssertFalse(try catalog.pendingAcknowledgements().isEmpty)
        catalog = try Catalog(url: catalogURL)
        engine = try SyncEngine(catalog: catalog, remote: remote, account: account)
        _ = try await engine.synchronize(force: true)
        XCTAssertTrue(try catalog.pendingAcknowledgements().isEmpty)
        XCTAssertFalse(try catalog.isBootstrapping)
        let interrupted = try await api.upload(state.appendingPathComponent("media/synthetic-9.png"), filename: "stream-recovery.png", progress: progress())
        remote.interruptStream = true
        do { _ = try await engine.synchronize(force: true); XCTFail("Expected interrupted stream") }
        catch Injected.failure { }
        XCTAssertEqual(try catalog.item(stableID).parentID, stableParent)
        _ = try await engine.synchronize(force: true)
        XCTAssertEqual(try catalog.item(ItemRecord.assetID(interrupted.id)).asset?.checksum, interrupted.checksum)
        _ = try await json(api, "sync/ack", method: "DELETE", body: [:])
        _ = try await engine.synchronize(force: true)
        XCTAssertEqual(try catalog.item(stableID).parentID, stableParent)
        try catalog.requestReset(sessionID: account.sessionID)
        _ = try await engine.synchronize(force: true)
        XCTAssertTrue(try catalog.item(ignored.id).isLocalOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        // Permanent server deletion must retire every local appearance (the client never force-deletes).
        _ = try await json(api, "assets", method: "DELETE", body: ["ids": [uploadedAsset.id], "force": true])
        _ = try await engine.synchronize(force: true)
        XCTAssertThrowsError(try catalog.item(ItemRecord.assetID(uploadedAsset.id)))
        let rebuilt = try Catalog(url: local.appendingPathComponent("rebuilt/catalog.sqlite"))
        let rebuiltEngine = try SyncEngine(catalog: rebuilt, remote: api, account: account)
        _ = try await rebuiltEngine.synchronize(force: true)
        XCTAssertEqual(try rebuilt.item(stableID).asset?.id, incremental.id)
        print("PASS lost acknowledgement replay, interrupted stream, reset, missing catalog rebuild, local retention")

        try stack("server-stop", state: state)
        do {
            do { _ = try await engine.synchronize(force: true); XCTFail("Sync succeeded during outage") }
            catch {
                let network = error as NSError
                XCTAssertEqual(network.domain, NSURLErrorDomain)
                XCTAssertTrue([NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                               NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet].contains(network.code))
            }
            XCTAssertEqual(try catalog.item(stableID).asset?.id, incremental.id)
            let (offlineFile, _) = try await engine.download(id: ignored.id, directory: downloads, progress: progress())
            XCTAssertEqual(try Data(contentsOf: offlineFile), Data("Local-only notes".utf8))
        } catch {
            try stack("server-start", state: state)
            throw error
        }
        try stack("server-start", state: state)
        _ = try await engine.synchronize(force: true)
        XCTAssertEqual(try catalog.item(stableID).asset?.id, incremental.id)
        let status = try XCTUnwrap(catalog.state("status", as: SyncStatus.self))
        XCTAssertNil(status.message)
        XCTAssertFalse(status.syncing)
        // Session revocation is real; cached metadata remains readable while network auth fails.
        try await api.logout()
        do { _ = try await api.currentSessionID(); XCTFail("Revoked session accepted") }
        catch SyncError.http(401, _) { }
        try credentials.delete(for: account)
        XCTAssertThrowsError(try credentials.read(for: account))
        XCTAssertEqual(try catalog.item(stableID).asset?.id, incremental.id)
        for suffix in ["", "-wal", "-shm"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: catalogURL.path + suffix)) {
                XCTAssertNil(data.range(of: Data(login.accessToken.utf8)))
                XCTAssertNil(data.range(of: Data(config.password.utf8)))
            }
        }
        try await observerAPI.logout()
        print("PASS real container outage/restart, offline local content, revocation/disconnect, catalog secret exclusion")
    }

    private func progress() -> Progress { Progress(totalUnitCount: 1) }
    private func membership(_ api: ImmichAPI, albumID: String) async throws -> Set<String> {
        let response = try await json(api, "search/metadata", method: "POST", body: ["filter": ["albumIds": ["any": [albumID]]], "size": 100])
        let assets = try XCTUnwrap(response["assets"] as? [String: Any])
        XCTAssertTrue(assets["nextCursor"] == nil || assets["nextCursor"] is NSNull)
        return Set((assets["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    }
    private func allItems(_ catalog: Catalog) throws -> [ItemRecord] {
        var result: [ItemRecord] = [], cursor: String?
        repeat {
            let page = try catalog.page(parentID: nil, after: cursor, expected: nil)
            result += page.items; cursor = page.next
        } while cursor != nil
        return result
    }
    private func json(_ api: ImmichAPI, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let value = try await jsonValue(api, path, method: method, body: body)
        return try XCTUnwrap(value as? [String: Any])
    }
    private func jsonValue(_ api: ImmichAPI, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let request = try api.request(path, method: method, body: body.map { try JSONSerialization.data(withJSONObject: $0) })
        let (data, response) = try await URLSession.shared.data(for: request)
        try ImmichAPI.validate(response)
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data)
    }
    private func stack(_ command: String, state: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["IMMICH_INTEGRATION_PYTHON"]))
        let root = state.deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = [root.appendingPathComponent("scripts/integration.py").path, command]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Stack command \(command) failed")
    }
}

private enum Injected: Error { case failure }

/// Faults wrap real HTTP operations; no fake remote state or responses are used.
private final class ObservedRemote: ImmichRemote, @unchecked Sendable {
    let api: ImmichAPI
    var pathCalls = 0
    var uploadCalls = 0
    var loseAckResponse = false
    var loseCopyResponse = false
    var interruptStream = false
    init(_ api: ImmichAPI) { self.api = api }
    func synchronize(reset: Bool, started: @escaping @Sendable () async throws -> Void,
                     receive: @escaping @Sendable ([SyncEvent]) async throws -> Void) async throws {
        try await api.synchronize(reset: reset, started: started, receive: { events in
            if self.interruptStream {
                self.interruptStream = false
                let partial = events.filter { $0.kind != .complete }
                if !partial.isEmpty { try await receive(partial) }
                throw Injected.failure
            }
            try await receive(events)
        })
    }
    func acknowledge(_ acks: [String]) async throws {
        try await api.acknowledge(acks)
        if loseAckResponse { loseAckResponse = false; throw Injected.failure }
    }
    func assetPaths(ids: [String]) async throws -> [Asset] { pathCalls += 1; return try await api.assetPaths(ids: ids) }
    func upload(_ file: URL, filename: String, progress: Progress) async throws -> Asset {
        uploadCalls += 1; return try await api.upload(file, filename: filename, progress: progress)
    }
    func copyAssociations(from sourceID: String, to targetID: String) async throws {
        try await api.copyAssociations(from: sourceID, to: targetID)
        if loseCopyResponse { loseCopyResponse = false; throw Injected.failure }
    }
    func mediaTypes() async throws -> MediaTypes { try await api.mediaTypes() }
    func asset(_ id: String) async throws -> Asset { try await api.asset(id) }
    func download(_ asset: Asset, into directory: URL, progress: Progress) async throws -> URL { try await api.download(asset, into: directory, progress: progress) }
    func thumbnail(_ assetID: String, large: Bool) async throws -> Data { try await api.thumbnail(assetID, large: large) }
    func createAlbum(name: String) async throws -> Album { try await api.createAlbum(name: name) }
    func renameAlbum(_ id: String, name: String) async throws -> Album { try await api.renameAlbum(id, name: name) }
    func deleteAlbum(_ id: String) async throws { try await api.deleteAlbum(id) }
    func add(_ assetID: String, to albumID: String) async throws { try await api.add(assetID, to: albumID) }
    func remove(_ assetID: String, from albumID: String) async throws { try await api.remove(assetID, from: albumID) }
    func trash(_ assetID: String) async throws { try await api.trash(assetID) }
}
