import FileProvider
import Foundation
import OpenCloudCore

// File Provider callbacks support background invocation, but the SDK does not mark them
// @Sendable. Keep that unchecked contract at the callback boundary; task inputs are values.
private struct ProviderCallback<Handler>: @unchecked Sendable {
    let handler: Handler
    init(_ handler: Handler) { self.handler = handler }
}

@objc(OpenCloudFileProviderExtension)
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

    private func run(context: ProviderContext, _ work: @escaping @Sendable (ProviderContext, Progress) async -> Void) -> Progress {
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
        let contentVersion = requestedVersion?.contentVersion
        let completion = ProviderCallback(completionHandler)
        return run(context: context) { context, progress in
            do {
                let result = try await context.engine.download(id: ProviderItem.id(itemIdentifier), directory: context.manager.temporaryDirectoryURL(), progress: progress, requestedVersion: contentVersion)
                completion.handler(result.0, try context.item(result.1), nil)
            } catch { context.recordError(error); completion.handler(nil, nil, ProviderErrors.map(error, identifier: itemIdentifier)) }
        }
    }

    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                           options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else {
            completionHandler(nil, [], false, ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0)
        }
        let contentType = itemTemplate.contentType
        // Packages and symlinks require semantics this WebDAV client does not implement.
        let supported = (contentType == .folder || contentType?.conforms(to: .data) == true)
            && contentType != .symbolicLink && contentType?.conforms(to: .package) != true
        let parentID = ProviderItem.id(itemTemplate.parentItemIdentifier)
        let filename = itemTemplate.filename
        let directory = contentType == .folder
        let completion = ProviderCallback(completionHandler)
        return run(context: context) { context, progress in
            do {
                guard supported else { throw SyncError.unsupported }
                let item = try await context.engine.create(parentID: parentID,
                    filename: filename, directory: directory, contents: url, progress: progress)
                context.signal(); completion.handler(try context.item(item), [], false, nil)
            } catch { context.recordError(error); completion.handler(nil, [], false, ProviderErrors.map(error, newImport: true)) }
        }
    }

    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                           changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions,
                           request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else {
            completionHandler(nil, [], false, ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0)
        }
        let id = ProviderItem.id(item.itemIdentifier)
        let contentVersion = version.contentVersion
        let filename = changedFields.contains(.filename) ? item.filename : nil
        let parentID = changedFields.contains(.parentItemIdentifier) ? ProviderItem.id(item.parentItemIdentifier) : nil
        let completion = ProviderCallback(completionHandler)
        return run(context: context) { context, progress in
            do {
                let updated = try await context.engine.modify(id: id, baseContentVersion: contentVersion,
                    filename: filename, parentID: parentID,
                    contents: newContents, progress: progress)
                context.signal()
                completion.handler(try context.item(updated), [], false, nil)
            } catch { context.recordError(error); completion.handler(nil, [], false, ProviderErrors.map(error)) }
        }
    }

    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                           options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                           completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else { completionHandler(ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0) }
        let contentVersion = version.contentVersion
        let completion = ProviderCallback(completionHandler)
        return run(context: context) { context, progress in
            do {
                try await context.engine.delete(id: ProviderItem.id(identifier), baseContentVersion: contentVersion,
                    recursive: options.contains(.recursive))
                context.signal(); completion.handler(nil)
            } catch {
                context.recordError(error)
                // Restore rejected deletions in Finder. Excluded imports have no catalog row and are a no-op above.
                let reject: Bool
                switch MutationFailure.cause(of: error) {
                case SyncError.unsupported, SyncError.unsupportedLocation, SyncError.conflict: reject = true
                default: reject = false
                }
                if reject, let record = try? context.engine.catalog.item(ProviderItem.id(identifier)),
                   let item = try? context.item(record) {
                    completion.handler(NSError.fileProviderErrorForRejectedDeletion(of: item))
                } else { completion.handler(ProviderErrors.map(error)) }
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
        let thumbnailCompletion = ProviderCallback(perThumbnailCompletionHandler)
        let completion = ProviderCallback(completionHandler)
        return run(context: context) { context, progress in
            progress.totalUnitCount = Int64(itemIdentifiers.count)
            for (index, id) in itemIdentifiers.enumerated() {
                if Task.isCancelled {
                    let error = ProviderErrors.map(CancellationError())
                    for remaining in itemIdentifiers.dropFirst(index) { thumbnailCompletion.handler(remaining, nil, error) }
                    completion.handler(error); return
                }
                do {
                    let bytes = try await context.engine.thumbnail(id: ProviderItem.id(id), large: max(size.width, size.height) > 256)
                    thumbnailCompletion.handler(id, bytes, nil)
                } catch { thumbnailCompletion.handler(id, nil, ProviderErrors.map(error)) }
                progress.completedUnitCount += 1
            }
            completion.handler(Task.isCancelled ? ProviderErrors.map(CancellationError()) : nil)
        }
    }

    public func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                              onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                              completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard case .success(let context) = contextResult else { completionHandler(ProviderErrors.map(SyncError.missingAccount)); return Progress(totalUnitCount: 0) }
        let completion = ProviderCallback(completionHandler)
        return run(context: context) { context, progress in
            do {
                let ids = itemIdentifiers.map(ProviderItem.id)
                switch actionIdentifier.rawValue {
                case "app.opencloud.sync.link", "app.opencloud.sync.sharing":
                    try context.engine.catalog.setState("actionResult",value: ActionResult(title: "Running Finder action…",urls: []))
                    var urls: [URL] = []
                    for id in ids {
                        let url = try await actionIdentifier.rawValue.hasSuffix(".link") ? context.engine.createSharingLink(id: id) : context.engine.sharingPage(id: id)
                        urls.append(url)
                        // Preserve each successful result if another item fails later.
                        try context.engine.catalog.setState("actionResult",value: ActionResult(title: "OpenCloud sharing",urls: urls))
                    }
                case "app.opencloud.sync.immichAlbum", "app.opencloud.sync.immichLink":
                    try context.engine.catalog.setState("actionResult",value: ActionResult(title: "Running Finder action…",urls: []))
                    guard let account = try SharedStore.immichAccount() else { throw SyncError.mediaMappingRequired }
                    let api = ImmichAPI(serverURL: account.serverURL,token: { try CredentialStore.read(for: account) },apiKey: account.credentialKind == "apiKey")
                    let mappings = try context.engine.catalog.mediaMappings(for: account)
                    let name = actionIdentifier.rawValue.hasSuffix("immichAlbum") ? (ids.count == 1 ? try context.engine.catalog.item(ids[0]).filename : "Finder selection") : nil
                    let result = try await MediaActions(remote: api).perform(itemIDs: ids,catalog: context.engine.catalog,mappings: mappings,albumName: name)
                    try context.engine.catalog.setState("actionResult",value: result)
                default:
                    for id in ids {
                        try Task.checkCancellation()
                        switch actionIdentifier.rawValue {
                        case "app.opencloud.sync.keep": try context.engine.catalog.pin(id,value: true)
                        case "app.opencloud.sync.automatic": try context.engine.catalog.pin(id,value: false)
                        case "app.opencloud.sync.inherit": try context.engine.catalog.pin(id,value: nil)
                        default: throw SyncError.unsupported
                        }
                    }
                }
                context.signal()
                progress.completedUnitCount = 100; completion.handler(nil)
            } catch {
                let partial = try? context.engine.catalog.state("actionResult",as: ActionResult.self)
                try? context.engine.catalog.setState("actionResult",value: ActionResult(title: "Action failed: " + error.localizedDescription,urls: partial?.urls ?? []))
                completion.handler(ProviderErrors.map(error))
            }
        }
    }
}
