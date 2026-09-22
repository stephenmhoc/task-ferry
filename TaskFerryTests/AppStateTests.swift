import Foundation
import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    func testConnectionCodeStoresTheCompleteRemoteConfiguration() async throws {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        let credentials = InMemoryCredentialStore(values: [:])
        let service = MutationFailingService()
        let factory = ReminderServiceFactory(
            makeBridgeService: { service },
            makeRemoteService: { _ in service },
            makeBridgeServer: { BridgeServer(operations: $0, token: $1) }
        )
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: factory,
            snapshotCache: .disabled
        )
        let code = try TaskFerryConnectionCode(
            endpoint: "https://task-ferry.example.com",
            accessClientID: "client-id",
            accessClientSecret: "client-secret",
            bridgeToken: "bridge-token"
        ).encoded()

        try await state.saveConnectionCode("\n\(code)\n")

        XCTAssertEqual(state.endpoint, "https://task-ferry.example.com")
        XCTAssertEqual(credentials.value(for: "remote-access-client-id"), "client-id")
        XCTAssertEqual(credentials.value(for: "remote-access-client-secret"), "client-secret")
        XCTAssertEqual(credentials.value(for: "remote-bridge-token"), "bridge-token")
        XCTAssertEqual(credentials.value(for: "bridge-token"), "", "A remote must not write the bridge's own token")
    }

    func testFailedMutationReturnsFalseAndBackgroundRefreshPreservesItsError() async {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let credentials = InMemoryCredentialStore(values: ["bridge-token": "TEST-TOKEN"])
        let service = MutationFailingService()
        let factory = ReminderServiceFactory(
            makeBridgeService: { service },
            makeRemoteService: { _ in service },
            makeBridgeServer: { BridgeServer(operations: $0, token: $1) }
        )
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: factory,
            snapshotCache: .disabled
        )
        XCTAssertFalse(state.hasLoadedSnapshot)
        await state.start()

        let mutationSucceeded = await state.createList(title: "Will fail").succeeded
        XCTAssertFalse(mutationSucceeded)
        XCTAssertEqual(state.errorMessage, "Mutation failed")

        let refreshSucceeded = await state.refresh(showLoadingIndicator: false)
        XCTAssertTrue(refreshSucceeded)
        XCTAssertTrue(state.hasLoadedSnapshot)
        XCTAssertEqual(state.errorMessage, "Mutation failed")
    }

    func testFailedFirstRefreshDoesNotMarkSnapshotAsLoaded() async {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let credentials = InMemoryCredentialStore(values: ["bridge-token": "TEST-TOKEN"])
        let service = SnapshotFailingService()
        let factory = ReminderServiceFactory(
            makeBridgeService: { service },
            makeRemoteService: { _ in service },
            makeBridgeServer: { BridgeServer(operations: $0, token: $1) }
        )
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: factory,
            snapshotCache: .disabled
        )

        let refreshSucceeded = await state.refresh()

        XCTAssertFalse(refreshSucceeded)
        XCTAssertFalse(state.hasLoadedSnapshot)
        XCTAssertEqual(state.connectionState, .failed)
    }

    func testCredentialReadsAreDeferredOffTheMainThread() async {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let credentials = InMemoryCredentialStore(values: ["bridge-token": "TEST-TOKEN"])
        let service = MutationFailingService()
        let factory = ReminderServiceFactory(
            makeBridgeService: { service },
            makeRemoteService: { _ in service },
            makeBridgeServer: { BridgeServer(operations: $0, token: $1) }
        )
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: factory,
            snapshotCache: .disabled
        )

        XCTAssertEqual(state.bridgeToken, "")
        XCTAssertEqual(credentials.readCount, 0)

        await state.start()

        XCTAssertEqual(state.bridgeToken, "TEST-TOKEN")
        XCTAssertGreaterThan(credentials.readCount, 0)
        XCTAssertFalse(credentials.readOccurredOnMainThread)
        // A connection saved by an earlier version moves to the remote's own Keychain items.
        XCTAssertEqual(credentials.value(for: "remote-bridge-token"), "TEST-TOKEN")
        XCTAssertEqual(credentials.value(for: "bridge-token"), "")
    }

    func testRemoteModeRefreshesWithoutAnActiveViewAndStopsAfterReset() async {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let credentials = InMemoryCredentialStore(values: ["bridge-token": "TEST-TOKEN"])
        let service = CountingService()
        let factory = ReminderServiceFactory(
            makeBridgeService: { service },
            makeRemoteService: { _ in service },
            makeBridgeServer: { BridgeServer(operations: $0, token: $1) }
        )
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: factory,
            snapshotCache: .disabled,
            automaticRefreshInterval: .milliseconds(10)
        )

        await state.start()
        for _ in 0..<50 where service.snapshotCount < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(service.snapshotCount, 2)

        state.resetMode()
        let countAfterReset = service.snapshotCount
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(service.snapshotCount, countAfterReset)
    }

    func testDockBadgeDefaultsToTodayAndOverdue() {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        let state = AppState(isDemo: false, defaults: defaults, snapshotCache: .disabled)
        let date = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            year: 2026,
            month: 7,
            day: 30,
            hour: 12
        ).date!
        state.snapshot = ReminderSnapshot(
            lists: [],
            reminders: [
                reminder(id: "overdue", year: 2026, month: 7, day: 29),
                reminder(id: "today", year: 2026, month: 7, day: 30),
                reminder(id: "tomorrow", year: 2026, month: 7, day: 31),
                ReminderRecord(id: "no-due-date", listID: "list", title: "No due date")
            ]
        )

        XCTAssertTrue(state.showsDockBadge)
        XCTAssertEqual(state.dockBadgeScope, .todayAndOverdue)
        XCTAssertEqual(state.dockBadgeCount(on: date), 2)
    }

    func testDockBadgeCanShowOnlyOverdueRemindersOrBeDisabled() {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        let state = AppState(isDemo: false, defaults: defaults, snapshotCache: .disabled)
        let date = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            year: 2026,
            month: 7,
            day: 30,
            hour: 12
        ).date!
        state.snapshot = ReminderSnapshot(
            lists: [],
            reminders: [
                reminder(id: "overdue", year: 2026, month: 7, day: 29),
                reminder(id: "today", year: 2026, month: 7, day: 30)
            ]
        )

        state.setDockBadgeScope(.overdueOnly)
        XCTAssertEqual(state.dockBadgeCount(on: date), 1)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.dockBadgeScope), DockBadgeScope.overdueOnly.rawValue)

        state.setShowsDockBadge(false)
        XCTAssertEqual(state.dockBadgeCount(on: date), 0)
        XCTAssertFalse(defaults.bool(forKey: AppPreferences.showsDockBadge))
    }

    func testAllRemindersSortsDatedTasksBeforeUndatedTasks() {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        let state = AppState(isDemo: false, defaults: defaults, snapshotCache: .disabled)
        state.snapshot = ReminderSnapshot(
            lists: [],
            reminders: [
                ReminderRecord(id: "undated-z", listID: "list", title: "Zulu"),
                reminder(id: "later", year: 2026, month: 8, day: 2),
                ReminderRecord(id: "undated-a", listID: "list", title: "Alpha"),
                reminder(id: "earlier", year: 2026, month: 8, day: 1)
            ]
        )

        XCTAssertEqual(
            state.allReminders.map(\.id),
            ["earlier", "later", "undated-a", "undated-z"]
        )
    }
}

