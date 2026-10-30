import AppKit
import AuthenticationServices
import Foundation

@MainActor final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "immich-sync") { [weak self] callback, error in
                Task { @MainActor in
                    self?.session = nil
                    if let callback { continuation.resume(returning: callback) }
                    else if (error as NSError?)?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: CancellationError())
                    } else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
