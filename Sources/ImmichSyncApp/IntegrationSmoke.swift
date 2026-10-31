#if DEBUG
import AppKit
import CryptoKit
import FileProvider
import Foundation
import ImmichCore

/// Runs only in the separately signed integration bundle, against the disposable loopback server.
@MainActor enum IntegrationSmoke {
    private enum Failure: Error { case check(String) }

    static func run(model: AppModel) async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard Bundle.main.bundleIdentifier?.hasSuffix(".integration") == true,
                  let server = env["IMMICH_SMOKE_SERVER"], let url = URL(string: server),
                  url.scheme == "http", url.host == "127.0.0.1",
                  let email = env["IMMICH_SMOKE_EMAIL"], let password = env["IMMICH_SMOKE_PASSWORD"],
                  let assetID = env["IMMICH_SMOKE_ASSET"], let checksum = env["IMMICH_SMOKE_CHECKSUM"] else {
                throw Failure.check("Use scripts/integration.py smoke with the isolated integration bundle")
            }
            if model.account != nil {
                await model.disconnect()
                guard model.account == nil else { throw Failure.check("Previous smoke domain could not be disconnected") }
            }
            await model.signIn(server: server, email: email, password: password, allowHTTP: true)
            guard model.error == nil, let account = model.account,
                  let manager = NSFileProviderManager(for: model.domain(for: account)) else {
                throw Failure.check(model.error ?? "Main-app sign-in did not create a File Provider domain")
            }
            let token = try CredentialStore.read(for: account)
            let api = ImmichAPI(serverURL: account.serverURL, token: { token })
            guard try await api.currentSessionID() == account.sessionID else { throw Failure.check("Session mismatch") }
            print("SMOKE PASS main-app password sign-in and App Group credential access")
            let root = try await visibleURL(manager, .rootContainer)
            guard root.startAccessingSecurityScopedResource() else { throw Failure.check("Root security scope unavailable") }
            defer { root.stopAccessingSecurityScopedResource() }
            // Access the actual provider location so macOS launches the embedded extension and enumerates it.
            let catalog = try Catalog(url: SharedStore.catalogURL(accountID: account.id))
            let deadline = Date().addingTimeInterval(120)
            var found = false
            while Date() < deadline {
                _ = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                if (try? catalog.item(ItemRecord.assetID(assetID))) != nil { found = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard found else {
                let status = try catalog.state("status", as: SyncStatus.self)
                throw Failure.check(status?.message ?? "Provider indexing timed out; enable the integration extension in System Settings")
            }
            let roots = try FileManager.default.contentsOfDirectory(atPath: root.path)
            guard roots.contains("Folder View"), roots.contains("Albums") else { throw Failure.check("Provider root containers missing") }
            let file = try await visibleURL(manager, NSFileProviderItemIdentifier(ItemRecord.assetID(assetID)))
            guard file.startAccessingSecurityScopedResource() else { throw Failure.check("File security scope unavailable") }
            defer { file.stopAccessingSecurityScopedResource() }
            let bytes = try await Task.detached {
                var failure: NSError?
                var result: Result<Data, Error>?
                NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &failure) { coordinated in
                    result = Result { try Data(contentsOf: coordinated) }
                }
                if let failure { throw failure }
                guard let result else { throw Failure.check("File coordination returned no result") }
                return try result.get()
            }.value
            guard Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString() == checksum else {
                throw Failure.check("Materialized original checksum mismatch")
            }
            print("SMOKE PASS embedded provider indexing, root enumeration, coordinated original download and checksum")
            await model.disconnect()
            guard model.account == nil else { throw Failure.check(model.error ?? "Disconnect failed") }
            do { _ = try CredentialStore.read(for: account); throw Failure.check("Credential survived disconnect") }
            catch SyncError.missingAccount { }
            do { _ = try await api.currentSessionID(); throw Failure.check("Session survived disconnect") }
            catch SyncError.http(401, _) { }
            print("SMOKE PASS main-app disconnect, credential deletion, server session revocation")
            fflush(stdout)
            exit(0)
        } catch {
            // Never print the environment, credentials, or server response body.
            print("SMOKE FAIL: \(error)")
            fflush(stdout)
            exit(1)
        }
    }

    private static func visibleURL(_ manager: NSFileProviderManager, _ id: NSFileProviderItemIdentifier) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: id) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? Failure.check("Provider URL unavailable")) }
            }
        }
    }
}
#endif
