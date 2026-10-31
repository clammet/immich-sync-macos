import FileProvider
import Foundation
import ImmichCore

@objc(ImmichFileProviderExtension)
public final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction, NSFileProviderThumbnailing {
    private let domain: NSFileProviderDomain
    private var contextResult: Result<ProviderContext, Error> { Result { try ProviderRegistry.context(for: domain) } }
    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }
    public func invalidate() { ProviderRegistry.invalidate(domain) }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard containerItemIdentifier != .trashContainer else { throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError) }
        do { _ = try contextResult.get(); return ProviderEnumerator(domain: domain, container: containerItemIdentifier) }
        catch { throw ProviderErrors.map(error) }
    }

    private func run(context: ProviderContext, _ work: @escaping (ProviderContext, Progress) async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task {
            await work(context, progress)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
                     completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do {
            let context = try contextResult.get()
            let item = try context.item(context.engine.catalog.item(ProviderItem.id(identifier)))
            context.requestSync(); completionHandler(item, nil)
        } catch { completionHandler(nil, ProviderErrors.map(error, identifier: identifier)) }
        return Progress(totalUnitCount: 0)
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                              request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else {
            completionHandler(nil, nil, ProviderErrors.map(SyncError.missingAccount))
            return Progress(totalUnitCount: 0)
        }
        return run(context: context) { context, progress in
            do {
                let result = try await context.engine.download(id: ProviderItem.id(itemIdentifier), directory: context.manager.temporaryDirectoryURL(), progress: progress, requestedVersion: requestedVersion?.contentVersion)
                completionHandler(result.0, try context.item(result.1), nil)
            } catch { context.recordError(error); completionHandler(nil, nil, ProviderErrors.map(error, identifier: itemIdentifier)) }
        }
    }

    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                           options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else {
            completionHandler(nil, [], false, ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0)
        }
        return run(context: context) { context, progress in
            do {
                // Packages and symlinks are local-only, even if their names resemble media files.
                guard itemTemplate.contentType == .folder || itemTemplate.contentType?.conforms(to: .data) == true,
                      itemTemplate.contentType != .symbolicLink, itemTemplate.contentType?.conforms(to: .package) != true else { throw SyncError.unsupported }
                let item = try await context.engine.create(parentID: ProviderItem.id(itemTemplate.parentItemIdentifier),
                    filename: itemTemplate.filename, directory: itemTemplate.contentType == .folder, contents: url, progress: progress)
                context.signal(); completionHandler(try context.item(item), [], false, nil)
            } catch { context.recordError(error); completionHandler(nil, [], false, ProviderErrors.map(error, newImport: true)) }
        }
    }

    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                           changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions,
                           request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else {
            completionHandler(nil, [], false, ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0)
        }
        return run(context: context) { context, progress in
            do {
                let updated = try await context.engine.modify(id: ProviderItem.id(item.itemIdentifier), baseContentVersion: version.contentVersion,
                    filename: changedFields.contains(.filename) ? item.filename : nil,
                    parentID: changedFields.contains(.parentItemIdentifier) ? ProviderItem.id(item.parentItemIdentifier) : nil,
                    contents: newContents, progress: progress)
                context.signal()
                completionHandler(try context.item(updated), [], false, nil)
            } catch { context.recordError(error); completionHandler(nil, [], false, ProviderErrors.map(error)) }
        }
    }

    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                           options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                           completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else { completionHandler(ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0) }
        return run(context: context) { context, progress in
            do {
                try await context.engine.delete(id: ProviderItem.id(identifier), baseContentVersion: version.contentVersion,
                    recursive: options.contains(.recursive))
                context.signal(); completionHandler(nil)
            } catch {
                context.recordError(error)
                // Restore rejected deletions in Finder. Excluded imports have no catalog row and are a no-op above.
                let reject: Bool
                switch error {
                case SyncError.unsupported, SyncError.unsupportedLocation, SyncError.serverOrganization, SyncError.conflict, SyncError.trashDisabled: reject = true
                default: reject = false
                }
                if reject, let record = try? context.engine.catalog.item(ProviderItem.id(identifier)),
                   let item = try? context.item(record) {
                    completionHandler(NSError.fileProviderErrorForRejectedDeletion(of: item))
                } else { completionHandler(ProviderErrors.map(error)) }
            }
        }
    }

    public func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                                 perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                                 completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else {
            let error = ProviderErrors.map(SyncError.missingAccount)
            for id in itemIdentifiers { perThumbnailCompletionHandler(id, nil, error) }
            completionHandler(error); return Progress(totalUnitCount: 0)
        }
        return run(context: context) { context, progress in
            progress.totalUnitCount = Int64(itemIdentifiers.count)
            for (index, id) in itemIdentifiers.enumerated() {
                if Task.isCancelled {
                    let error = ProviderErrors.map(CancellationError())
                    for remaining in itemIdentifiers.dropFirst(index) { perThumbnailCompletionHandler(remaining, nil, error) }
                    completionHandler(error); return
                }
                do {
                    let bytes = try await context.engine.thumbnail(id: ProviderItem.id(id), large: max(size.width, size.height) > 256)
                    perThumbnailCompletionHandler(id, bytes, nil)
                } catch { perThumbnailCompletionHandler(id, nil, ProviderErrors.map(error)) }
                progress.completedUnitCount += 1
            }
            completionHandler(Task.isCancelled ? ProviderErrors.map(CancellationError()) : nil)
        }
    }

    public func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                              onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                              completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else { completionHandler(ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0) }
        return run(context: context) { context, progress in
            do {
                for identifier in itemIdentifiers {
                    try Task.checkCancellation()
                    let id = ProviderItem.id(identifier)
                    switch actionIdentifier.rawValue {
                    case "app.immich.sync.keep": try context.engine.catalog.pin(id, value: true)
                    case "app.immich.sync.automatic": try context.engine.catalog.pin(id, value: false)
                    case "app.immich.sync.inherit": try context.engine.catalog.pin(id, value: nil)
                    default: throw SyncError.unsupported
                    }
                    context.signal()
                }
                progress.completedUnitCount = 100; completionHandler(nil)
            } catch { completionHandler(ProviderErrors.map(error)) }
        }
    }
}
