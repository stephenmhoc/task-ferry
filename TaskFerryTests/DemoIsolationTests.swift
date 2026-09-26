import Foundation
import XCTest

@MainActor
final class DemoIsolationTests: XCTestCase {
    func testRoleChangesAndConfigurationNeverUseLiveDependencies() async throws {
        let name = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("production endpoint", forKey: AppPreferences.endpoint)
        let credentials = ForbiddenDemoCredentials()
        let factory = ReminderServiceFactory(
            makeBridgeService: { XCTFail("Demo must not create EventKit service"); return DemoReminderService() },
            makeRemoteService: { _ in XCTFail("Demo must not create network service"); return DemoReminderService() },
            makeBridgeServer: { _, _ in fatalError("Demo must not create a listener") }
        )
        let state = AppState(isDemo: true, defaults: defaults, credentialStore: credentials, serviceFactory: factory)
        for role in [AppMode.bridge, .remote, .bridge] {
            state.resetMode()
            await state.chooseMode(role)
            XCTAssertEqual(state.snapshot.reminders.count, 4)
            XCTAssertFalse(state.bridgeToken.isEmpty)
        }
        _ = try await state.regenerateBridgeToken()
        state.resetMode()
        await state.chooseMode(.remote)
        try await state.saveRemoteConfiguration(endpoint: "https://demo.example.com", clientID: "demo", clientSecret: "demo", bridgeToken: "demo")
        let outcome = await state.createReminder(title: "Demo mutation", listID: "personal", due: nil)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.endpoint), "production endpoint")
        XCTAssertEqual(credentials.calls, 0)
    }

    func testDemoCloudflareStorageDoesNotTouchCredentials() async {
        let credentials = ForbiddenDemoCredentials()
        let state = AppState(isDemo: true, credentialStore: credentials)
        await state.chooseMode(.bridge)
        do {
            try await state.removeStoredCloudflareProvisioning()
            XCTFail("Demo must reject live provisioning")
        } catch {}
        state.startCloudflareConnector()
        state.cleanUpOrphanedConnector()
        XCTAssertEqual(credentials.calls, 0)
    }

    func testScenariosExposeEmptyLoadingAndCachedOfflineStates() async {
        let empty = AppState(isDemo: true, demoScenario: .empty)
        await empty.refresh()
        XCTAssertTrue(empty.hasLoadedSnapshot)
        XCTAssertEqual(empty.snapshot.lists.count, 2)
        XCTAssertTrue(empty.snapshot.reminders.isEmpty)
        let loading = AppState(isDemo: true, demoScenario: .loading)
        await loading.refresh()
        XCTAssertFalse(loading.hasLoadedSnapshot)
        XCTAssertEqual(loading.connectionState, .loading)
        let offline = AppState(isDemo: true, demoScenario: .offline)
        await offline.refresh()
        XCTAssertTrue(offline.isShowingCachedSnapshot)
        XCTAssertTrue(offline.isOffline)
        XCTAssertFalse(offline.snapshot.reminders.isEmpty)
        let original = offline.snapshot
        let outcome = await offline.createReminder(title: "Offline change", listID: "personal", due: nil)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(offline.snapshot, original)
    }

    func testUnconfiguredDemoCanConnectWithoutLosingEndpoint() async throws {
        let state = AppState(isDemo: true, demoScenario: .unconfigured)
        XCTAssertNil(state.mode)
        await state.chooseMode(.remote)
        XCTAssertTrue(state.endpoint.isEmpty)
        try await state.saveRemoteConfiguration(endpoint: "https://demo.example.com", clientID: "demo", clientSecret: "demo", bridgeToken: "demo")
        XCTAssertEqual(state.endpoint, "https://demo.example.com")
        await state.refresh()
        XCTAssertTrue(state.hasLoadedSnapshot)
    }
}

private final class ForbiddenDemoCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    private func record() { lock.withLock { count += 1 } }
    func string(for account: String) -> String { record(); return "" }
    func read(_ account: String) throws -> String { record(); return "" }
    func set(_ value: String, for account: String) throws { record() }
    func randomToken() throws -> String { record(); return "unexpected" }
}
