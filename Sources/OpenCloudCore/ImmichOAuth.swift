import CryptoKit
import Foundation
import Security

public struct OAuthChallenge: Sendable {
    public static let redirectURI = "opencloud-sync://oauth"
    public let state: String
    public let verifier: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init() throws {
        state = try Self.random(); verifier = try Self.random()
    }
    public func validate(_ callback: URL) throws {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == "opencloud-sync", components.host == "oauth", components.path.isEmpty,
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let query = components.queryItems,
              query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == state,
              query.filter({ $0.name == "code" }).count == 1,
              query.first(where: { $0.name == "code" })?.value?.isEmpty == false,
              !query.contains(where: { $0.name == "error" }) else { throw SyncError.invalidOAuthCallback }
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SyncError.invalidResponse }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
