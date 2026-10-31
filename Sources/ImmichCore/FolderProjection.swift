import CryptoKit
import Foundation

/// Server paths are opaque POSIX components, never URLs or paths to resolve on this Mac.
/// Keep absolute/relative paths and external libraries in separate namespaces. Do not guess a
/// storage root: it can change with server configuration, storage labels, and library mounts.
enum FolderProjection {
    struct Folder {
        let id: String
        let parent: String
        let name: String
        let kind: ItemRecord.Kind
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func components(_ path: String?) -> (absolute: Bool, parts: [String])? {
        guard let path, !path.isEmpty, path.utf8.count <= 8192 else { return nil }
        let absolute = path.hasPrefix("/")
        let parts = (absolute ? String(path.dropFirst()) : path).components(separatedBy: "/")
        guard (1...64).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 1024 &&
            !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { return nil }
        return (absolute, parts)
    }
    static func name(_ component: String) -> String {
        var name = component.precomposedStringWithCanonicalMapping.replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled" }
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        if name.utf8.count > 240 { return ItemRecord.safeName(name, identity: String(digest(component).prefix(16))) }
        return name
    }
    static func folders(for asset: Asset) -> (folders: [Folder], filename: String) {
        var folders: [Folder] = [], parent = ItemRecord.libraryID
        let scope = asset.libraryId.map { "external:\($0)" } ?? "owned"
        let kind: ItemRecord.Kind = asset.libraryId == nil ? .folder : .externalFolder
        func append(_ key: String, _ name: String) {
            let id = "folder:" + digest(key)
            folders.append(Folder(id: id, parent: parent, name: name, kind: kind))
            parent = id
        }
        if let library = asset.libraryId {
            append("external", "External Libraries")
            append(scope, "Library " + name(library))
        }
        guard let path = components(asset.originalPath) else {
            append(scope + "\0unresolved", "Unresolved paths")
            return (folders, asset.originalFileName)
        }
        let namespace = scope + (path.absolute ? "\0absolute" : "\0relative")
        append(namespace, path.absolute ? "Server" : "Relative paths")
        var key = namespace
        for component in path.parts.dropLast() {
            key += "\0" + component
            append(key, name(component))
        }
        return (folders, path.parts.last!)
    }
}

public struct AssetPathWork: Sendable {
    public let id: String
    public let generation: Int
    public let revision: String
}
