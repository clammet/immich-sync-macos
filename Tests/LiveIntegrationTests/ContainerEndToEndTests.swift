import Foundation
import XCTest
@testable import ImmichCore

/// Only the container runner enables these tests. Each test owns one disposable
/// remote directory and independent on-disk catalogs, with no OS provider setup.
class ContainerTestCase: XCTestCase {
    let env = ProcessInfo.processInfo.environment
    var api: OpenCloudAPI!
    var account: Account!
    var space: CloudSpace!
    var folder: ItemRecord!
    var catalog: Catalog!
    var engine: SyncEngine!
    var work: URL!

    override func setUp() async throws {
        guard env["CONTAINER_E2E"] == "1" else {
            throw XCTSkip("Run python3 scripts/container-e2e.py for disposable OpenCloud/Immich tests")
        }
        let address = try loopback("OPENCLOUD_TEST_SERVER")
        let username = try required("OPENCLOUD_TEST_USERNAME"), token = try required("OPENCLOUD_TEST_TOKEN")
        api = OpenCloudAPI(serverURL: address, username: username, token: { token })
        let user = try await api.user()
        let spaces = try await api.spaces()
        let spaceID = try required("OPENCLOUD_TEST_SPACE")
        space = try XCTUnwrap(spaces.first { $0.id == spaceID })
        account = Account(serverURL: address, userID: user.id, displayName: username, email: username,
                          sessionID: UUID().uuidString, allowHTTP: true)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("container-e2e-" + UUID().uuidString)
        catalog = try Catalog(url: work.appendingPathComponent("catalog.sqlite"))
        engine = try SyncEngine(catalog: catalog, remote: api, account: account)
        try await engine.synchronize(force: true)
        let root = try await api.properties(space: space, path: [])
        folder = try await engine.create(parentID: root.id, filename: "e2e-" + UUID().uuidString,
                                         directory: true, contents: nil, progress: Progress())
    }

    override func tearDown() async throws {
        defer { if let work { try? FileManager.default.removeItem(at: work) } }
        if let remote = folder?.remote {
            let current = try await api.properties(space: space, path: remote.path)
            try await api.delete(current)
        }
    }

    func required(_ key: String) throws -> String { try XCTUnwrap(env[key], "Missing \(key)") }
    func loopback(_ key: String) throws -> URL {
        let url = try ServerAddress(required(key), allowHTTP: true).apiURL
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
            throw SyncError.invalidServer
        }
        return url
    }
    func content(_ bytes: Data) throws -> URL {
        let url = work.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return url
    }
    func create(_ name: String, parent: ItemRecord? = nil, bytes: Data? = nil) async throws -> ItemRecord {
        try await engine.create(parentID: (parent ?? folder).id, filename: name, directory: bytes == nil,
                                contents: bytes.map { try content($0) }, progress: Progress())
    }
    func assertBytes(_ item: ItemRecord, equal expected: Data, using other: SyncEngine? = nil,
                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let (url, downloaded) = try await (other ?? engine).download(id: item.id, directory: work, progress: Progress())
        XCTAssertEqual(downloaded.id, item.id, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), expected, file: file, line: line)
    }
    func expectConflict(_ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        do { try await operation(); XCTFail("Expected a conditional conflict", file: file, line: line) }
        catch SyncError.conflict { }
    }
    func immichLogin(email: String? = nil) async throws -> (ImmichAPI, SessionLogin) {
        let url = try loopback("IMMICH_TEST_SERVER")
        let login = try await ImmichAPI(serverURL: url).login(email: email ?? required("IMMICH_TEST_EMAIL"),
                                                           password: required("IMMICH_TEST_PASSWORD"))
        XCTAssertFalse(login.shouldChangePassword)
        let token = login.accessToken
        return (ImmichAPI(serverURL: url, token: { token }), login)
    }
    func json(_ api: ImmichAPI, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let request = try api.request(path, method: method, body: body.map { try JSONSerialization.data(withJSONObject: $0) })
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.validate(response)
        return data.isEmpty ? NSNull() : try JSONSerialization.jsonObject(with: data)
    }
}

