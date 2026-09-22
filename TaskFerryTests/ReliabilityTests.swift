import Foundation
import XCTest

final class RequestLedgerTests: XCTestCase {
    func testRemembersCreatedIdentifierUntilItExpires() {
        var ledger = RequestLedger(capacity: 10, lifetime: 60)
        let start = Date(timeIntervalSince1970: 1_000)

        ledger.record("request", createdID: "reminder", now: start)

        XCTAssertEqual(ledger.entry(for: "request", now: start.addingTimeInterval(30))?.createdID, "reminder")
        XCTAssertNil(ledger.entry(for: "request", now: start.addingTimeInterval(61)))
    }

    func testEvictsOldestEntriesBeyondCapacity() {
        var ledger = RequestLedger(capacity: 2, lifetime: 600)
        let now = Date()

        ledger.record("a", createdID: nil, now: now)
        ledger.record("b", createdID: nil, now: now)
        ledger.record("c", createdID: nil, now: now)

        XCTAssertNil(ledger.entry(for: "a", now: now))
        XCTAssertNotNil(ledger.entry(for: "b", now: now))
        XCTAssertNotNil(ledger.entry(for: "c", now: now))
    }
}

final class SnapshotCacheTests: XCTestCase {
    func testRoundTripsOnlyForTheSameEndpointAndIsPrivate() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = SnapshotCache(fileURL: folder.appending(path: "snapshot.json"))
        let snapshot = ReminderSnapshot(
            lists: [ReminderListRecord(id: "l", title: "List", colorHex: "FF0000")],
            reminders: [ReminderRecord(id: "r", listID: "l", title: "Title", due: ReminderDue(year: 2026, month: 9, day: 22))]
        )

        await cache.save(.init(endpoint: "https://a.example.com", savedAt: Date(timeIntervalSince1970: 5), snapshot: snapshot))

        XCTAssertEqual(cache.load(endpoint: "https://a.example.com")?.snapshot, snapshot)
        XCTAssertNil(cache.load(endpoint: "https://b.example.com"))
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "snapshot.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        cache.clear()
        XCTAssertNil(cache.load(endpoint: "https://a.example.com"))
    }
}

final class ReminderNotificationPlanTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testSchedulesTimedAndDateOnlyRemindersWithinTheHorizon() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 8)))
        let snapshot = ReminderSnapshot(
            lists: [ReminderListRecord(id: "work", title: "Work", colorHex: "0000FF")],
            reminders: [
                ReminderRecord(id: "timed", listID: "work", title: "Standup", notes: "Room 4\nsecond line",
                               due: ReminderDue(year: 2026, month: 9, day: 22, hour: 10, minute: 30, timeZoneIdentifier: "America/New_York")),
                ReminderRecord(id: "dated", listID: "work", title: "Expenses", due: ReminderDue(year: 2026, month: 9, day: 23)),
                ReminderRecord(id: "past", listID: "work", title: "Earlier", due: ReminderDue(year: 2026, month: 9, day: 21)),
                ReminderRecord(id: "far", listID: "work", title: "Later", due: ReminderDue(year: 2026, month: 12, day: 1)),
                ReminderRecord(id: "undated", listID: "work", title: "Someday")
            ]
        )

        let items = ReminderNotificationPlan.items(for: snapshot, now: now, dateOnlyHour: 9, calendar: calendar)

        XCTAssertEqual(items.map(\.reminderID), ["timed", "dated"])
        XCTAssertEqual(items[0].body, "Work · Room 4")
        XCTAssertEqual(calendar.component(.hour, from: items[1].fireDate), 9)
    }

    func testIdentifierChangesWhenTheReminderTextChanges() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let first = ReminderNotificationPlan.identifier(reminderID: "r", fireDate: date, title: "A", body: "")
        XCTAssertEqual(first, ReminderNotificationPlan.identifier(reminderID: "r", fireDate: date, title: "A", body: ""))
        XCTAssertNotEqual(first, ReminderNotificationPlan.identifier(reminderID: "r", fireDate: date, title: "B", body: ""))
    }

    func testRespectsTheSystemLimit() {
        let now = Date()
        let reminders = (0..<100).map { index in
            ReminderRecord(
                id: "\(index)",
                listID: "l",
                title: "\(index)",
                due: ReminderDue(date: now.addingTimeInterval(Double(index + 1) * 3_600), includesTime: true)
            )
        }
        let items = ReminderNotificationPlan.items(for: ReminderSnapshot(lists: [], reminders: reminders), now: now, dateOnlyHour: 9)
        XCTAssertEqual(items.count, ReminderNotificationPlan.limit)
        XCTAssertEqual(items.first?.reminderID, "0")
    }
}

