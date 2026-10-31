import Darwin
import Foundation
import XCTest
@testable import ImmichCore

final class CredentialStoreTests: XCTestCase {
    private var root: URL!
    private var store: FileCredentialStore!
    private var account: Account!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        store = FileCredentialStore(directory: root.appendingPathComponent("Credentials", isDirectory: true))
        account = Account(serverURL: URL(string: "https://photos.example.com/api")!, userID: "owner",
                          displayName: "Test", email: "test@example.com", sessionID: "mac-session", allowHTTP: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRoundTripReplacementAndOwnerOnlyPermissions() throws {
        try store.save("first-token", for: account)
        let file = try credentialFile()
        XCTAssertEqual(try store.read(for: account), "first-token")
        try store.save("second-token", for: account)
        XCTAssertEqual(try store.read(for: account), "second-token")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700); XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 1)
        if try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
            // Some macOS releases report false even after Foundation writes the Time Machine marker.
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes {
                getxattr(store.directory.path, "com.apple.metadata:com_apple_backup_excludeItem", $0.baseAddress, $0.count, 0, 0)
            }
            XCTAssertGreaterThan(count, 0)
            if count > 0 {
                let marker = try PropertyListSerialization.propertyList(from: Data(buffer.prefix(count)), format: nil)
                XCTAssertEqual(marker as? String, "com.apple.backupd")
            }
        }
    }

    func testCredentialIsBoundToServerUserAccountAndSession() throws {
        try store.save("secret-token", for: account)
        for change: (inout Account) -> Void in [
            { $0.serverURL = URL(string: "https://other.example.com/api")! },
            { $0.userID = "other-owner" },
            { $0.id = UUID().uuidString },
        ] {
            var other = account!
            change(&other)
            assertUnsafe { _ = try self.store.read(for: other) }
        }
        var otherSession = account!
        otherSession.sessionID = "other-session"
        XCTAssertThrowsError(try store.read(for: otherSession)) { error in
            guard case SyncError.missingAccount = error else { return XCTFail("Expected absent session") }
        }
    }

    func testMissingAndRepeatedDeletionDoNotCreateStorage() throws {
        try store.delete(for: account)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertThrowsError(try store.read(for: account)) { error in
            guard case SyncError.missingAccount = error else { return XCTFail("Expected missing credential") }
        }
        try store.save("secret-token", for: account)
        try store.delete(for: account)
        try store.delete(for: account)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    func testDeletingPreviousSessionPreservesReplacement() throws {
        try store.save("old-token", for: account)
        var replacement = account!
        replacement.sessionID = "new-session"
        try store.save("new-token", for: replacement)
        try store.delete(for: account)
        XCTAssertEqual(try store.read(for: replacement), "new-token")
    }

    func testUnsafeTokensNeverReplaceExistingCredential() throws {
        try store.save("old-token", for: account)
        for token in ["", "token\r\nInjected: header", "token with spaces", String(repeating: "x", count: 16 * 1024 + 1)] {
            assertUnsafe { try self.store.save(token, for: self.account) }
            XCTAssertEqual(try store.read(for: account), "old-token")
        }
    }

    func testCorruptAndOversizedFilesAreRejected() throws {
        try store.save("secret-token", for: account)
        let file = try credentialFile()
        for bytes in [Data("not json".utf8), Data(repeating: 0, count: 64 * 1024 + 1)] {
            try bytes.write(to: file)
            assertUnsafe { _ = try self.store.read(for: self.account) }
        }
        try store.delete(for: account)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSessionIdentifierCannotEscapeCredentialsDirectory() throws {
        account.sessionID = "../../outside"
        try store.save("secret-token", for: account)
        XCTAssertEqual(try store.read(for: account), "secret-token")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Credentials"])
    }

    func testSymlinkDirectoryIsRejectedWithoutTouchingTarget() throws {
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: outside)
        assertUnsafe { try self.store.save("secret-token", for: self.account) }
        assertUnsafe { _ = try self.store.read(for: self.account) }
        assertUnsafe { try self.store.delete(for: self.account) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testSymlinkFileIsRejectedWithoutTouchingTarget() throws {
        try store.save("secret-token", for: account)
        let file = try credentialFile(), outside = root.appendingPathComponent("Outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        assertUnsafe { try self.store.save("replacement", for: self.account) }
        assertUnsafe { _ = try self.store.read(for: self.account) }
        try store.delete(for: account)
        XCTAssertEqual(try String(contentsOf: outside), "untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testHardLinkedFileIsRejected() throws {
        try store.save("secret-token", for: account)
        let file = try credentialFile(), link = root.appendingPathComponent("OtherLink")
        try FileManager.default.linkItem(at: file, to: link)
        assertUnsafe { _ = try self.store.read(for: self.account) }
        assertUnsafe { try self.store.save("replacement", for: self.account) }
        try store.delete(for: account)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testBroadFileAndDirectoryPermissionsAreRejected() throws {
        try store.save("secret-token", for: account)
        let file = try credentialFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        assertUnsafe { _ = try self.store.read(for: self.account) }
        assertUnsafe { try self.store.save("replacement", for: self.account) }
        try store.delete(for: account)
        try store.save("secret-token", for: account)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path)
        assertUnsafe { _ = try self.store.read(for: self.account) }
        assertUnsafe { try self.store.save("replacement", for: self.account) }
    }

    func testSubstitutedFIFOIsRejectedWithoutBlocking() throws {
        try store.save("secret-token", for: account)
        let file = try credentialFile()
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, mode_t(0o600)), 0)
        assertUnsafe { _ = try self.store.read(for: self.account) }
        assertUnsafe { try self.store.save("replacement", for: self.account) }
    }

    func testExtendedACLIsRejectedDespiteOwnerOnlyMode() throws {
        try store.save("secret-token", for: account)
        let file = try credentialFile()
        var acl = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        let ace = try XCTUnwrap(entry)
        XCTAssertEqual(acl_set_tag_type(ace, ACL_EXTENDED_ALLOW), 0)
        var qualifier = UUID().uuid
        XCTAssertEqual(withUnsafePointer(to: &qualifier) { acl_set_qualifier(ace, $0) }, 0)
        var permissions: acl_permset_t?
        XCTAssertEqual(acl_get_permset(ace, &permissions), 0)
        XCTAssertEqual(acl_add_perm(try XCTUnwrap(permissions), ACL_READ_DATA), 0)
        XCTAssertEqual(acl_set_file(file.path, ACL_TYPE_EXTENDED, try XCTUnwrap(acl)), 0)
        assertUnsafe { _ = try self.store.read(for: self.account) }
        assertUnsafe { try self.store.save("replacement", for: self.account) }
    }

    func testConcurrentReadersOnlySeeCompleteReplacements() throws {
        let store = store!, account = account!, lock = NSLock()
        var failures = 0
        try store.save("x", for: account)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                if index.isMultiple(of: 2) {
                    try store.save(String(repeating: "x", count: index + 1), for: account)
                } else {
                    let token = try store.read(for: account)
                    if token.isEmpty || !token.allSatisfy({ $0 == "x" }) { lock.withLock { failures += 1 } }
                }
            } catch { lock.withLock { failures += 1 } }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 1)
    }

    private func credentialFile() throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.directory,
                                                               includingPropertiesForKeys: nil).first)
    }

    private func assertUnsafe(_ work: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            guard case SyncError.credentialStorage = error else {
                return XCTFail("Expected credential-storage safety check", file: file, line: line)
            }
        }
    }
}
