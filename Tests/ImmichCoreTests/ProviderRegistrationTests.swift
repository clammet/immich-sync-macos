import XCTest
@testable import ImmichCore

final class ProviderRegistrationTests: XCTestCase {
    private func account() -> Account {
        Account(serverURL: URL(string: "https://example.invalid/api")!, userID: "owner", displayName: "Test",
                email: "test@example.invalid", sessionID: "session", allowHTTP: false)
    }
    func testFirstLaunchWithoutAccountDoesNotCreateAnEmptyLocation() async throws {
        let registry = Registry()
        let state = try await ProviderRegistration(registry: registry).reconcile(account: nil)
        XCTAssertEqual(state, .signInRequired)
        let additions = await registry.additions
        XCTAssertTrue(additions.isEmpty)
    }
    func testMissingDomainIsRestoredAndRequiresUserEnablement() async throws {
        let registry = Registry()
        let account = account()
        let registration = ProviderRegistration(registry: registry)
        let state = try await registration.reconcile(account: account)
        XCTAssertEqual(state, .needsEnablement)
        _ = try await registration.reconcile(account: account)
        let additions = await registry.additions
        XCTAssertEqual(additions, [account.id])
    }
    func testExistingEnabledDomainIsReusedAndConsentChangesAreObserved() async throws {
        let account = account()
        let registry = Registry([RegisteredProviderDomain(id: account.id, displayName: "OpenCloud — Test", userEnabled: true)])
        let registration = ProviderRegistration(registry: registry)
        let ready = try await registration.reconcile(account: account)
        XCTAssertEqual(ready, .ready)
        await registry.disable()
        let disabled = try await registration.reconcile(account: account)
        XCTAssertEqual(disabled, .needsEnablement)
        let additions = await registry.additions
        XCTAssertTrue(additions.isEmpty)
    }
    func testDisplayNameUpdatePreservesIdentityAndOtherDomains() async throws {
        let account = account()
        let other = RegisteredProviderDomain(id: "other", displayName: "Other", userEnabled: true)
        let registry = Registry([other, RegisteredProviderDomain(id: account.id, displayName: "Old name", userEnabled: true)])
        let state = try await ProviderRegistration(registry: registry).reconcile(account: account)
        XCTAssertEqual(state, .ready)
        let domains = try await registry.domains()
        XCTAssertEqual(domains.count, 2)
        XCTAssertTrue(domains.contains(other))
        XCTAssertEqual(domains.first { $0.id == account.id }?.displayName, "OpenCloud — Test")
    }
    func testDelayedSystemPublicationIsRetriedWithoutAnotherAdd() async throws {
        let registry = Registry(delayed: true)
        let account = account()
        let registration = ProviderRegistration(registry: registry)
        let pending = try await registration.reconcile(account: account)
        XCTAssertEqual(pending, .registering)
        await registry.publish()
        let published = try await registration.reconcile(account: account)
        XCTAssertEqual(published, .needsEnablement)
        let additions = await registry.additions
        XCTAssertEqual(additions, [account.id])
    }
}

private actor Registry: ProviderDomainRegistry {
    var values: [RegisteredProviderDomain]
    var additions: [String] = []
    let delayed: Bool
    var pending: RegisteredProviderDomain?
    init(_ values: [RegisteredProviderDomain] = [], delayed: Bool = false) { self.values = values; self.delayed = delayed }
    func domains() async throws -> [RegisteredProviderDomain] { values }
    func add(id: String, displayName: String) async throws {
        additions.append(id)
        if let index = values.firstIndex(where: { $0.id == id }) { values[index].displayName = displayName }
        else {
            let domain = RegisteredProviderDomain(id: id, displayName: displayName, userEnabled: false)
            if delayed { pending = domain } else { values.append(domain) }
        }
    }
    func publish() { if let pending { values.append(pending); self.pending = nil } }
    func disable() { values[0].userEnabled = false }
}