final class TaskFerryURLTests: XCTestCase {
    func testParsesAdd() {
        XCTAssertEqual(
            TaskFerryURL(URL(string: "taskferry://add?title=Buy%20milk&list=Groceries&due=tomorrow&notes=2%25")!),
            .add(title: "Buy milk", list: "Groceries", due: .tomorrow, notes: "2%")
        )
        XCTAssertEqual(
            TaskFerryURL(URL(string: "taskferry://add")!),
            .add(title: nil, list: nil, due: .none, notes: nil)
        )
    }

    func testParsesShow() {
        XCTAssertEqual(TaskFerryURL(URL(string: "taskferry://show/tomorrow")!), .show(.tomorrow))
        XCTAssertEqual(TaskFerryURL(URL(string: "taskferry://show/list/Work")!), .show(.list("Work")))
        XCTAssertEqual(TaskFerryURL(URL(string: "taskferry://reminder/ABC")!), .show(.reminder("ABC")))
        XCTAssertEqual(TaskFerryURL(URL(string: "TaskFerry://show")!), .show(.today))
    }

    func testRejectsUnknownURLs() {
        XCTAssertNil(TaskFerryURL(URL(string: "https://example.com/add")!))
        XCTAssertNil(TaskFerryURL(URL(string: "taskferry://connect?code=TASKFERRY1:abc")!))
        XCTAssertNil(TaskFerryURL(URL(string: "taskferry://show/unknown")!))
    }
}

final class ReminderDueTimeZoneTests: XCTestCase {
    func testTimedReminderFromAnotherTimeZoneLandsOnTheLocalDay() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 8 AM on the 23rd in Tokyo is 7 PM on the 22nd in New York.
        let due = ReminderDue(year: 2026, month: 9, day: 23, hour: 8, minute: 0, timeZoneIdentifier: "Asia/Tokyo")
        let localEvening = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12)))

        XCTAssertTrue(due.isSameDay(as: localEvening, calendar: newYork))
        XCTAssertFalse(due.isBeforeDay(localEvening, calendar: newYork))
    }

    func testDateOnlyReminderFloats() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let due = ReminderDue(year: 2026, month: 9, day: 23)
        let day = try XCTUnwrap(tokyo.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 1)))

        XCTAssertTrue(due.isSameDay(as: day, calendar: tokyo))
    }
}

@MainActor
final class CloudflareConnectorOutputTests: XCTestCase {
    func testFindsTheMetricsAddressInJSONLogs() {
        let line = #"{"level":"info","time":"2026-09-22T10:00:00Z","message":"Starting metrics server on 127.0.0.1:53421/metrics"}"#
        XCTAssertEqual(CloudflareTunnelConnector.metricsAddress(in: line), "127.0.0.1:53421")
        XCTAssertNil(CloudflareTunnelConnector.metricsAddress(in: #"{"message":"Registered tunnel connection"}"#))
    }
}

// MARK: - AppState reliability

@MainActor
final class AppStateReliabilityTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    func testBackgroundSyncFailuresStayQuietUntilTheyPersist() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let service = SwitchableService()
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: TestCredentialStore(values: ["remote-bridge-token": "TOKEN"]),
            serviceFactory: .fixed(service),
            snapshotCache: .disabled,
            automaticRefreshInterval: .seconds(3_600)
        )

        let firstSync = await state.refresh()
        XCTAssertTrue(firstSync)
        service.failsSnapshots = true

        await state.refresh(showLoadingIndicator: false)
        await state.refresh(showLoadingIndicator: false)
        XCTAssertNil(state.errorMessage, "One or two missed background syncs shouldn't raise a banner")
        XCTAssertTrue(state.isOffline)

        await state.refresh(showLoadingIndicator: false)
        XCTAssertEqual(state.errorMessage, "Offline")

