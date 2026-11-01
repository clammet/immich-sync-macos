import Foundation

/// Stored inside an operation's private Recovery directory. Never persist the
/// app token; the upload URL itself may contain a short-lived transfer token.
struct TUSUploadCheckpoint: Codable {
    let fingerprint: String
    var location: URL?
    var accepted = false
    var etag: String?
    var file: CloudFile?
    var completionAttempted: Bool? = false
}

/// TUS creation followed by bounded PATCH chunks. There is no PUT fallback or
/// automatic recreation of expired/ambiguous sessions: pending bytes survive.
struct TUSUploader {
    let api: OpenCloudAPI
    let session: URLSession
    let chunkSize: Int
    let binding: String

    func upload(parent: CloudFile, name: String, contents: URL, replacing: CloudFile?, progress: Progress,
                checkpointURL: URL?) async throws -> CloudFile {
        var outcome = MutationOutcome.notSent
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: contents.path)
            guard let length = attributes[.size] as? NSNumber, length.int64Value >= 0 else { throw SyncError.invalidResponse }
            let size = length.int64Value
            let digest = try FileDigest.sha1(contents).map { String(format: "%02x",$0) }.joined()
            let target = parent.path + [name]
            let fingerprint = RemotePath.digest([binding,parent.space.id,parent.fileID,
                RemotePath.digest(target.joined(separator: "\0")),replacing?.fileID ?? "create",
                replacing?.etag ?? "",String(size),digest].joined(separator: "\0"))
            var checkpoint: TUSUploadCheckpoint
            let resuming = checkpointURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if resuming, let checkpointURL {
                checkpoint = try JSONDecoder().decode(TUSUploadCheckpoint.self,from: Data(contentsOf: checkpointURL))
                guard checkpoint.fingerprint == fingerprint else { throw SyncError.conflict }
            } else { checkpoint = TUSUploadCheckpoint(fingerprint: fingerprint) }

            func save() throws {
                guard let checkpointURL else { return }
                let data = try JSONEncoder().encode(checkpoint)
                try data.write(to: checkpointURL,options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: checkpointURL.path)
                let file = try FileHandle(forWritingTo: checkpointURL)
                defer { try? file.close() }
                try file.synchronize()
            }
            func check() throws {
                try Task.checkCancellation()
                if progress.isCancelled { throw CancellationError() }
            }
            progress.totalUnitCount = max(1,size)
            try check()
            if !resuming {
                // Record the attempt before POST. If its response is lost, retrying
                // this operation cannot blindly create a second upload session.
                try save()
                var request = try api.request(url: parent.space.davURL,method: "POST")
                request.setValue("1.0.0",forHTTPHeaderField: "Tus-Resumable")
                request.setValue(String(size),forHTTPHeaderField: "Upload-Length")
                let metadata = ["filename " + Data(target.joined(separator: "/").utf8).base64EncodedString(),
                                "checksum " + Data(("SHA1 " + digest).utf8).base64EncodedString()]
                request.setValue(metadata.joined(separator: ","),forHTTPHeaderField: "Upload-Metadata")
                if let replacing { request.setValue(try OpenCloudAPI.condition(replacing.etag),forHTTPHeaderField: "If-Match") }
                else { request.setValue("*",forHTTPHeaderField: "If-None-Match") }
                if size == 0 {
                    request.setValue("application/offset+octet-stream",forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data()
                }
                outcome = .uncertain
                let (_,response) = try await session.data(for: request)
                let http = try MutationFailure.validate(response)
                guard http.statusCode == 201, http.value(forHTTPHeaderField: "Tus-Resumable") == "1.0.0" else { throw SyncError.invalidResponse }
                // OpenCloud's zero-byte TouchFile shortcut returns 201 without a
                // Location. It still requires the same post-upload verification.
                if size == 0 { checkpoint.accepted = true }
                else {
                    guard let location = http.value(forHTTPHeaderField: "Location"), !location.isEmpty,
                          let url = URL(string: location,relativeTo: request.url)?.absoluteURL else { throw SyncError.invalidResponse }
                    try validateLocation(url)
                    checkpoint.location = url
                }
                checkpoint.etag = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "OC-ETag")
                try save()
            }

