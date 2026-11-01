import Foundation
import XCTest
@testable import ImmichCore

actor MediaServer: ImmichMediaRemote {
    var assets: [String:[IndexedAsset]] = [:]
    var requested: [(String,String?)] = []
    var albums: [[String]] = []
    func add(_ path: String, ids: [String]) {
        assets[path] = ids.map { IndexedAsset(id: $0,originalPath: path,libraryId: "library",checksum: "",type: "IMAGE",isTrashed: false,visibility: "timeline") }
    }
    func discover() async throws -> ImmichDiscovery { ImmichDiscovery(libraries: [],samplePaths: Array(assets.keys),libraryAccessDenied: true) }
    func indexedAssets(path: String,libraryID: String?) async throws -> [IndexedAsset] { requested.append((path,libraryID)); return assets[path] ?? [] }
    func createAlbum(name: String,assetIDs: [String]) async throws -> URL { albums.append(assetIDs); return URL(string: "https://photos.example/albums/new")! }
    func createSharingLink(assetIDs: [String]) async throws -> URL { URL(string: "https://photos.example/share/new")! }
}
final class MediaActionsTests: CatalogTestCase {
    func testContainerPathsNeverGuessAnOpenCloudSpaceOrSuffixMapping() async throws {
        let file = cloud("file",["Photos","a.jpg"]), server = MediaServer()
        _ = try catalog.commit(file,parentID: "root")
        await server.add("/container/Photos/a.jpg",ids: ["asset"])
        let actions = MediaActions(remote: server)
        do { _ = try await actions.resolve(itemIDs: [file.id],catalog: catalog,mappings: []); XCTFail("Expected explicit mapping") } catch SyncError.mediaMappingRequired {}
        let requests = await server.requested; XCTAssertTrue(requests.isEmpty)
        let unrelated = try MediaMapping(spaceID: "different-space",cloudRoot: ["Photos"],immichRoot: "/container/Photos")
        do { _ = try await actions.resolve(itemIDs: [file.id],catalog: catalog,mappings: [unrelated]); XCTFail("Expected space mismatch") } catch SyncError.mediaMappingRequired {}
    }
    func testFolderAlbumsUseOnlyExistingIndexedIDsAndReportSkippedFiles() async throws {
        let folder = cloud("folder",["Photos"],directory: true), a = cloud("a",["Photos","a.jpg"]), b = cloud("b",["Photos","notes.txt"])
        _ = try catalog.commit(folder,parentID: "root"); _ = try catalog.commit(a,parentID: folder.id); _ = try catalog.commit(b,parentID: folder.id)
        let server = MediaServer(); await server.add("/media/a.jpg",ids: ["indexed-asset"])
        let mapping = try MediaMapping(spaceID: testSpace.id,cloudRoot: ["Photos"],immichRoot: "/media/",libraryID: "library")
        let actions = MediaActions(remote: server)
        let selection = try await actions.resolve(itemIDs: [folder.id,a.id],catalog: catalog,mappings: [mapping])
        XCTAssertEqual(selection.assetIDs,["indexed-asset"]); XCTAssertEqual(selection.skipped,1)
        _ = try await actions.perform(itemIDs: [folder.id],catalog: catalog,mappings: [mapping],albumName: "Photos")
        let albums = await server.albums; XCTAssertEqual(albums,[["indexed-asset"]])
        let requests = await server.requested
        XCTAssertTrue(requests.allSatisfy { $0.0.hasPrefix("/media/") && $0.1 == "library" })
    }
    func testExplicitUnindexedFilesAndAmbiguousAssetsFailWithoutCreatingAlbums() async throws {
        let file = cloud("file",["Photos","a.jpg"]); _ = try catalog.commit(file,parentID: "root")
        let server = MediaServer(), actions = MediaActions(remote: MediaServer())
        let mapping = try MediaMapping(spaceID: testSpace.id,cloudRoot: ["Photos"],immichRoot: "/media")
        do { _ = try await actions.resolve(itemIDs: [file.id],catalog: catalog,mappings: [mapping]); XCTFail("Expected not indexed") } catch SyncError.mediaNotIndexed {}
        await server.add("/media/a.jpg",ids: ["one","two"])
        do { _ = try await MediaActions(remote: server).perform(itemIDs: [file.id],catalog: catalog,mappings: [mapping],albumName: "Test"); XCTFail("Expected ambiguity") } catch SyncError.ambiguousMedia {}
        let albums = await server.albums; XCTAssertTrue(albums.isEmpty)
        do { _ = try await MediaActions(remote: server).resolve(itemIDs: [file.id],catalog: catalog,mappings: [mapping,mapping]); XCTFail("Expected mapping ambiguity") } catch SyncError.ambiguousMedia {}
    }
    func testPendingDescendantEditsPreventAlbumsFromReferencingAnOlderIndexedCopy() async throws {
        let folder = cloud("dir",["Photos"],directory: true), file = cloud("file",["Photos","a.jpg"])
        _ = try catalog.commit(folder,parentID: "root"); _ = try catalog.commit(file,parentID: folder.id)
        try catalog.saveOperation(PendingEdit(id: "pending",sourceID: file.id,parentID: folder.id,filename: "a.jpg",hash: nil,baseVersion: nil,createdAt: Date()))
        let server = MediaServer(); await server.add("/media/a.jpg",ids: ["old-indexed-asset"])
        let mapping = try MediaMapping(spaceID: testSpace.id,cloudRoot: ["Photos"],immichRoot: "/media")
        do { _ = try await MediaActions(remote: server).perform(itemIDs: [folder.id],catalog: catalog,mappings: [mapping],albumName: "Photos"); XCTFail("Expected pending-edit guard") } catch SyncError.conflict {}
        let albums = await server.albums; XCTAssertTrue(albums.isEmpty)
    }
    func testMappingUsesComponentBoundariesAndMostSpecificConfirmedRoot() throws {
        let mapping = try MediaMapping(spaceID: testSpace.id,cloudRoot: ["Photos"],immichRoot: "/container/media")
        XCTAssertNil(mapping.serverPath(for: cloud("x",["Photos-old","a.jpg"])))
        XCTAssertEqual(mapping.serverPath(for: cloud("x",["Photos","Trip","a.jpg"])),"/container/media/Trip/a.jpg")
        let unicode = try MediaMapping(spaceID: testSpace.id,cloudRoot: ["caf\u{e9}"],immichRoot: "/media")
        XCTAssertNil(unicode.serverPath(for: cloud("x",["cafe\u{301}","a.jpg"])))
        XCTAssertThrowsError(try MediaMapping(spaceID: testSpace.id,cloudRoot: [".."],immichRoot: "/media"))
        XCTAssertThrowsError(try MediaMapping(spaceID: testSpace.id,cloudRoot: [],immichRoot: "relative/media"))
        XCTAssertThrowsError(try MediaMapping(spaceID: testSpace.id,cloudRoot: [],immichRoot: "/media/../other"))
    }
    func testLibraryPermissionFailureStillDiscoversPathsAndSearchUsesExactFilters() async throws {
        let asset = IndexedAsset(id: "asset",originalPath: "/container/a.jpg",libraryId: "library",checksum: "",type: "IMAGE",isTrashed: false,visibility: "timeline")
        var paths: [String] = []
        StubProtocol.handler = { r in
            paths.append(r.url!.path)
            if r.url!.path == "/api/libraries" { return (403,[:],Data()) }
            XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"),"key"); XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String:Any]
            if let filter = body["filter"] as? [String:[String:String]] {
                XCTAssertEqual(filter["originalPath"],["eq":"/container/a.jpg"]); XCTAssertEqual(filter["libraryId"],["eq":"library"])
            }
            let bytes = try JSONSerialization.data(withJSONObject: ["assets":["items":[try JSONSerialization.jsonObject(with: JSONEncoder().encode(asset))],"nextCursor":NSNull()]])
            return (200,[:],bytes)
        }
        defer { StubProtocol.handler = nil }
        let api = ImmichAPI(serverURL: URL(string: "https://photos.example")!,token: { "key" },apiKey: true,session: stubSession())
        let discovery = try await api.discover()
        XCTAssertTrue(discovery.libraryAccessDenied); XCTAssertEqual(discovery.samplePaths,["/container/a.jpg"])
        let indexed = try await api.indexedAssets(path: "/container/a.jpg",libraryID: "library")
        XCTAssertEqual(indexed.map(\.id),["asset"])
        XCTAssertEqual(paths,["/api/libraries","/api/search/metadata","/api/search/metadata"])
    }
    func testImmichActionsOnlyPostIndexedIDsAndDisableLinkUploads() async throws {
        StubProtocol.handler = { r in
            XCTAssertEqual(r.httpMethod,"POST")
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String:Any]
            XCTAssertEqual(body["assetIds"] as? [String],["asset"])
            if r.url!.path == "/api/albums" { return (201,[:],Data("{\"id\":\"album\"}".utf8)) }
            XCTAssertEqual(r.url!.path,"/api/shared-links"); XCTAssertEqual(body["allowUpload"] as? Bool,false)
            return (201,[:],Data("{\"key\":\"sharing-key\"}".utf8))
        }
        defer { StubProtocol.handler = nil }
        let api = ImmichAPI(serverURL: URL(string: "https://photos.example")!,token: { "session" },session: stubSession())
        let album = try await api.createAlbum(name: "Test",assetIDs: ["asset"])
        let link = try await api.createSharingLink(assetIDs: ["asset"])
        XCTAssertEqual(album.path,"/albums/album"); XCTAssertEqual(link.path,"/share/sharing-key")
    }
    func testOAuthCallbackRequiresExactStateAndSingleCode() throws {
        let challenge = try OAuthChallenge()
        XCTAssertNoThrow(try challenge.validate(URL(string: "immich-sync://oauth?state=\(challenge.state)&code=code")!))
        for value in ["immich-sync://oauth?state=wrong&code=code","immich-sync://oauth?state=\(challenge.state)&code=a&code=b","immich-sync://oauth?state=\(challenge.state)&code=code#error"] {
            XCTAssertThrowsError(try challenge.validate(URL(string: value)!))
        }
    }
}
