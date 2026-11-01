import FileProvider
import Foundation

public struct RegisteredProviderDomain: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var userEnabled: Bool

    public init(id: String, displayName: String, userEnabled: Bool) {
        self.id = id; self.displayName = displayName; self.userEnabled = userEnabled
    }
}

public protocol ProviderDomainRegistry: Sendable {
    func domains() async throws -> [RegisteredProviderDomain]
    func add(id: String, displayName: String) async throws
}

public struct SystemProviderDomainRegistry: ProviderDomainRegistry {
    public init() {}
    public func domains() async throws -> [RegisteredProviderDomain] {
        try await NSFileProviderManager.domains().map {
            RegisteredProviderDomain(id: $0.identifier.rawValue, displayName: $0.displayName, userEnabled: $0.userEnabled)
        }
    }
    public func add(id: String, displayName: String) async throws {
        try await NSFileProviderManager.add(NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: displayName))
    }
}

/// Reconciles the saved account with macOS without creating duplicate locations or changing user consent.
public struct ProviderRegistration: Sendable {
    public enum State: Sendable, Equatable { case signInRequired, registering, needsEnablement, ready }
    private let registry: any ProviderDomainRegistry
    public init(registry: any ProviderDomainRegistry = SystemProviderDomainRegistry()) { self.registry = registry }

    public func reconcile(account: Account?) async throws -> State {
        // Querying domains also establishes the system's domain-change notifications.
        let existing = try await registry.domains()
        guard let account else { return .signInRequired }
        let name = "OpenCloud — \(account.displayName)"
        if let domain = existing.first(where: { $0.id == account.id }), domain.displayName == name {
            return domain.userEnabled ? .ready : .needsEnablement
        }
        try await registry.add(id: account.id, displayName: name)
        guard let domain = try await registry.domains().first(where: { $0.id == account.id }) else { return .registering }
        return domain.userEnabled ? .ready : .needsEnablement
    }
}