        service.failsSnapshots = false
        await state.refresh(showLoadingIndicator: false)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isOffline)
    }

    func testInteractiveFailureIsReportedImmediately() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let service = SwitchableService()
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: TestCredentialStore(values: ["remote-bridge-token": "TOKEN"]),
            serviceFactory: .fixed(service),
            snapshotCache: .disabled,
            automaticRefreshInterval: .seconds(3_600)
        )
        await state.refresh()
        service.failsSnapshots = true

        let succeeded = await state.refresh()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(state.errorMessage, "Offline")
    }

    func testCreateReminderReportsTheBridgesIdentifier() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: TestCredentialStore(values: ["remote-bridge-token": "TOKEN"]),
            serviceFactory: .fixed(DemoReminderService()),
            snapshotCache: .disabled,
            automaticRefreshInterval: .seconds(3_600)
        )
        await state.refresh()
        let listID = state.defaultListID ?? ""

        let outcome = await state.createReminder(title: "Fresh", listID: listID, due: nil)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(state.reminder(for: outcome.createdID ?? "")?.title, "Fresh")
    }

    func testLeavingTheRemoteRoleForgetsItsConnection() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        let credentials = TestCredentialStore(values: [:])
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: .fixed(DemoReminderService()),
            snapshotCache: .disabled,
            automaticRefreshInterval: .seconds(3_600)
        )
        try await state.saveRemoteConfiguration(endpoint: "https://example.com", clientID: "", clientSecret: "", bridgeToken: "TOKEN")
        XCTAssertEqual(credentials.value(for: "remote-bridge-token"), "TOKEN")

        state.resetMode()
        for _ in 0..<50 where !credentials.value(for: "remote-bridge-token").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(state.endpoint, "")
        XCTAssertEqual(credentials.value(for: "remote-bridge-token"), "")
        XCTAssertNil(defaults.string(forKey: AppPreferences.mode))
    }

    func testAFormerBridgeNeverAdoptsItsOwnCredentialsAsARemote() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        let provisioning = CloudflareProvisioning(
            accountID: "a", zoneID: "z", tunnelID: "t", accessApplicationID: "app",
            serviceTokenID: "s", dnsRecordID: "d", hostname: "bridge.example.com"
        )
        defaults.set(try JSONEncoder().encode(provisioning), forKey: AppPreferences.cloudflareProvisioning)
        let credentials = TestCredentialStore(values: ["bridge-token": "BRIDGE-OWN-TOKEN"])
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: .fixed(DemoReminderService()),
            snapshotCache: .disabled,
            automaticRefreshInterval: .seconds(3_600)
        )

        await state.start()

        XCTAssertEqual(state.bridgeToken, "")
        XCTAssertEqual(credentials.value(for: "bridge-token"), "BRIDGE-OWN-TOKEN")
    }

    func testUnreadableKeychainNeverReplacesTheBridgeToken() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.bridge.rawValue, forKey: AppPreferences.mode)
        let credentials = TestCredentialStore(values: ["bridge-token": "PAIRED-TOKEN"])
        credentials.readError = ReminderServiceError.message("The keychain is locked.")
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: credentials,
            serviceFactory: .fixed(DemoReminderService()),
            snapshotCache: .disabled
        )

        await state.start()

        XCTAssertEqual(state.errorMessage, "The keychain is locked.")
        XCTAssertEqual(credentials.value(for: "bridge-token"), "PAIRED-TOKEN")
        XCTAssertEqual(credentials.writeCount, 0)
    }

    func testLaunchShowsTheCachedSnapshotUntilTheFirstLiveSync() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = SnapshotCache(fileURL: folder.appending(path: "snapshot.json"))
        let cached = ReminderSnapshot(
            lists: [ReminderListRecord(id: "l", title: "Cached", colorHex: "FF0000")],
            reminders: [ReminderRecord(id: "old", listID: "l", title: "From last session")]
        )
        await cache.save(.init(endpoint: "https://example.com", savedAt: Date(timeIntervalSince1970: 1), snapshot: cached))

        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: TestCredentialStore(values: ["remote-bridge-token": "TOKEN"]),
            serviceFactory: .fixed(SwitchableService()),
            snapshotCache: cache,
            automaticRefreshInterval: .seconds(3_600)
        )

        // Available synchronously from init, so the first frame can draw it.
        XCTAssertEqual(state.snapshot, cached)
        XCTAssertTrue(state.isShowingCachedSnapshot)
        XCTAssertFalse(state.hasLoadedSnapshot)

        await state.refresh()

        XCTAssertFalse(state.isShowingCachedSnapshot)
        XCTAssertEqual(state.snapshot.lists.first?.title, "List")
        for _ in 0..<50 where cache.load(endpoint: "https://example.com")?.snapshot.lists.first?.title != "List" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(cache.load(endpoint: "https://example.com")?.snapshot.lists.first?.title, "List")
    }

    func testTodayRollsOverWhenTheDayChanges() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        let state = AppState(isDemo: false, defaults: defaults, snapshotCache: .disabled)
        let tomorrow = try XCTUnwrap(Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date()))
        state.snapshot = ReminderSnapshot(
            lists: [],
            reminders: [ReminderRecord(id: "r", listID: "l", title: "Tomorrow", due: ReminderDue(date: tomorrow, includesTime: false))]
        )
        XCTAssertEqual(state.tomorrowReminders.map(\.id), ["r"])
        var badgeCounts: [Int] = []
        state.onDockBadgeChange = { badgeCounts.append($0) }

        state.dayDidChange(now: tomorrow)

        XCTAssertEqual(state.todayReminders.map(\.id), ["r"])
        XCTAssertTrue(state.tomorrowReminders.isEmpty)
        XCTAssertFalse(badgeCounts.isEmpty)
    }
}