final class ContainerEndToEndTests: ContainerTestCase {
    func testTUSResumesLostPATCHReplyAfterCatalogAndClientReopen() async throws {
        let original = try await create("resume.txt",bytes: Data("original".utf8))
        let bytes = Data("abcdefgh".utf8), source = try content(bytes)
        let token = try required("OPENCLOUD_TEST_TOKEN")
        let fault = TUSLostReplyProtocol.Fault()
        TUSLostReplyProtocol.fault = fault
        defer { TUSLostReplyProtocol.fault = nil }
        func client() -> OpenCloudAPI {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [TUSLostReplyProtocol.self]
            return OpenCloudAPI(serverURL: account.serverURL,username: account.email,token: { token },
                                session: URLSession(configuration: config),uploadChunkSize: 2)
        }
        let interrupted = try SyncEngine(catalog: catalog,remote: client(),account: account)
        do {
            _ = try await interrupted.modify(id: original.id,baseContentVersion: original.contentVersion,
                                             filename: nil,parentID: nil,contents: source,progress: Progress())
            XCTFail("Expected the first accepted PATCH response to be lost")
        } catch is URLError { }
        try FileManager.default.removeItem(at: source)
        let reopened = try Catalog(url: work.appendingPathComponent("catalog.sqlite"))
        let pending = try XCTUnwrap(reopened.recoveryOperations().first)
        XCTAssertNil(pending.uploaded)
        let recovery = reopened.localDirectory.appendingPathComponent(pending.id)
        let checkpoint = try JSONDecoder().decode(TUSUploadCheckpoint.self,from: Data(contentsOf: recovery.appendingPathComponent("upload.json")))
        XCTAssertNotNil(checkpoint.location)
        XCTAssertFalse(checkpoint.accepted)
        let preserved = recovery.appendingPathComponent("content").appendingPathComponent(pending.filename)
        XCTAssertEqual(try Data(contentsOf: preserved),bytes)
        // Polling can update cached metadata while an upload is pending. The
        // checkpoint must remain bound to the original base, not that snapshot.
        let observed = try await api.properties(space: space,path: original.remote!.path)
        _ = try reopened.commit(observed,parentID: folder.id)
        let restarted = try SyncEngine(catalog: reopened,remote: client(),account: account)
        let resumed = try await restarted.modify(id: original.id,baseContentVersion: original.contentVersion,
                                                 filename: nil,parentID: nil,contents: preserved,progress: Progress())
        try await assertBytes(resumed,equal: bytes,using: restarted)
        XCTAssertEqual(fault.postCount,1,"A restart must reuse the recorded TUS session")
        XCTAssertEqual(fault.patchOffsets,["0","2","4","6"],"The accepted first chunk must not be sent twice")
        XCTAssertTrue(try reopened.recoveryOperations().isEmpty)
    }

