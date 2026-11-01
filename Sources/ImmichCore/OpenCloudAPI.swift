import Foundation

public protocol OpenCloudRemote: Sendable {
    func spaces() async throws -> [CloudSpace]
    func properties(space: CloudSpace, path: [String]) async throws -> CloudFile
    func children(_ folder: CloudFile) async throws -> [CloudFile]
    func download(_ file: CloudFile, into directory: URL, progress: Progress) async throws -> URL
    func upload(parent: CloudFile, name: String, contents: URL, replacing: CloudFile?, progress: Progress, checkpointURL: URL?) async throws -> CloudFile
    func makeDirectory(parent: CloudFile, name: String) async throws -> CloudFile
    func move(_ file: CloudFile, parent: CloudFile, name: String) async throws -> CloudFile
    func delete(_ file: CloudFile) async throws
    func createLink(_ file: CloudFile) async throws -> URL
    func webURL(_ file: CloudFile) async throws -> URL
}

final class HTTPDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: Progress?
    private let uploadOffset: Int64
    private let uploadLength: Int64?
    init(_ progress: Progress? = nil, uploadOffset: Int64 = 0, uploadLength: Int64? = nil) {
        self.progress = progress; self.uploadOffset = uploadOffset; self.uploadLength = uploadLength
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?.totalUnitCount = max(1,uploadLength ?? totalBytesExpectedToSend)
        progress?.completedUnitCount = uploadOffset + totalBytesSent
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?.totalUnitCount = max(1,totalBytesExpectedToWrite); progress?.completedUnitCount = totalBytesWritten
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum HTTPClient {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: config, delegate: HTTPDelegate(), delegateQueue: nil)
    }
    @discardableResult static func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return response
        case 404: throw SyncError.missingItem
        case 409, 412: throw SyncError.conflict
        default: throw SyncError.http(response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() &&
        (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80)) &&
        b.user == nil && b.password == nil && b.fragment == nil
    }
}