            if !checkpoint.accepted {
                // No recorded Location means POST's outcome was ambiguous. An
                // expired session is also kept for recovery, never replayed as PUT.
                outcome = checkpoint.completionAttempted == false && checkpoint.location != nil ? .interrupted : .uncertain
                guard let location = checkpoint.location else { throw SyncError.conflict }
                try validateLocation(location)
                var head = try api.request(url: location,method: "HEAD")
                head.setValue("1.0.0",forHTTPHeaderField: "Tus-Resumable")
                let (_,response) = try await session.data(for: head)
                if let status = (response as? HTTPURLResponse)?.statusCode, [404,410].contains(status) {
                    throw MutationFailure(outcome: .expired,underlyingError: SyncError.conflict)
                }
                let http = try HTTPClient.validate(response)
                guard [200,204].contains(http.statusCode), http.value(forHTTPHeaderField: "Tus-Resumable") == "1.0.0",
                      let offsetText = http.value(forHTTPHeaderField: "Upload-Offset"), let initialOffset = Int64(offsetText),
                      let length = http.value(forHTTPHeaderField: "Upload-Length"), Int64(length) == size,
                      initialOffset >= 0, initialOffset <= size else { throw SyncError.invalidResponse }
                var offset = initialOffset
                outcome = offset < size ? .interrupted : .uncertain
                progress.completedUnitCount = offset
                let file = try FileHandle(forReadingFrom: contents)
                defer { try? file.close() }
                while offset < size {
                    try check()
                    try file.seek(toOffset: UInt64(offset))
                    let count = Int(min(Int64(chunkSize),size - offset))
                    guard let bytes = try file.read(upToCount: count), bytes.count == count else { throw SyncError.conflict }
                    var patch = try api.request(url: location,method: "PATCH")
                    patch.setValue("1.0.0",forHTTPHeaderField: "Tus-Resumable")
                    patch.setValue(String(offset),forHTTPHeaderField: "Upload-Offset")
                    patch.setValue("application/offset+octet-stream",forHTTPHeaderField: "Content-Type")
                    if offset + Int64(count) == size {
                        checkpoint.completionAttempted = true
                        try save()
                        outcome = .uncertain
                    }
                    let (_,response) = try await session.upload(for: patch,from: bytes,
                        delegate: HTTPDelegate(progress,uploadOffset: offset,uploadLength: size))
                    let http = try MutationFailure.validate(response)
                    guard http.statusCode == 204, http.value(forHTTPHeaderField: "Tus-Resumable") == "1.0.0",
                          let next = http.value(forHTTPHeaderField: "Upload-Offset"), Int64(next) == offset + Int64(count) else {
                        throw SyncError.invalidResponse
                    }
                    offset += Int64(count)
                    if offset == size {
                        checkpoint.etag = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "OC-ETag")
                    }
                    progress.completedUnitCount = offset
                }
                checkpoint.accepted = true
                try save()
            }
            outcome = .uncertain
            try check()
            let current = try await api.properties(space: parent.space,path: target)
            guard !current.isDirectory, current.size == size,
                  replacing.map({ $0.fileID == current.fileID }) ?? true,
                  checkpoint.etag.map({ $0 == current.etag }) ?? true,
                  checkpoint.file.map({ $0.id == current.id && $0.etag == current.etag }) ?? true else { throw SyncError.conflict }
            if let checksum = current.checksum {
                guard checksum.lowercased() == digest else { throw SyncError.conflict }
            } else {
                // TouchFile can omit the checksum. Verify actual bytes through a
                // conditional disk download rather than accepting size alone.
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let downloaded = try await api.download(current,into: directory,progress: Progress())
                let checksum = try FileDigest.sha1(downloaded).map { String(format: "%02x",$0) }.joined()
                guard checksum == digest else { throw SyncError.conflict }
            }
            checkpoint.file = current
            try save()
            progress.completedUnitCount = progress.totalUnitCount
            return current
        } catch { throw MutationFailure.wrapping(error,outcome: outcome) }
    }

    private func validateLocation(_ url: URL) throws {
        guard HTTPClient.sameOrigin(api.serverURL,url), url.query == nil else { throw SyncError.invalidServer }
    }
}