    func testTUSCanReplaceExistingFileWithEmptyContent() async throws {
        let original = try await create("empty-edit.txt",bytes: Data("nonempty".utf8))
        let edited = try await engine.modify(id: original.id,baseContentVersion: original.contentVersion,
                                            filename: nil,parentID: nil,contents: content(Data()),progress: Progress())
        XCTAssertEqual(edited.id,original.id)
        XCTAssertEqual(edited.remote?.size,0)
        try await assertBytes(edited,equal: Data())
        XCTAssertTrue(try catalog.recoveryOperations().isEmpty)
    }
    func testUploadedEditResumesFailedMoveFromDurableManifest() async throws {
        let original = try await create("source.txt", bytes: Data("before".utf8))
        let blocker = try await create("destination.txt", bytes: Data("occupied".utf8))
        let bytes = Data("uploaded before the failed move".utf8), source = try content(bytes)
        try await expectConflict {
            _ = try await self.engine.modify(id: original.id, baseContentVersion: original.contentVersion,
                                             filename: blocker.filename, parentID: nil, contents: source, progress: Progress())
        }
        let reopened = try Catalog(url: work.appendingPathComponent("catalog.sqlite"))
        let pending = try XCTUnwrap(reopened.recoveryOperations().first)
        let uploaded = try XCTUnwrap(pending.uploaded)
        XCTAssertEqual(uploaded.id, original.id)
        XCTAssertNotEqual(uploaded.etag, original.remote?.etag)
        let preserved = reopened.localDirectory.appendingPathComponent(pending.id)
            .appendingPathComponent("content").appendingPathComponent(blocker.filename)
        XCTAssertEqual(try Data(contentsOf: preserved), bytes)
        try await api.delete(try XCTUnwrap(blocker.remote))
        let restarted = try SyncEngine(catalog: reopened, remote: api, account: account)
        let resumed = try await restarted.modify(id: original.id, baseContentVersion: original.contentVersion,
                                                 filename: blocker.filename, parentID: nil, contents: source, progress: Progress())
        XCTAssertEqual(resumed.id, original.id)
        XCTAssertEqual(resumed.remote?.etag, uploaded.etag, "Retry must move the recorded upload without uploading it again")
        try await assertBytes(resumed, equal: bytes, using: restarted)
        XCTAssertTrue(try reopened.recoveryOperations().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.path))
    }

    func testSyncRoundTripExactPathsRemoteMovesAndDeletion() async throws {
        let nested = try await create("Nested folder")
        let cases: [(String, Data)] = [
            (".hidden", Data("dotfile".utf8)), ("café #%?.txt", Data("Unicode and URL punctuation".utf8)),
            ("binary.bin", Data((0...255).map(UInt8.init))), ("empty.txt", Data())
        ]
        var files: [ItemRecord] = []
        for (name, bytes) in cases {
            let item = try await create(name, parent: nested, bytes: bytes)
            XCTAssertEqual(item.remote?.path, folder.remote!.path + [nested.filename, name])
            XCTAssertEqual(item.filename, name)
            try await assertBytes(item, equal: bytes)
            files.append(item)
        }
        let secondCatalog = try Catalog(url: work.appendingPathComponent("second/catalog.sqlite"))
        let second = try SyncEngine(catalog: secondCatalog, remote: api, account: account)
        try await second.synchronize(force: true)
        XCTAssertEqual(Set(try secondCatalog.children(nested.id).map(\.id)), Set(files.map(\.id)))
        for (index, item) in files.enumerated() { try await assertBytes(item, equal: cases[index].1, using: second) }
        let anchor = try secondCatalog.anchor()
        let changed = try await second.synchronize(force: true)
        XCTAssertFalse(changed)
        XCTAssertEqual(try secondCatalog.anchor(), anchor)

        let edited = try await engine.modify(id: files[0].id, baseContentVersion: files[0].contentVersion,
                                            filename: "renamed.txt", parentID: folder.id,
                                            contents: content(Data("updated bytes".utf8)), progress: Progress())
        XCTAssertEqual(edited.id, files[0].id)
        try await assertBytes(edited, equal: Data("updated bytes".utf8))
        // Rename the directory on a second DAV client, then discover it by polling.
        let current = try await api.properties(space: space, path: nested.remote!.path)
        let moved = try await api.move(current, parent: folder.remote!, name: "Moved # folder")
        try await engine.synchronize(force: true)
        XCTAssertEqual(moved.id, nested.id)
        for item in files.dropFirst() {
            XCTAssertEqual(try catalog.item(item.id).remote?.path, moved.path + [item.filename])
        }
        let link = try await engine.createSharingLink(id: edited.id)
        XCTAssertEqual(link.host, account.serverURL.host)
        let folderLink = try await engine.createSharingLink(id: nested.id)
        XCTAssertEqual(folderLink.host, account.serverURL.host)
        let web = try await engine.sharingPage(id: edited.id)
        XCTAssertEqual(web.host, account.serverURL.host)
        // A new catalog handle must see committed content and deletion events.
        let reopened = try Catalog(url: work.appendingPathComponent("catalog.sqlite"))
        XCTAssertEqual(try reopened.item(edited.id).remote, edited.remote)
        try await engine.delete(id: edited.id, baseContentVersion: edited.contentVersion, recursive: false)
        try await second.synchronize(force: true)
        XCTAssertThrowsError(try secondCatalog.item(edited.id))
        let events = try secondCatalog.changes(since: anchor)
        XCTAssertTrue(events.changes.contains { $0.id == edited.id && $0.record == nil })
        try await engine.delete(id: nested.id, baseContentVersion: nil, recursive: true)
        XCTAssertThrowsError(try catalog.item(files[1].id))
        XCTAssertTrue(try catalog.recoveryOperations().isEmpty)
    }

    func testStalePreconditionsAndDurableRecoveryAcrossClients() async throws {
        let original = try await create("conflict.txt", bytes: Data("original".utf8))
        let stale = try XCTUnwrap(original.remote)
        let other = OpenCloudAPI(serverURL: account.serverURL, username: account.email, token: { [env] in env["OPENCLOUD_TEST_TOKEN"]! })
        let latest = try await other.upload(parent: folder.remote!, name: original.filename,
                                         contents: content(Data("second client's version".utf8)), replacing: stale, progress: Progress())
        XCTAssertNotEqual(latest.etag, stale.etag)
        let local = Data("offline edit to preserve".utf8), source = try content(local)
        try await expectConflict { _ = try await self.api.upload(parent: self.folder.remote!, name: original.filename,
                                                              contents: source, replacing: stale, progress: Progress()) }
        try await expectConflict {
            _ = try await self.engine.modify(id: original.id, baseContentVersion: original.contentVersion,
                                             filename: nil, parentID: nil, contents: source, progress: Progress())
        }
        try FileManager.default.removeItem(at: source)
        let reopened = try Catalog(url: work.appendingPathComponent("catalog.sqlite"))
        let pending = try XCTUnwrap(reopened.recoveryOperations().first)
        XCTAssertEqual(try reopened.recoveryOperations().count, 1)
        XCTAssertEqual(pending.sourceID, original.id)
        let recovery = reopened.localDirectory.appendingPathComponent(pending.id)
        let manifest = try JSONDecoder().decode(PendingEdit.self, from: Data(contentsOf: recovery.appendingPathComponent("operation.json")))
        XCTAssertEqual(manifest.hash, pending.hash)
        let preserved = recovery.appendingPathComponent("content").appendingPathComponent(original.filename)
        XCTAssertEqual(try Data(contentsOf: preserved), local)
        let restarted = try SyncEngine(catalog: reopened, remote: api, account: account)
        try await restarted.synchronize(force: true)
        try await assertBytes(try reopened.item(original.id), equal: Data("second client's version".utf8), using: restarted)
        try await expectConflict { try await restarted.delete(id: self.folder.id, baseContentVersion: nil, recursive: true) }
        let recovered = try await restarted.create(parentID: folder.id, filename: "recovered.txt", directory: false,
                                                   contents: preserved, progress: Progress())
        try await assertBytes(recovered, equal: local, using: restarted)
        try reopened.finishOperation(pending.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertTrue(try reopened.recoveryOperations().isEmpty)
    }

    func testKnownOpenCloudStaleDeletePreconditionGap() async throws {
        let original = try await create("stale-delete.txt", bytes: Data("before".utf8))
        _ = try await api.upload(parent: folder.remote!, name: original.filename, contents: content(Data("newer".utf8)),
                              replacing: original.remote, progress: Progress())
        var rejected = false
        do { try await api.delete(try XCTUnwrap(original.remote)) }
        catch SyncError.conflict { rejected = true }
        // Strict expected failures keep the upstream safety gap visible and fail
        // on an unexpected pass when a future server release fixes the behavior.
        XCTExpectFailure("OpenCloud 9.0.0 ignores If-Match on DELETE; a newer revision can be deleted") {
            XCTAssertTrue(rejected, "The server must reject a stale conditional DELETE")
        }
    }

    func testKnownOpenCloudConditionalCreatePreconditionGap() async throws {
        let original = try await create("occupied.txt", bytes: Data("existing content".utf8))
        var rejected = false
        do {
            _ = try await api.upload(parent: folder.remote!, name: original.filename, contents: content(Data("new create".utf8)),
                                  replacing: nil, progress: Progress())
        } catch SyncError.conflict { rejected = true }
        XCTExpectFailure("OpenCloud 9.0.0 ignores If-None-Match on TUS creation; a create can overwrite an existing file") {
            XCTAssertTrue(rejected, "The server must reject creation at an occupied path")
        }
    }

    func testKnownOpenCloudStaleMovePreconditionGap() async throws {
        let original = try await create("stale-move.txt", bytes: Data("before".utf8))
        _ = try await api.upload(parent: folder.remote!, name: original.filename, contents: content(Data("newer".utf8)),
                              replacing: original.remote, progress: Progress())
        var rejected = false
        do { _ = try await api.move(try XCTUnwrap(original.remote), parent: folder.remote!, name: "moved-newer.txt") }
        catch SyncError.conflict { rejected = true }
        XCTExpectFailure("OpenCloud 9.0.0 ignores If-Match on MOVE; a newer revision can be moved") {
            XCTAssertTrue(rejected, "The server must reject a stale conditional MOVE")
        }
    }

    func testImmichIndexesOpenCloudOriginalsAndActionsReuseAssetIDs() async throws {
        let (immich, login) = try await immichLogin()
        let identity = try await immich.identity()
        XCTAssertEqual(identity.id, login.userId)
        let session = try await immich.currentSessionID()
        XCTAssertFalse(session.isEmpty)
        let libraryID = try required("IMMICH_TEST_LIBRARY")
        let root = try required("IMMICH_TEST_ROOT") + "/" + folder.filename
        let mapping = try MediaMapping(spaceID: space.id, cloudRoot: folder.remote!.path, immichRoot: root, libraryID: libraryID)
        try catalog.saveMediaMappings([mapping], for: account)
        let mappings = try catalog.mediaMappings(for: account)
        let nested = try await create("Trip #1")
        let excludedFolder = try await create("excluded")
        let red = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "red", withExtension: "png", subdirectory: "Fixtures")))
        let blue = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "blue", withExtension: "png", subdirectory: "Fixtures")))
        let first = try await create("café #1.png", bytes: red)
        let second = try await create("blue.png", parent: nested, bytes: blue)
        let note = try await create("notes.txt", bytes: Data("not media".utf8))
        let excluded = try await create("excluded.png", parent: excludedFolder, bytes: red)
        let actions = MediaActions(remote: immich)
        do { _ = try await actions.resolve(itemIDs: [first.id], catalog: catalog, mappings: mappings); XCTFail("Unscanned asset must fail") }
        catch SyncError.mediaNotIndexed { }
        _ = try await json(immich, "libraries/\(libraryID)/scan", method: "POST", body: [:])
        // Immich indexes asynchronously; poll the real search API with a bounded deadline.
        let deadline = Date().addingTimeInterval(120)
        var indexed: [IndexedAsset] = []
        repeat {
            let redAssets = try await immich.indexedAssets(path: root + "/" + first.filename, libraryID: libraryID)
            let blueAssets = try await immich.indexedAssets(path: root + "/Trip #1/blue.png", libraryID: libraryID)
            indexed = redAssets + blueAssets
            if indexed.count == 2 { break }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        XCTAssertEqual(indexed.count, 2, "External library failed to index OpenCloud's POSIX originals")
        let expectedIDs = Set(indexed.map(\.id))
        let discovery = try await immich.discover()
        XCTAssertFalse(discovery.libraryAccessDenied)
        let libraryRoot = try required("IMMICH_TEST_ROOT")
        XCTAssertTrue(discovery.libraries.contains { $0.id == libraryID && $0.importPaths == [libraryRoot] })
        XCTAssertTrue(discovery.samplePaths.contains(root + "/" + first.filename))
        XCTAssertNotNil(first.remote?.checksum)
        let selection = try await actions.resolve(itemIDs: [folder.id, first.id], catalog: catalog, mappings: mappings)
        XCTAssertEqual(Set(selection.assetIDs), expectedIDs)
        XCTAssertEqual(selection.skipped, 2, "Text and excluded media must be reported")
        for item in [note, excluded] {
            do { _ = try await actions.resolve(itemIDs: [item.id], catalog: catalog, mappings: mappings); XCTFail("Explicit unindexed selection must fail") }
            catch SyncError.mediaNotIndexed { }
        }
        let wrong = try MediaMapping(spaceID: space.id, cloudRoot: folder.remote!.path, immichRoot: root + "-wrong", libraryID: libraryID)
        do { _ = try await actions.resolve(itemIDs: [first.id], catalog: catalog, mappings: [wrong]); XCTFail("Wrong prefix must fail") }
        catch SyncError.mediaNotIndexed { }
        do { _ = try await actions.resolve(itemIDs: [first.id], catalog: catalog, mappings: [mapping, mapping]); XCTFail("Ambiguous mapping must fail") }
        catch SyncError.ambiguousMedia { }
        let album = try await actions.perform(itemIDs: [folder.id], catalog: catalog, mappings: mappings, albumName: "E2E originals")
        let albumID = try XCTUnwrap(album.urls.first).lastPathComponent
        let albumResponse = try await json(immich, "albums/\(albumID)")
        let albumBody = try XCTUnwrap(albumResponse as? [String: Any])
        XCTAssertEqual(albumBody["assetCount"] as? Int, expectedIDs.count)
        let albumSearch = try await json(immich, "search/metadata", method: "POST",
                                         body: ["filter": ["albumIds": ["any": [albumID]]], "size": 100, "withExif": false])
        let albumSearchBody = try XCTUnwrap(albumSearch as? [String: Any])
        let albumAssets = try XCTUnwrap((albumSearchBody["assets"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(Set(albumAssets.compactMap { $0["id"] as? String }), expectedIDs)
        for (item, bytes) in [(first, red), (second, blue)] {
            let path = try XCTUnwrap(mapping.serverPath(for: XCTUnwrap(item.remote)))
            let asset = try XCTUnwrap(indexed.first { $0.originalPath == path })
            let (originalBytes, response) = try await URLSession.shared.data(for: immich.request("assets/\(asset.id)/original"))
            try HTTPClient.validate(response)
            XCTAssertEqual(originalBytes, bytes, "Immich must serve the original bytes uploaded through OpenCloud")
        }
        let link = try await actions.perform(itemIDs: [first.id, second.id], catalog: catalog, mappings: mappings, albumName: nil)
        let key = try XCTUnwrap(link.urls.first).lastPathComponent
        let linksResponse = try await json(immich, "shared-links")
        let links = try XCTUnwrap(linksResponse as? [[String: Any]])
        let summary = try XCTUnwrap(links.first { $0["key"] as? String == key })
        let sharedID = try XCTUnwrap(summary["id"] as? String)
        // The list endpoint returns only the cover asset. Link details include
        // originals after Immich's asynchronous metadata extraction completes.
        let metadataDeadline = Date().addingTimeInterval(120)
        var shared: [String: Any] = [:], sharedIDs = Set<String>()
        repeat {
            let sharedResponse = try await json(immich, "shared-links/\(sharedID)")
            shared = try XCTUnwrap(sharedResponse as? [String: Any])
            sharedIDs = Set((shared["assets"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            if sharedIDs == expectedIDs { break }
            try await Task.sleep(for: .seconds(1))
        } while Date() < metadataDeadline
        XCTAssertEqual(shared["allowUpload"] as? Bool, false)
        XCTAssertEqual(sharedIDs, expectedIDs)
        // Inspect all assets after the actions: exactly the two external originals,
        // with no native uploads or duplicate copies created as a side effect.
        let allResponse = try await json(immich, "search/metadata", method: "POST", body: ["size": 1000, "withExif": false])
        let all = try XCTUnwrap(allResponse as? [String: Any])
        let assets = try XCTUnwrap((all["assets"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(Set(assets.compactMap { $0["id"] as? String }), expectedIDs)
        XCTAssertTrue(assets.allSatisfy { $0["libraryId"] as? String == libraryID })

        let apiKeyResponse = try await json(immich, "api-keys", method: "POST", body: ["name": "E2E", "permissions": ["all"]])
        let apiKeyBody = try XCTUnwrap(apiKeyResponse as? [String: Any])
        let apiKey = try XCTUnwrap(apiKeyBody["secret"] as? String)
        let keyed = ImmichAPI(serverURL: try loopback("IMMICH_TEST_SERVER"), token: { apiKey }, apiKey: true)
        let keyedAssets = try await keyed.indexedAssets(path: root + "/" + first.filename, libraryID: libraryID)
        XCTAssertEqual(Set(keyedAssets.map(\.id)), Set(indexed.filter { $0.originalPath == root + "/" + first.filename }.map(\.id)))
        let (reader, _) = try await immichLogin(email: "reader@example.test")
        let readerDiscovery = try await reader.discover()
        XCTAssertTrue(readerDiscovery.libraryAccessDenied)
        XCTAssertTrue(readerDiscovery.libraries.isEmpty)
        try await reader.logout()
        try await immich.logout()
        do { _ = try await immich.identity(); XCTFail("Logged out session must be rejected") }
        catch SyncError.http(401, _) { }
    }
}

final class ContainerImmichOfflineTests: ContainerTestCase {
    func testOpenCloudCreateEditMoveShareDownloadAndDeleteWhileImmichIsStopped() async throws {
        let url = try loopback("IMMICH_TEST_SERVER")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: url.appendingPathComponent("api/server/ping"))
            XCTFail("Runner must stop the Immich container before this phase")
        } catch is URLError { }
        let original = try await create("ordinary.txt", bytes: Data("without Immich".utf8))
        let edited = try await engine.modify(id: original.id, baseContentVersion: original.contentVersion,
                                            filename: "renamed.txt", parentID: nil,
                                            contents: content(Data("still works".utf8)), progress: Progress())
        try await engine.synchronize(force: true)
        try await assertBytes(edited, equal: Data("still works".utf8))
        let link = try await engine.createSharingLink(id: edited.id)
        XCTAssertNotNil(link.host)
        try await engine.delete(id: edited.id, baseContentVersion: edited.contentVersion, recursive: false)
        XCTAssertThrowsError(try catalog.item(edited.id))
        XCTAssertTrue(try catalog.recoveryOperations().isEmpty)
    }
}