// MARK: - Bridge end to end

@MainActor
final class BridgeServerDeduplicationTests: XCTestCase {
    func testRetriedMutationIsAppliedOnceAndReportsTheSameIdentifier() async throws {
        let service = CountingDemoService()
        let coordinator = ReminderOperationCoordinator(service: service)
        let server = BridgeServer(operations: coordinator, token: "SECRET")
        let port = UInt16.random(in: 49_152...60_000)
        server.start(port: port)
        defer { server.stop() }
        for _ in 0..<100 where server.state != .running(port) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.state, .running(port))

        let listID = try await send(.snapshot, port: port).snapshot?.lists.first?.id
        var request = RPCRequest(operation: .upsertReminder, title: "Only once", listID: listID)
        request.requestID = "retry-me"

        let first = try await send(request, port: port)
        let second = try await send(request, port: port)

        XCTAssertEqual(service.mutationCount, 1)
        XCTAssertNotNil(first.createdID)
        XCTAssertEqual(first.createdID, second.createdID)
        XCTAssertEqual(second.protocolVersion, RPCRequest.currentProtocolVersion)
        XCTAssertEqual(second.snapshot?.reminders.filter { $0.title == "Only once" }.count, 1)
    }

    func testRejectsTheWrongToken() async throws {
        let server = BridgeServer(operations: ReminderOperationCoordinator(service: DemoReminderService()), token: "SECRET")
        let port = UInt16.random(in: 49_152...60_000)
        server.start(port: port)
        defer { server.stop() }
        for _ in 0..<100 where server.state != .running(port) {
            try await Task.sleep(for: .milliseconds(10))
        }

        let response = try await send(.snapshot, port: port, token: "WRONG")

        XCTAssertEqual(response.error, "Unauthorized.")
        XCTAssertNil(response.snapshot)
    }

    private func send(_ rpc: RPCRequest, port: UInt16, token: String = "SECRET") async throws -> RPCResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(rpc)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return try JSONDecoder().decode(RPCResponse.self, from: data)
    }
}

// MARK: - Test doubles

@MainActor
private final class SwitchableService: ReminderService {
    var failsSnapshots = false

    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if failsSnapshots {
            throw ReminderServiceError.message("Offline")
        }
        return RPCResult(snapshot: ReminderSnapshot(
            lists: [ReminderListRecord(id: "l", title: "List", colorHex: "FF0000")],
            reminders: []
        ))
    }
}

@MainActor
private final class CountingDemoService: ReminderService {
    private let demo = DemoReminderService()
    private(set) var mutationCount = 0

    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if request.operation != .snapshot {
            mutationCount += 1
        }
        return try await demo.execute(request)
    }
}

private extension ReminderServiceFactory {
    static func fixed(_ service: any ReminderService) -> ReminderServiceFactory {
        ReminderServiceFactory(
            makeBridgeService: { service },
            makeRemoteService: { _ in service },
            makeBridgeServer: { BridgeServer(operations: $0, token: $1) }
        )
    }
}

private final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var writes = 0
    private var error: (any Error)?

    init(values: [String: String]) {
        self.values = values
    }

    var readError: (any Error)? {
        get { lock.withLock { error } }
        set { lock.withLock { error = newValue } }
    }

    var writeCount: Int { lock.withLock { writes } }

    func string(for account: String) -> String {
        lock.withLock { values[account] ?? "" }
    }

    func read(_ account: String) throws -> String {
        try lock.withLock {
            if let error { throw error }
            return values[account] ?? ""
        }
    }

    func set(_ value: String, for account: String) throws {
        lock.withLock {
            writes += 1
            values[account] = value
        }
    }

    func randomToken() throws -> String { "NEW-TOKEN" }

    func value(for account: String) -> String {
        lock.withLock { values[account] ?? "" }
    }
}
