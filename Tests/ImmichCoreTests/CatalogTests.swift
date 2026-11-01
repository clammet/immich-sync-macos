import FileProvider
import XCTest
@testable import ImmichCore
import ImmichFileProvider

final class CatalogTests: CatalogTestCase {
    func testNamesOnlyDisambiguateRealCaseAndUnicodeCollisions() throws {
        let root = cloud("root",[],directory: true)
        _ = try catalog.commit(root,parentID: ItemRecord.rootID)
        for (id,name) in [("a",".hidden"),("b","space .txt"),("c","Photo.jpg"),("d","photo.jpg"),("e","é.txt"),("f","e\u{301}.txt")] {
            _ = try catalog.commit(cloud(id,[name]),parentID: root.id)
        }
        let children = try catalog.children(root.id)
        XCTAssertEqual(children.first { $0.remote?.fileID == "a" }?.filename,".hidden")
        XCTAssertEqual(children.first { $0.remote?.fileID == "b" }?.filename,"space .txt")
        XCTAssertEqual(children.first { $0.remote?.fileID == "c" }?.filename,"Photo.jpg")
        XCTAssertNotEqual(children.first { $0.remote?.fileID == "d" }?.filename,"photo.jpg")
        XCTAssertNotEqual(children.first { $0.remote?.fileID == "f" }?.filename,"e\u{301}.txt")
        XCTAssertEqual(children.first { $0.remote?.fileID == "d" }?.remote?.path,["photo.jpg"])
        let permitted = String(repeating: "a",count: 250)
        XCTAssertEqual(ItemRecord.localName(permitted),permitted)
    }
    func testCaseSensitiveVolumesRetainDistinctServerCaseNames() throws {
        let sensitive = try Catalog(url: directory.appendingPathComponent("case-sensitive.sqlite"),caseSensitiveNames: true)
        let root = cloud("root",[],directory: true)
        _ = try sensitive.commit(root,parentID: ItemRecord.rootID)
        let upper = try sensitive.commit(cloud("upper",["Report.txt"]),parentID: root.id)
        let lower = try sensitive.commit(cloud("lower",["report.txt"]),parentID: root.id)
        XCTAssertEqual(upper.filename,"Report.txt"); XCTAssertEqual(lower.filename,"report.txt")
        XCTAssertNotEqual(upper.id,lower.id)
    }
    func testMovedItemEmitsDepartureAndArrivalAndPagingExpires() throws {
        let root = cloud("root",[],directory: true), folder = cloud("dir",["dir"],directory: true), file = cloud("file",["a.txt"])
        _ = try catalog.commit(root,parentID: ItemRecord.rootID); _ = try catalog.commit(folder,parentID: root.id); _ = try catalog.commit(file,parentID: root.id)
        let anchor = try catalog.anchor()
        _ = try catalog.commit(cloud("file",["dir","a.txt"]),parentID: folder.id)
        let changes = try catalog.changes(since: anchor).changes.filter { $0.id == file.id }
        XCTAssertEqual(changes.map(\.parentID),[root.id,folder.id])
        XCTAssertEqual(changes.map { $0.record?.parentID },[folder.id,folder.id])
        XCTAssertThrowsError(try catalog.page(parentID: root.id,after: nil,expected: anchor))
    }
    func testProviderCapabilitiesFollowPermissionsAndFoldersAreMutable() {
        var folder = cloud("dir",["dir"],directory: true); folder.permissions = "RDNVCK"
        let writable = ProviderItem(.record(folder,parentID: "root"))
        XCTAssertTrue(writable.capabilities.contains([.allowsRenaming,.allowsReparenting,.allowsDeleting,.allowsAddingSubItems]))
        folder.permissions = "R"
        XCTAssertEqual(ProviderItem(.record(folder,parentID: "root")).capabilities,[.allowsReading])
        let file = ProviderItem(.record(cloud("file",["anything.bin"]),parentID: "root"))
        XCTAssertTrue(file.capabilities.contains([.allowsWriting,.allowsRenaming]))
    }
    func testMappingsAreBoundToTheImmichServerAndUser() throws {
        let optional = testAccount()
        let mapping = try MediaMapping(spaceID: testSpace.id,cloudRoot: ["Photos"],immichRoot: "/container")
        try catalog.saveMediaMappings([mapping],for: optional)
        XCTAssertEqual(try catalog.mediaMappings(for: optional),[mapping])
        var other = optional; other.userID = "other"
        XCTAssertTrue(try catalog.mediaMappings(for: other).isEmpty)
        other = optional; other.serverURL = URL(string: "https://another.example")!
        XCTAssertTrue(try catalog.mediaMappings(for: other).isEmpty)
    }
    func testServerAddressesRemainGenericAndRejectEmbeddedCredentials() throws {
        XCTAssertEqual(try ServerAddress("https://cloud.example/base/").apiURL.absoluteString,"https://cloud.example/base")
        XCTAssertThrowsError(try ServerAddress("https://user:secret@cloud.example"))
        XCTAssertThrowsError(try ServerAddress("http://cloud.example"))
        XCTAssertThrowsError(try ServerAddress("https://cloud.example?token=secret"))
    }
}
