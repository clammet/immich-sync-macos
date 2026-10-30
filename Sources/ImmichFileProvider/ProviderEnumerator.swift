import FileProvider
import Foundation
import ImmichCore

final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    let domain: NSFileProviderDomain
    let container: NSFileProviderItemIdentifier
    private var invalidated = false
    private let lock = NSLock()
    init(domain: NSFileProviderDomain, container: NSFileProviderItemIdentifier) { self.domain = domain; self.container = container }
    func invalidate() { lock.withLock { invalidated = true } }

    private struct Page: Codable {
        let container: String
        let after: String
        let anchor: SyncAnchor
    }
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard !lock.withLock({ invalidated }) else { observer.finishEnumeratingWithError(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)); return }
        do {
            let context = try ProviderRegistry.context(for: domain)
            context.requestSync()
            let token: Page?
            if page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data || page.rawValue == NSFileProviderPage.initialPageSortedByName as Data { token = nil }
            else {
                guard let decoded = try? JSONDecoder().decode(Page.self, from: page.rawValue) else { throw SyncError.invalidAnchor }
                token = decoded
                guard token?.container == container.rawValue else { throw SyncError.invalidAnchor }
            }
            let result = try context.engine.catalog.page(parentID: container == .workingSet ? nil : ProviderItem.id(container),
                after: token?.after, expected: token?.anchor)
            observer.didEnumerate(try result.items.filter { $0.kind != .root }.map(context.item))
            let next = try result.next.map { NSFileProviderPage(try JSONEncoder().encode(Page(container: container.rawValue, after: $0, anchor: result.anchor))) }
            observer.finishEnumerating(upTo: next)
        } catch SyncError.invalidAnchor {
            observer.finishEnumeratingWithError(NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.pageExpired.rawValue))
        } catch {
            observer.finishEnumeratingWithError(ProviderErrors.map(error))
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        do {
            let context = try ProviderRegistry.context(for: domain)
            context.requestSync()
            guard let decoded = try? SyncAnchor(data: anchor.rawValue) else { throw SyncError.invalidAnchor }
            let changes = try context.engine.catalog.changes(since: decoded)
            // Keep only the last event per identity within this batch (a create may be followed by deletion).
            let matching = changes.changes.filter { container == .workingSet || $0.parentID == ProviderItem.id(container) }
            let relevant = Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values
            observer.didDeleteItems(withIdentifiers: relevant.filter { $0.record == nil }.map { ProviderItem.identifier($0.id) })
            observer.didUpdate(try relevant.compactMap(\.record).filter { $0.kind != .root }.map(context.item))
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(changes.anchor.data), moreComing: changes.more)
        } catch SyncError.invalidAnchor {
            observer.finishEnumeratingWithError(NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.syncAnchorExpired.rawValue))
        } catch {
            observer.finishEnumeratingWithError(ProviderErrors.map(error))
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        do {
            let context = try ProviderRegistry.context(for: domain)
            context.requestSync()
            completionHandler(try NSFileProviderSyncAnchor(context.engine.catalog.anchor().data))
        } catch { completionHandler(nil) }
    }
}
