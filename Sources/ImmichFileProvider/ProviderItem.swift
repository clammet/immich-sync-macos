import FileProvider
import Foundation
import ImmichCore
import UniformTypeIdentifiers

public final class ProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    public let record: ItemRecord
    private let pin: Bool?
    public init(_ record: ItemRecord, pin: Bool? = nil) { self.record = record; self.pin = pin }
    public var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.id) }
    public var parentItemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.parentID) }
    public var filename: String { record.filename }
    public var contentType: UTType { record.isFolder ? .folder : UTType(filenameExtension: (record.filename as NSString).pathExtension) ?? .data }
    public var documentSize: NSNumber? { (record.asset?.size ?? record.localSize).map(NSNumber.init(value:)) }
    public var isUploaded: Bool { !record.isLocalOnly }
    public var decorations: [NSFileProviderItemDecorationIdentifier]? {
        record.isLocalOnly ? [NSFileProviderItemDecorationIdentifier("app.immich.sync.ignored")] : []
    }
    public var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion(contentVersion: record.contentVersion, metadataVersion: record.metadataVersion) }
    public var contentModificationDate: Date? { Self.date(record.asset?.fileModifiedAt ?? record.modifiedAt) }
    public var creationDate: Date? { record.asset.flatMap { Self.date($0.fileCreatedAt) } }
    public var capabilities: NSFileProviderItemCapabilities {
        switch record.kind {
        case .root: return [.allowsReading]
        case .library, .albums: return [.allowsReading, .allowsAddingSubItems]
        case .album: return [.allowsReading, .allowsAddingSubItems, .allowsRenaming, .allowsDeleting]
        case .asset:
            return record.isMutable ? [.allowsReading, .allowsWriting, .allowsDeleting, .allowsReparenting] : [.allowsReading]
        case .ignoredFile: return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsReparenting, .allowsRenaming]
        case .ignoredFolder: return [.allowsReading, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming]
        }
    }
    public var contentPolicy: NSFileProviderContentPolicy {
        if record.isLocalOnly { return .downloadEagerlyAndKeepDownloaded }
        if let pin { return pin ? .downloadEagerlyAndKeepDownloaded : .downloadLazily }
        return record.kind == .root ? .downloadLazily : .inherited
    }
    public var userInfo: [AnyHashable: Any]? { ["pinned": pin == true] }

    public static func identifier(_ id: String) -> NSFileProviderItemIdentifier { id == ItemRecord.rootID ? .rootContainer : NSFileProviderItemIdentifier(id) }
    public static func id(_ identifier: NSFileProviderItemIdentifier) -> String { identifier == .rootContainer ? ItemRecord.rootID : identifier.rawValue }
    private static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public enum ProviderErrors {
    /// Excluding an existing item instructs macOS to call deleteItem on its remote counterpart.
    /// Only use exclusion for NEW unsupported imports; existing originals must remain untouched.
    public static func map(_ error: Error, newImport: Bool = false) -> Error {
        let code: NSFileProviderError.Code
        switch error {
        case SyncError.unsupported, SyncError.unsupportedLocation: code = newImport ? .excludedFromSync : .cannotSynchronize
        case SyncError.missingAccount, SyncError.keychain: code = .notAuthenticated
        case SyncError.http(let status, _):
            switch status {
            case 401, 403: code = .notAuthenticated
            case 507: code = .insufficientQuota
            case 400, 413, 415, 422: code = .cannotSynchronize
            default: code = .serverUnreachable
            }
        case SyncError.conflict, SyncError.trashDisabled: code = .cannotSynchronize
        case SyncError.missingItem: code = .noSuchItem
        case is CancellationError: return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        default:
            if (error as NSError).code == NSURLErrorCancelled { return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
            code = .serverUnreachable
        }
        return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: error.localizedDescription, NSUnderlyingErrorKey: error])
    }
}
