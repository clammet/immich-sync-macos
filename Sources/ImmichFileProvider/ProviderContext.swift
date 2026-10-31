import FileProvider
import Foundation
import ImmichCore

final class ProviderContext: @unchecked Sendable {
    let engine: SyncEngine
    let manager: NSFileProviderManager
    let sessionID: String
    private let lock = NSLock()
    private var job: Task<Void, Never>?
    private var invalidated = false

    init(domain: NSFileProviderDomain, account: Account) throws {
        guard account.id == domain.identifier.rawValue, let manager = NSFileProviderManager(for: domain) else { throw SyncError.missingAccount }
        self.manager = manager; sessionID = account.sessionID
        let catalog = try Catalog(url: SharedStore.catalogURL(accountID: account.id))
        let validate: @Sendable () throws -> Void = {
            guard let current = try SharedStore.account(), current.id == account.id, current.sessionID == account.sessionID else { throw SyncError.missingAccount }
            if current.paused { throw SyncError.paused }
        }
        let api = ImmichAPI(serverURL: account.serverURL, token: {
            try validate()
            return try CredentialStore.read(for: account)
        })
        engine = try SyncEngine(catalog: catalog, remote: api, account: account, checkRunning: validate)
    }
    func item(_ record: ItemRecord) throws -> ProviderItem { ProviderItem(record, pin: try engine.catalog.pinned(record.id)) }
    func signal() { manager.signalEnumerator(for: .workingSet) { _ in } }
    func cancel() { lock.withLock { invalidated = true; job?.cancel() } }
    func requestSync() {
        lock.withLock {
            guard !invalidated, job == nil else { return }
            job = Task {
                let before = try? engine.catalog.anchor()
                defer {
                    if let before, let after = try? engine.catalog.anchor(), before != after { signal() }
                    lock.withLock { job = nil }
                }
                do {
                    let requested = UserDefaults(suiteName: SharedStore.groupID)?.double(forKey: "syncRequestedAt") ?? 0
                    let last = try engine.catalog.state("status", as: SyncStatus.self)?.lastSync?.timeIntervalSince1970 ?? 0
                    try await engine.synchronize(force: requested > last)
                } catch { /* SyncEngine persists errors; cached Finder metadata stays available. */ }
            }
        }
    }
    func recordError(_ error: Error) {
        var status = (try? engine.catalog.state("status", as: SyncStatus.self)) ?? SyncStatus()
        status.message = error.localizedDescription
        try? engine.catalog.setState("status", value: status)
    }
}

enum ProviderRegistry {
    static let lock = NSLock()
    static var contexts: [String: ProviderContext] = [:]
    static func context(for domain: NSFileProviderDomain) throws -> ProviderContext {
        return try lock.withLock {
            guard let account = try SharedStore.account() else { throw SyncError.missingAccount }
            let id = domain.identifier.rawValue
            if let existing = contexts[id], existing.sessionID == account.sessionID { return existing }
            contexts[id]?.cancel()
            let context = try ProviderContext(domain: domain, account: account)
            contexts[id] = context
            return context
        }
    }
    static func invalidate(_ domain: NSFileProviderDomain) {
        lock.withLock { contexts.removeValue(forKey: domain.identifier.rawValue)?.cancel() }
    }
}
