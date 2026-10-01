import Foundation
import XCTest

@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    func testPendingCredentialReadCannotRepopulateResetRole() async throws {
        let store = BlockingCredentialStore(values: ["remote-bridge-token": "OLD"], blockedRead: "remote-bridge-token")
        let (state, defaults, suite) = makeState(store: store)
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination(); store.release() }
        let read = Task { try await state.loadStoredCredentials() }
        try await waitUntil { store.isBlocked }
        state.resetMode()
        store.release()
        do {
            _ = try await read.value
            XCTFail("The old role's read must be superseded")
        } catch is CancellationError {}
        XCTAssertNil(state.mode)
        XCTAssertEqual(state.bridgeToken, "")
        try await waitUntil { store.value("remote-bridge-token").isEmpty }
    }

    func testCredentialDeletionFinishesBeforeANewConnectionIsSaved() async throws {
        let store = BlockingCredentialStore(values: ["remote-bridge-token": "OLD"], blockedWrite: "remote-access-client-id")
        let (state, defaults, suite) = makeState(store: store)
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination(); store.release() }
        state.resetMode()
        try await waitUntil { store.isBlocked }
        let save = Task {
            try await state.saveRemoteConfiguration(endpoint: "https://new.example.com", clientID: "NEW-ID",
                                                    clientSecret: "NEW-SECRET", bridgeToken: "NEW")
        }
        await Task.yield()
        store.release()
        try await save.value
        XCTAssertEqual(state.bridgeToken, "NEW")
        XCTAssertEqual(store.value("remote-bridge-token"), "NEW")
        XCTAssertEqual(store.value("remote-access-client-id"), "NEW-ID")
        XCTAssertEqual(store.value("remote-access-client-secret"), "NEW-SECRET")
    }

    func testNewSaveWinsOverAPendingCredentialRead() async throws {
        let store = BlockingCredentialStore(values: ["remote-bridge-token": "OLD"], blockedRead: "remote-bridge-token")
        let (state, defaults, suite) = makeState(store: store)
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination(); store.release() }
        let read = Task { try await state.loadStoredCredentials() }
        try await waitUntil { store.isBlocked }
        let save = Task {
            try await state.saveRemoteConfiguration(endpoint: "https://new.example.com", clientID: "ID",
                                                    clientSecret: "SECRET", bridgeToken: "NEW")
        }
        await Task.yield()
        store.release()
        _ = try? await read.value
        try await save.value
        XCTAssertEqual(state.bridgeToken, "NEW")
        let reloaded = try await state.loadStoredCredentials()
        XCTAssertEqual(reloaded.bridgeToken, "NEW")
    }

    func testEndpointChangeClearsSnapshotDraftsPreferencesAndQueuedCacheWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = SnapshotCache(fileURL: folder.appending(path: "snapshot.json"))
        let (state, defaults, suite) = makeState(store: BlockingCredentialStore(), cache: cache)
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination() }
        await state.refresh()
        XCTAssertTrue(state.hasLoadedSnapshot)
        let reminder = try XCTUnwrap(state.snapshot.reminders.first)
        let draft = ReminderEditSession(reminder, connectionRevision: state.connectionRevision)
        draft.title = "Uncommitted old connection"
        state.unsavedEdits[draft.id] = draft
        state.rememberNewReminderList(reminder.listID)
        state.navigate(to: .reminder(reminder.id))
        var resetNotifications = false
        state.onConnectionChange = { resetNotifications = true }

        try await state.saveRemoteConfiguration(endpoint: "https://new.example.com", clientID: "",
                                                clientSecret: "", bridgeToken: "NEW")
        state.setKeepsOfflineCopy(true)

        XCTAssertEqual(state.snapshot, .empty)
        XCTAssertFalse(state.hasLoadedSnapshot)
        XCTAssertFalse(state.isShowingCachedSnapshot)
        XCTAssertNil(state.lastSuccessfulSync)
        XCTAssertTrue(state.unsavedEdits.isEmpty)
        XCTAssertEqual(draft.phase, .discarded)
        XCTAssertNil(state.preferredNewReminderListID)
        XCTAssertNil(state.navigationRequest)
        XCTAssertTrue(resetNotifications)
        XCTAssertNil(cache.load(endpoint: "https://old.example.com"))
        XCTAssertNil(cache.load(endpoint: "https://new.example.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL!.path))
    }

    func testSameEndpointCredentialReplacementKeepsTheSnapshot() async throws {
        let (state, defaults, suite) = makeState(store: BlockingCredentialStore())
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination() }
        await state.refresh()
        let snapshot = state.snapshot
        let reminder = try XCTUnwrap(snapshot.reminders.first)
        let draft = ReminderEditSession(reminder, connectionRevision: state.connectionRevision)
        draft.title = "Keep this draft"
        state.unsavedEdits[draft.id] = draft
        try await state.saveRemoteConfiguration(endpoint: "https://old.example.com", clientID: "",
                                                clientSecret: "", bridgeToken: "NEW")
        XCTAssertEqual(state.snapshot, snapshot)
        XCTAssertTrue(state.hasLoadedSnapshot)
        XCTAssertNotNil(state.unsavedEdits[draft.id])
        let saved = await state.saveEdit(draft, undoManager: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(state.reminder(for: reminder.id)?.title, "Keep this draft")
    }

    func testDepartingEditorCannotReintroduceAnOldConnectionDraft() async throws {
        let (state, defaults, suite) = makeState(store: BlockingCredentialStore())
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination() }
        await state.refresh()
        let reminder = try XCTUnwrap(state.snapshot.reminders.first)
        let draft = ReminderEditSession(reminder, connectionRevision: state.connectionRevision)
        draft.title = "Old editor"
        try await state.saveRemoteConfiguration(endpoint: "https://new.example.com", clientID: "",
                                                clientSecret: "", bridgeToken: "NEW")
        let saved = await state.saveEdit(draft, undoManager: nil)
        XCTAssertFalse(saved)
        XCTAssertEqual(draft.phase, .discarded)
        XCTAssertTrue(state.unsavedEdits.isEmpty)
    }

    func testResetReportsCredentialDeletionFailure() async throws {
        let store = BlockingCredentialStore()
        store.failsWrites = true
        let (state, defaults, suite) = makeState(store: store)
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination() }
        state.resetMode()
        try await waitUntil { state.errorMessage != nil }
        XCTAssertTrue(state.errorMessage?.contains("Could not forget") == true)
        XCTAssertTrue(state.errorNeedsSettings)
    }

    func testRoleSwitchLoadsBridgeCredentialsWhileAnOldRemoteReadIsPending() async throws {
        let store = BlockingCredentialStore(values: ["remote-bridge-token": "REMOTE", "bridge-token": "BRIDGE"],
                                             blockedRead: "remote-bridge-token")
        defer { store.release() }
        let credentials = CredentialManager(store: store)
        let remoteRead = Task { try await credentials.load(for: .remote, mayMigrateLegacy: false) }
        try await waitUntil { store.isBlocked }
        _ = credentials.reset(clearRemote: false)
        let bridgeRead = Task { try await credentials.load(for: .bridge, mayMigrateLegacy: false) }
        store.release()
        _ = try? await remoteRead.value
        let bridge = try await bridgeRead.value
        XCTAssertEqual(bridge.bridgeToken, "BRIDGE")
        XCTAssertEqual(credentials.cached.bridgeToken, "BRIDGE")
    }

    func testOldRefreshResponseCannotRepopulateAReplacementConnection() async throws {
        let suite = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://old.example.com", forKey: AppPreferences.endpoint)
        let oldService = SuspendedReminderService()
        let newService = DemoReminderService(scenario: .empty)
        let state = AppState(isDemo: false, defaults: defaults, credentialStore: BlockingCredentialStore(),
            serviceFactory: .init(makeBridgeService: { newService },
                makeRemoteService: {
                    if $0.endpoint.host == "old.example.com" { return oldService }
                    return newService
                },
                makeBridgeServer: { BridgeServer(operations: $0, token: $1) }),
            snapshotCache: .disabled, automaticRefreshInterval: .seconds(3600))
        defer { defaults.removePersistentDomain(forName: suite); state.prepareForTermination(); oldService.release() }
        await state.refresh()
        oldService.pauseNextRequest = true
        let oldRefresh = Task { await state.refresh() }
        try await waitUntil { oldService.isPaused }
        try await state.saveRemoteConfiguration(endpoint: "https://new.example.com", clientID: "",
                                                clientSecret: "", bridgeToken: "NEW")
        oldService.release()
        let oldSucceeded = await oldRefresh.value
        XCTAssertFalse(oldSucceeded)
        XCTAssertEqual(state.snapshot, .empty)
        XCTAssertFalse(state.hasLoadedSnapshot)
        let newSucceeded = await state.refresh()
        XCTAssertTrue(newSucceeded)
        XCTAssertTrue(state.snapshot.reminders.isEmpty)
        XCTAssertTrue(state.hasLoadedSnapshot)
    }

    private func makeState(store: BlockingCredentialStore, cache: SnapshotCache = .disabled) -> (AppState, UserDefaults, String) {
        let suite = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://old.example.com", forKey: AppPreferences.endpoint)
        let service = DemoReminderService()
        let state = AppState(isDemo: false, defaults: defaults, credentialStore: store,
            serviceFactory: .init(makeBridgeService: { service }, makeRemoteService: { _ in service },
                                  makeBridgeServer: { BridgeServer(operations: $0, token: $1) }),
            snapshotCache: cache, automaticRefreshInterval: .seconds(3600))
        return (state, defaults, suite)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The operation did not reach its expected state")
        throw CancellationError()
    }
}

