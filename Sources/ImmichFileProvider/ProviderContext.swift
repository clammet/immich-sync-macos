import FileProvider
import Foundation
import ImmichCore

final class ProviderContext: @unchecked Sendable {
    let engine: SyncEngine
    let manager: NSFileProviderManager
    private let lock = NSLock()
    private var refreshing = false

    init(domain: NSFileProviderDomain) throws {
        guard let account = try SharedStore.account(), account.id == domain.identifier.rawValue,
              let manager = NSFileProviderManager(for: domain) else { throw SyncError.missingAccount }
        self.manager = manager
        let key = try CredentialStore.read(accountID: account.id)
        let catalog = try Catalog(url: SharedStore.catalogURL(accountID: account.id))
        if try catalog.all().isEmpty {
            try catalog.replace(with: ItemRecord.records(from: RemoteSnapshot(assets: [], albums: [], memberships: [:], mediaTypes: MediaTypes(image: [], video: []))))
        }
        engine = SyncEngine(catalog: catalog, remote: ImmichAPI(account: account, apiKey: key, keyProvider: {
            try CredentialStore.read(accountID: account.id)
        }), checkRunning: {
            guard let current = try SharedStore.account(), current.id == account.id else { throw SyncError.missingAccount }
            if current.paused { throw SyncError.paused }
        })
    }

    func item(_ record: ItemRecord) throws -> ProviderItem { ProviderItem(record, pin: try engine.catalog.pinned(record.id)) }
    func signal(_ parents: Set<String> = [ItemRecord.rootID, ItemRecord.libraryID, ItemRecord.albumsID]) {
        for id in parents { manager.signalEnumerator(for: ProviderItem.identifier(id)) { _ in } }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }
    func requestRefresh() {
        let started = lock.withLock { () -> Bool in
            if refreshing { return false }; refreshing = true; return true
        }
        guard started else { return }
        Task {
            defer { lock.withLock { refreshing = false } }
            do {
                let requested = UserDefaults(suiteName: SharedStore.groupID)?.double(forKey: "refreshRequestedAt") ?? 0
                let last = try engine.catalog.state("status", as: SyncStatus.self)?.lastRefresh?.timeIntervalSince1970 ?? 0
                let parents = try await engine.refresh(force: requested > last)
                if !parents.isEmpty { signal(parents) }
            } catch { /* The engine persists the error for the menu bar. Cached metadata remains available. */ }
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
        try lock.withLock {
            // A credentials update changes the domain version through re-registration; refresh the process
            // after account repair so that a stale API client is never silently reused.
            let key = domain.identifier.rawValue
            if let context = contexts[key] { return context }
            let context = try ProviderContext(domain: domain); contexts[key] = context; return context
        }
    }
    static func invalidate(_ domain: NSFileProviderDomain) { _ = lock.withLock { contexts.removeValue(forKey: domain.identifier.rawValue) } }
}
