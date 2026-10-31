import CryptoKit
import Darwin
import Foundation

public enum CredentialStore {
    private static func store() throws -> FileCredentialStore {
        FileCredentialStore(directory: try SharedStore.directory.appendingPathComponent("Credentials", isDirectory: true))
    }

    public static func save(_ token: String, for account: Account) throws {
        try store().save(token, for: account)
    }

    public static func read(for account: Account) throws -> String {
        try store().read(for: account)
    }

    public static func delete(for account: Account) throws {
        try store().delete(for: account)
    }
}

/// The containing app writes credentials; the provider reads them independently of the app's lifetime.
/// Container authorization separates apps; POSIX permissions additionally exclude other user accounts.
struct FileCredentialStore {
    let directory: URL
    private static let maximumFileSize = 64 * 1024

    private struct Record: Codable {
        let version: Int
        let accountID: String
        let serverURL: URL
        let userID: String
        let sessionID: String
        let token: String

        init(token: String, account: Account) {
            version = 1; accountID = account.id; serverURL = account.serverURL
            userID = account.userID; sessionID = account.sessionID; self.token = token
        }

        func matches(_ account: Account) -> Bool {
            version == 1 && accountID == account.id && serverURL == account.serverURL &&
                userID == account.userID && sessionID == account.sessionID
        }
    }

    func save(_ token: String, for account: Account) throws {
        let name = try filename(for: account)
        guard Self.validToken(token) else { throw SyncError.credentialStorage }
        let data = try JSONEncoder().encode(Record(token: token, account: account))
        guard data.count <= Self.maximumFileSize else { throw SyncError.credentialStorage }
        guard let folder = try openDirectory(create: true) else { throw SyncError.credentialStorage }
        defer { close(folder) }

        // Refuse to replace an unexpected entry. renameat itself never follows the destination link.
        if let existing = try openFile(name, in: folder) { close(existing) }
        let temporary = "." + UUID().uuidString + ".tmp"
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw SyncError.credentialStorage }
        defer {
            close(fd)
            unlinkat(folder, temporary, 0)
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw SyncError.credentialStorage }
        try validate(fd, directory: false)
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncError.credentialStorage }
                written += count
            }
        }
        guard fsync(fd) == 0, renameat(folder, temporary, folder, name) == 0 else {
            throw SyncError.credentialStorage
        }
        // Some file systems don't support syncing directory descriptors; file data is already synced.
        if fsync(folder) != 0 && errno != EINVAL && errno != ENOTSUP { throw SyncError.credentialStorage }
    }

    func read(for account: Account) throws -> String {
        let name = try filename(for: account)
        guard let folder = try openDirectory(create: false) else { throw SyncError.missingAccount }
        defer { close(folder) }
        guard let fd = try openFile(name, in: folder) else { throw SyncError.missingAccount }
        defer { close(fd) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= Self.maximumFileSize else { throw SyncError.credentialStorage }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.matches(account), Self.validToken(record.token) else { throw SyncError.credentialStorage }
        return record.token
    }

    func delete(for account: Account) throws {
        let name = try filename(for: account)
        guard let folder = try openDirectory(create: false) else { return }
        defer { close(folder) }
        // Unlink only this directory entry, without opening/following it. This also lets sign-out
        // remove a corrupt or overly permissive credential; a substituted symlink target is untouched.
        guard unlinkat(folder, name, 0) == 0 || errno == ENOENT else { throw SyncError.credentialStorage }
    }

    private func filename(for account: Account) throws -> String {
        guard UUID(uuidString: account.id) != nil, !account.userID.isEmpty,
              !account.sessionID.isEmpty, account.sessionID.utf8.count <= 512,
              let address = try? ServerAddress(account.serverURL.absoluteString, allowHTTP: account.allowHTTP),
              address.apiURL == account.serverURL else { throw SyncError.credentialStorage }
        // Server-assigned identifiers never become path components.
        return SHA256.hash(data: Data(account.sessionID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16 * 1024 && token.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw SyncError.credentialStorage }
        defer { close(parent) }
        let name = directory.lastPathComponent
        if create && mkdirat(parent, name, mode_t(0o700)) != 0 && errno != EEXIST {
            throw SyncError.credentialStorage
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && !create && errno == ENOENT { return nil }
        guard fd >= 0 else { throw SyncError.credentialStorage }
        do {
            try validate(fd, directory: true)
            if create {
                var url = directory, values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            }
            return fd
        } catch {
            close(fd)
            throw SyncError.credentialStorage
        }
    }

    private func openFile(_ name: String, in folder: Int32) throws -> Int32? {
        // O_NONBLOCK prevents a substituted FIFO from hanging before its type can be checked.
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw SyncError.credentialStorage }
        do {
            try validate(fd, directory: false)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func validate(_ fd: Int32, directory: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              info.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
              directory || (info.st_nlink <= 1 && info.st_size >= 0 && info.st_size <= Self.maximumFileSize) else {
            throw SyncError.credentialStorage
        }
        // An inherited allow ACL could grant access despite owner-only POSIX mode bits.
        guard let acl = acl_get_fd(fd) else {
            // Darwin reports an absent extended ACL as ENOENT rather than returning an empty ACL.
            guard errno == ENOENT else { throw SyncError.credentialStorage }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_valid(acl) == 0,
              acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
              errno == EINVAL else { throw SyncError.credentialStorage }
    }
}