public final class OpenCloudAPI: OpenCloudRemote, @unchecked Sendable {
    public let serverURL: URL
    private let username: String
    private let token: @Sendable () throws -> String
    private let session: URLSession
    private let uploadChunkSize: Int
    public init(serverURL: URL, username: String, token: @escaping @Sendable () throws -> String, session: URLSession? = nil,
                uploadChunkSize: Int = 8 * 1024 * 1024) {
        self.serverURL = serverURL; self.username = username; self.token = token; self.session = session ?? HTTPClient.session()
        self.uploadChunkSize = min(max(1,uploadChunkSize),8 * 1024 * 1024)
    }
    private func endpoint(_ parts: [String]) -> URL { parts.reduce(serverURL) { $0.appendingPathComponent($1) } }
    public func request(url: URL, method: String = "GET") throws -> URLRequest {
        guard HTTPClient.sameOrigin(serverURL,url), url.query == nil || method == "GET",
              !username.contains(":"), !username.contains("\r"), !username.contains("\n") else { throw SyncError.invalidServer }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Basic " + Data((username + ":" + (try token())).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        r.setValue("OpenCloudSync/0.3 (macOS)", forHTTPHeaderField: "User-Agent")
        return r
    }
    private func json<T: Decodable>(_ url: URL, method: String = "GET", body: [String:Any]? = nil) async throws -> T {
        var r = try request(url: url, method: method)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data,response) = try await session.data(for: r)
        try HTTPClient.validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }
    public struct User: Decodable, Sendable { public let id: String; public let displayName: String? }
    public func user() async throws -> User { try await json(endpoint(["graph","v1.0","me"])) }
    private struct Drive: Decodable {
        struct Root: Decodable { let id: String; let webDavUrl: URL }
        let id: String; let name: String; let root: Root
    }
    private struct Drives: Decodable {
        let value: [Drive]; let next: String?
        enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
    }
    public func spaces() async throws -> [CloudSpace] {
        var url: URL? = endpoint(["graph","v1.0","me","drives"]), seen = Set<URL>(), ids = Set<String>(), result: [CloudSpace] = []
        while let page = url {
            guard seen.insert(page).inserted else { throw SyncError.invalidResponse }
            let response: Drives = try await json(page)
            for drive in response.value {
                guard !drive.id.isEmpty, !drive.root.id.isEmpty, ids.insert(drive.id).inserted,
                      HTTPClient.sameOrigin(serverURL,drive.root.webDavUrl), drive.root.webDavUrl.query == nil else { throw SyncError.invalidResponse }
                result.append(CloudSpace(id: drive.id, name: drive.name, rootID: drive.root.id, davURL: drive.root.webDavUrl))
            }
            if let next = response.next {
                guard let parsed = URL(string: next, relativeTo: page)?.absoluteURL,
                      HTTPClient.sameOrigin(serverURL,parsed), parsed.path.hasPrefix(endpoint(["graph"]).path + "/") else { throw SyncError.invalidResponse }
                url = parsed
            } else { url = nil }
        }
        return result
    }
    private static let propertiesBody = Data("""
    <?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/><d:getlastmodified/><oc:fileid/><oc:id/><oc:permissions/><oc:checksums/></d:prop></d:propfind>
    """.utf8)
    private func propfind(space: CloudSpace, path: [String], depth: Int) async throws -> [CloudFile] {
        try RemotePath.validate(path)
        let url = path.reduce(space.davURL) { $0.appendingPathComponent($1) }
        var r = try request(url: url, method: "PROPFIND")
        r.setValue(String(depth), forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Self.propertiesBody
        let (bytes,response) = try await session.data(for: r)
        let http = try HTTPClient.validate(response)
        guard http.statusCode == 207, bytes.count <= 64 * 1024 * 1024 else { throw SyncError.invalidResponse }
        return try DAVDecoder.decode(bytes, space: space, requestedURL: url)
    }
    public func properties(space: CloudSpace, path: [String]) async throws -> CloudFile {
        let files = try await propfind(space: space,path: path,depth: 0)
        guard files.count == 1, let file = files.first, RemotePath.equal(file.path,path) else { throw SyncError.invalidResponse }
        return file
    }
    public func children(_ folder: CloudFile) async throws -> [CloudFile] {
        guard folder.isDirectory else { throw SyncError.unsupportedLocation }
        let files = try await propfind(space: folder.space,path: folder.path,depth: 1)
        guard files.filter({ $0.path.count == folder.path.count && RemotePath.equal($0.path,folder.path) && $0.fileID == folder.fileID }).count == 1 else { throw SyncError.invalidResponse }
        let children = files.filter { !RemotePath.equal($0.path,folder.path) }
        guard children.allSatisfy({ $0.path.count == folder.path.count + 1 && RemotePath.contains(folder.path,$0.path) }),
              Set(files.map(\.fileID)).count == files.count, Set(files.map { RemotePath.key($0.path) }).count == files.count else { throw SyncError.invalidResponse }
        return children
    }
    public func download(_ file: CloudFile, into directory: URL, progress: Progress) async throws -> URL {
        var r = try request(url: file.url)
        r.setValue(try Self.condition(file.etag), forHTTPHeaderField: "If-Match")
        let (temporary,response) = try await session.download(for: r, delegate: HTTPDelegate(progress))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let http = try HTTPClient.validate(response)
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "ETag").map({ $0 == file.etag }) ?? true else { throw SyncError.conflict }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
        if let expected = file.size, size != expected { throw SyncError.invalidResponse }
        if let expected = file.checksum, try FileDigest.sha1(temporary).map({ String(format: "%02x",$0) }).joined().lowercased() != expected.lowercased() { throw SyncError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress.completedUnitCount = progress.totalUnitCount
        return destination
    }
    static func condition(_ etag: String) throws -> String {
        guard !etag.isEmpty, !etag.hasPrefix("W/"), etag.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.dropFirst().dropLast().contains("\"") else { throw SyncError.invalidResponse }
        return etag
    }
    public func upload(parent: CloudFile, name: String, contents: URL, replacing: CloudFile?, progress: Progress,
                       checkpointURL: URL? = nil) async throws -> CloudFile {
        try RemotePath.validate([name])
        guard parent.isDirectory, replacing?.isDirectory != true, replacing == nil || (replacing?.space.id == parent.space.id && replacing.map { RemotePath.equal($0.path,parent.path + [name]) } == true) else { throw SyncError.unsupportedLocation }
        let binding = RemotePath.digest(serverURL.absoluteString + "\0" + username)
        return try await TUSUploader(api: self, session: session, chunkSize: uploadChunkSize, binding: binding)
            .upload(parent: parent, name: name, contents: contents, replacing: replacing,
                    progress: progress, checkpointURL: checkpointURL)
    }
    public func makeDirectory(parent: CloudFile, name: String) async throws -> CloudFile {
        var outcome = MutationOutcome.notSent
        do {
            try RemotePath.validate([name])
            guard parent.isDirectory else { throw SyncError.unsupportedLocation }
            var r = try request(url: parent.url.appendingPathComponent(name), method: "MKCOL")
            r.setValue("*", forHTTPHeaderField: "If-None-Match")
            outcome = .uncertain
            let (_,response) = try await session.data(for: r)
            if (response as? HTTPURLResponse)?.statusCode == 405 { throw MutationFailure(outcome: .rejected,underlyingError: SyncError.conflict) }
            let http = try MutationFailure.validate(response)
            guard http.statusCode == 201 else { throw SyncError.invalidResponse }
            let folder = try await properties(space: parent.space,path: parent.path + [name])
            guard folder.isDirectory else { throw SyncError.conflict }
            return folder
        } catch { throw MutationFailure.wrapping(error,outcome: outcome) }
    }
    public func move(_ file: CloudFile, parent: CloudFile, name: String) async throws -> CloudFile {
        var outcome = MutationOutcome.notSent
        do {
            try RemotePath.validate([name])
            guard parent.isDirectory, file.space.id == parent.space.id, !file.path.isEmpty,
                  !(file.isDirectory && RemotePath.contains(file.path,parent.path)) else { throw SyncError.unsupportedLocation }
            var r = try request(url: file.url,method: "MOVE")
            r.setValue(try Self.condition(file.etag), forHTTPHeaderField: "If-Match")
            r.setValue(parent.url.appendingPathComponent(name).absoluteString, forHTTPHeaderField: "Destination")
            r.setValue("F", forHTTPHeaderField: "Overwrite")
            outcome = .uncertain
            let (_,response) = try await session.data(for: r)
            let http = try MutationFailure.validate(response)
            guard [201,204].contains(http.statusCode) else { throw SyncError.invalidResponse }
            let moved = try await properties(space: parent.space,path: parent.path + [name])
            guard moved.fileID == file.fileID else { throw SyncError.conflict }
            return moved
        } catch { throw MutationFailure.wrapping(error,outcome: outcome) }
    }
    public func delete(_ file: CloudFile) async throws {
        var outcome = MutationOutcome.notSent
        do {
            guard !file.path.isEmpty else { throw SyncError.unsupportedLocation }
            var r = try request(url: file.url,method: "DELETE")
            r.setValue(try Self.condition(file.etag), forHTTPHeaderField: "If-Match")
            outcome = .uncertain
            let (_,response) = try await session.data(for: r)
            let http = try MutationFailure.validate(response)
            // A 207 may contain individual failures. Do not report deletion as successful.
            guard [200,204].contains(http.statusCode) else { throw SyncError.invalidResponse }
        } catch { throw MutationFailure.wrapping(error,outcome: outcome) }
    }
    public func createLink(_ file: CloudFile) async throws -> URL {
        struct Permission: Decodable { struct Link: Decodable { let webUrl: URL }; let link: Link }
        let base = ["graph","v1beta1","drives",file.space.id]
        let path = file.path.isEmpty ? ["root","createLink"] : ["items",file.fileID,"createLink"]
        let result: Permission = try await json(endpoint(base + path),method: "POST",body: ["type":"view"])
        guard HTTPClient.sameOrigin(serverURL,result.link.webUrl) else { throw SyncError.invalidResponse }
        return result.link.webUrl
    }
    public func webURL(_ file: CloudFile) async throws -> URL {
        struct Item: Decodable { let webUrl: URL }
        let result: Item = try await json(endpoint(["graph","v1.0","drives",file.space.id,"items",file.fileID]))
        guard HTTPClient.sameOrigin(serverURL,result.webUrl) else { throw SyncError.invalidResponse }
        return result.webUrl
    }
}