@MainActor
private final class SuspendedReminderService: ReminderService {
    private let service = DemoReminderService()
    private var continuation: CheckedContinuation<Void, Never>?
    var pauseNextRequest = false
    var isPaused: Bool { continuation != nil }
    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if pauseNextRequest {
            pauseNextRequest = false
            await withCheckedContinuation { continuation = $0 }
        }
        return try await service.execute(request)
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class BlockingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var values: [String: String]
    private let blockedRead: String?
    private let blockedWrite: String?
    private var didBlock = false
    private var blocked = false
    var failsWrites = false
    var isBlocked: Bool { lock.withLock { blocked } }

    init(values: [String: String] = ["remote-bridge-token": "OLD"], blockedRead: String? = nil, blockedWrite: String? = nil) {
        self.values = values
        self.blockedRead = blockedRead
        self.blockedWrite = blockedWrite
    }
    func value(_ account: String) -> String { lock.withLock { values[account] ?? "" } }
    func string(for account: String) -> String { value(account) }
    func read(_ account: String) throws -> String {
        let result = value(account)
        blockOnce(if: blockedRead == account)
        return result
    }
    func set(_ value: String, for account: String) throws {
        blockOnce(if: blockedWrite == account)
        if failsWrites { throw ReminderServiceError.message("Expected deletion failure") }
        lock.withLock { values[account] = value }
    }
    func randomToken() throws -> String { "FAKE-TOKEN" }
    func release() { gate.signal() }
    private func blockOnce(if shouldBlock: Bool) {
        let wait = lock.withLock {
            guard shouldBlock, !didBlock else { return false }
            didBlock = true
            blocked = true
            return true
        }
        if wait { gate.wait() }
    }
}
