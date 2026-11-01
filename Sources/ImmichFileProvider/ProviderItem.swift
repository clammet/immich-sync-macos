import FileProvider
import Foundation
import ImmichCore
import UniformTypeIdentifiers

public final class ProviderItem: NSObject, NSFileProviderItem {
    public let record: ItemRecord
    private let pin: Bool?
    public init(_ record: ItemRecord,pin: Bool? = nil) { self.record = record; self.pin = pin }
    public var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.id) }
    public var parentItemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.parentID) }
    public var filename: String { record.filename }
    public var contentType: UTType { record.isFolder ? .folder : UTType(filenameExtension: (record.filename as NSString).pathExtension) ?? .data }
    public var documentSize: NSNumber? { record.remote?.size.map(NSNumber.init(value:)) }
    public var isUploaded: Bool { true }
    public var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion(contentVersion: record.contentVersion,metadataVersion: record.metadataVersion) }
    public var contentModificationDate: Date? { Self.date(record.modifiedAt) }
    public var capabilities: NSFileProviderItemCapabilities {
        guard record.kind != .root, let remote = record.remote else { return [.allowsReading] }
        var result: NSFileProviderItemCapabilities = [.allowsReading]
        // Advertise only server-granted operations. Requests are authorized again by OpenCloud.
        let permissions = remote.permissions ?? ""
        if record.isFolder, permissions.contains("C") || permissions.contains("K") { result.insert(.allowsAddingSubItems) }
        if !record.isFolder, permissions.contains("W") { result.insert(.allowsWriting) }
        if record.kind != .space {
            if permissions.contains("N") { result.insert(.allowsRenaming) }
            if permissions.contains("V") { result.insert(.allowsReparenting) }
            if permissions.contains("D") { result.insert(.allowsDeleting) }
        }
        return result
    }
    public var contentPolicy: NSFileProviderContentPolicy {
        if let pin { return pin ? .downloadEagerlyAndKeepDownloaded : .downloadLazily }
        return record.kind == .root ? .downloadLazily : .inherited
    }
    public var userInfo: [AnyHashable:Any]? { ["pinned":pin == true,"cloudItem":record.remote != nil] }
    public static func identifier(_ id: String) -> NSFileProviderItemIdentifier { id == ItemRecord.rootID ? .rootContainer : NSFileProviderItemIdentifier(id) }
    public static func id(_ identifier: NSFileProviderItemIdentifier) -> String { identifier == .rootContainer ? ItemRecord.rootID : identifier.rawValue }
    private static func date(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let value = iso.date(from: string) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: string) { return value }
        let http = DateFormatter(); http.locale = Locale(identifier: "en_US_POSIX"); http.timeZone = TimeZone(secondsFromGMT: 0)
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return http.date(from: string)
    }
}
public enum ProviderErrors {
    public static func map(_ error: Error,newImport: Bool = false,identifier: NSFileProviderItemIdentifier? = nil) -> Error {
        let code: NSFileProviderError.Code
        switch error {
        case SyncError.unsupported: code = newImport ? .excludedFromSync : .cannotSynchronize
        case SyncError.unsupportedLocation, SyncError.conflict, SyncError.mediaMappingRequired, SyncError.mediaNotIndexed, SyncError.ambiguousMedia: code = .cannotSynchronize
        case SyncError.missingAccount, SyncError.credentialStorage: code = .notAuthenticated
        case SyncError.http(let status,_):
            switch status {
            case 401: code = .notAuthenticated
            case 507: code = .insufficientQuota
            case 400,403,405,413,415,422: code = .cannotSynchronize
            default: code = .serverUnreachable
            }
        case SyncError.missingItem:
            if let identifier { return NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier) }; code = .noSuchItem
        case is CancellationError: return NSError(domain: NSCocoaErrorDomain,code: NSUserCancelledError)
        default:
            if (error as NSError).code == NSURLErrorCancelled { return NSError(domain: NSCocoaErrorDomain,code: NSUserCancelledError) }
            code = .serverUnreachable
        }
        return NSError(domain: NSFileProviderErrorDomain,code: code.rawValue,userInfo: [NSLocalizedDescriptionKey:error.localizedDescription,NSUnderlyingErrorKey:error])
    }
}