/// Namespace-aware DAV parsing. A failed resource or propstat cannot turn a partial listing into a deletion.
enum DAVDecoder {
    static func decode(_ data: Data, space: CloudSpace, requestedURL: URL) throws -> [CloudFile] {
        let delegate = DAVParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failed, delegate.sawMultistatus else { throw SyncError.invalidResponse }
        return try delegate.rows.map { row in
            guard let href = row["DAV:|href"], let url = URL(string: href, relativeTo: requestedURL)?.absoluteURL,
                  HTTPClient.sameOrigin(space.davURL,url), url.query == nil,
                  let id = row["http://owncloud.org/ns|fileid"] ?? row["http://owncloud.org/ns|id"], !id.isEmpty,
                  let etag = row["DAV:|getetag"], row["DAV:|resourcetype"] != nil else { throw SyncError.invalidResponse }
            func parts(_ url: URL) throws -> [String] {
                guard let c = URLComponents(url: url,resolvingAgainstBaseURL: false) else { throw SyncError.invalidResponse }
                let values = c.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? "" }
                try RemotePath.validate(values); return values
            }
            let root = try parts(space.davURL), full = try parts(url)
            guard RemotePath.contains(root,full) else { throw SyncError.invalidResponse }
            let path = Array(full.dropFirst(root.count))
            let isDirectory = row["DAV:|collection"] != nil
            _ = try OpenCloudAPI.condition(etag)
            let size = row["DAV:|getcontentlength"].flatMap(Int64.init)
            guard isDirectory || size.map({ $0 >= 0 }) == true else { throw SyncError.invalidResponse }
            let checksum = row["http://owncloud.org/ns|checksum"].flatMap { value -> String? in
                value.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.uppercased().hasPrefix("SHA1:") }).map { String($0.dropFirst(5)) }
            }
            return CloudFile(space: space,fileID: id,path: path,isDirectory: isDirectory,etag: etag,size: size,
                             modifiedAt: row["DAV:|getlastmodified"] ?? "",permissions: row["http://owncloud.org/ns|permissions"],checksum: checksum)
        }
    }
}