@MainActor
private final class MutationFailingService: ReminderService {
    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if request.operation != .snapshot {
            throw ReminderServiceError.message("Mutation failed")
        }
        return RPCResult(snapshot: .empty)
    }
}

@MainActor
private final class SnapshotFailingService: ReminderService {
    func execute(_ request: RPCRequest) async throws -> RPCResult {
        throw ReminderServiceError.message("Snapshot failed")
    }
}

@MainActor
private final class CountingService: ReminderService {
    private(set) var snapshotCount = 0

    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if request.operation == .snapshot {
            snapshotCount += 1
        }
        return RPCResult(snapshot: .empty)
    }
}

private func reminder(id: String, year: Int, month: Int, day: Int) -> ReminderRecord {
    ReminderRecord(
        id: id,
        listID: "list",
        title: id,
        due: ReminderDue(year: year, month: month, day: day)
    )
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var reads = 0
    private var mainThreadRead = false

    init(values: [String: String]) {
        self.values = values
    }

    func string(for account: String) -> String {
        lock.withLock {
            reads += 1
            mainThreadRead = mainThreadRead || Thread.isMainThread
            return values[account] ?? ""
        }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock { values[account] = value }
    }

    func randomToken() throws -> String {
        "TEST-TOKEN"
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    var readOccurredOnMainThread: Bool {
        lock.withLock { mainThreadRead }
    }

    func value(for account: String) -> String {
        lock.withLock { values[account] ?? "" }
    }
}