private final class DAVParser: NSObject, XMLParserDelegate {
    var rows: [[String:String]] = []
    var failed = false, sawMultistatus = false
    private var row: [String:String] = [:], props: [String:String] = [:]
    private var stack: [String] = [], value = "", propStatus = "", responseStatus = ""
    func parser(_ parser: XMLParser,didStartElement elementName: String,namespaceURI: String?,qualifiedName qName: String?,attributes attributeDict: [String:String]) {
        let key = (namespaceURI ?? "") + "|" + elementName
        stack.append(key); value = ""
        if stack.count == 1, key != "DAV:|multistatus" { failed = true }
        if key == "DAV:|multistatus" { sawMultistatus = true }
        if key == "DAV:|response" { row = [:]; responseStatus = "" }
        if key == "DAV:|propstat" { props = [:]; propStatus = "" }
        if key == "DAV:|collection" { props[key] = "true" }
    }
    func parser(_ parser: XMLParser,foundCharacters string: String) { value += string }
    func parser(_ parser: XMLParser,didEndElement elementName: String,namespaceURI: String?,qualifiedName qName: String?) {
        let key = (namespaceURI ?? "") + "|" + elementName
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "DAV:|status" {
            if stack.contains("DAV:|propstat") { propStatus = trimmed } else { responseStatus = trimmed }
        } else if key == "DAV:|href" { row[key] = trimmed }
        else if key == "DAV:|propstat" {
            let code = propStatus.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            if code == 200 { row.merge(props,uniquingKeysWith: { _,new in new }) }
            // Optional properties may return 404; required ones are validated after parsing.
            else if code != 404 { failed = true }
        } else if key == "DAV:|response" {
            if !responseStatus.isEmpty, responseStatus.split(separator: " ").dropFirst().first != "200" { failed = true }
            rows.append(row)
        } else if key == "DAV:|resourcetype", stack.contains("DAV:|prop") { props[key] = trimmed }
        else if key == "http://owncloud.org/ns|checksum" { props[key] = [props[key],trimmed].compactMap { $0 }.joined(separator: " ") }
        else if stack.contains("DAV:|prop"), !trimmed.isEmpty { props[key] = trimmed }
        _ = stack.popLast(); value = ""
    }
    func parser(_ parser: XMLParser,parseErrorOccurred parseError: Error) { failed = true }
}
