import Foundation
import XCTest

@MainActor
final class ReminderBatchTests: XCTestCase {
    func testPartialMoveKeepsUndoAndRedoForOnlySuccessfulItems() async throws {
        let (state, service, defaults, suite) = await makeState()
        defer { state.prepareForTermination(); defaults.removePersistentDomain(forName: suite) }
        let records = Array(state.snapshot.reminders.filter { $0.listID == state.snapshot.reminders.first?.listID }.prefix(2))
        let destination = try XCTUnwrap(state.snapshot.lists.first { $0.id != records[0].listID }).id
        service.failOnceIDs = [records[0].id]
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let outcome = await state.moveReporting(records, toList: destination, undoManager: manager)
        manager.endUndoGrouping()

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.failedIDs, [records[0].id])
        XCTAssertEqual(outcome.changes.map { $0.before.id }, [records[1].id])
        XCTAssertEqual(state.reminder(for: records[0].id), records[0])
        XCTAssertEqual(state.reminder(for: records[1].id)?.listID, destination)
        XCTAssertEqual(state.errorMessage, "Expected item failure")
        XCTAssertTrue(manager.canUndo)
        service.mutatedIDs.removeAll()
        manager.undo()
        try await waitUntil { state.reminder(for: records[1].id) == records[1] }
        XCTAssertEqual(service.mutatedIDs, [records[1].id])
        manager.redo()
        try await waitUntil { state.reminder(for: records[1].id)?.listID == destination }
        XCTAssertEqual(service.mutatedIDs, [records[1].id, records[1].id])
    }

    func testPartialRescheduleKeepsUndoAndTimedComponents() async throws {
        let (state, service, defaults, suite) = await makeState()
        defer { state.prepareForTermination(); defaults.removePersistentDomain(forName: suite) }
        let records = Array(state.snapshot.reminders.prefix(2))
        var timed = records[1]
        timed.due = ReminderDue(year: 2026, month: 1, day: 1, hour: 14, minute: 25,
                                timeZoneIdentifier: "America/New_York")
        let edited = await state.updateReminder(records[1], title: timed.title, listID: timed.listID, due: timed.due)
        XCTAssertTrue(edited)
        service.failOnceIDs = [records[0].id]
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let outcome = await state.rescheduleReporting([records[0], timed], to: .tomorrow, undoManager: manager)
        manager.endUndoGrouping()
        XCTAssertEqual(outcome.failedIDs, [records[0].id])
        XCTAssertEqual(outcome.changes.count, 1)
        let due = try XCTUnwrap(state.reminder(for: timed.id)?.due)
        XCTAssertEqual(due.hour, 14)
        XCTAssertEqual(due.minute, 25)
        XCTAssertEqual(due.timeZoneIdentifier, "America/New_York")
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        try await waitUntil { state.reminder(for: timed.id) == timed }
    }

    func testEntirelyFailedBatchDoesNotRegisterUndo() async throws {
        let (state, service, defaults, suite) = await makeState()
        defer { state.prepareForTermination(); defaults.removePersistentDomain(forName: suite) }
        let records = Array(state.snapshot.reminders.prefix(2))
        service.failOnceIDs = Set(records.map(\.id))
        let manager = UndoManager()
        manager.groupsByEvent = false
        let outcome = await state.rescheduleReporting(records, to: .tomorrow, undoManager: manager)
        XCTAssertEqual(Set(outcome.failedIDs), Set(records.map(\.id)))
        XCTAssertTrue(outcome.changes.isEmpty)
        XCTAssertFalse(manager.canUndo)
    }

    func testNoOpAndDuplicateItemsDoNotCreateExtraUndoChanges() async throws {
        let (state, service, defaults, suite) = await makeState()
        defer { state.prepareForTermination(); defaults.removePersistentDomain(forName: suite) }
        let record = try XCTUnwrap(state.snapshot.reminders.first)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let outcome = await state.moveReporting([record, record], toList: record.listID, undoManager: manager)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.changes.isEmpty)
        XCTAssertTrue(service.mutatedIDs.isEmpty)
        XCTAssertFalse(manager.canUndo)
    }

    func testUndoFromPreviousConnectionDoesNotMutateTheNewBridge() async throws {
        let (state, service, defaults, suite) = await makeState()
        defer { state.prepareForTermination(); defaults.removePersistentDomain(forName: suite) }
        let record = try XCTUnwrap(state.snapshot.reminders.first)
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        ReminderUndo.registerCompletion([record.id], completed: true, state: state, undoManager: manager)
        manager.endUndoGrouping()
        try await state.saveRemoteConfiguration(endpoint: "https://other.example.com", clientID: "",
                                                clientSecret: "", bridgeToken: "TOKEN")
        service.mutatedIDs.removeAll()
        manager.undo()
        await Task.yield()
        XCTAssertTrue(service.mutatedIDs.isEmpty)
        XCTAssertFalse(manager.canRedo)
    }

    private func makeState() async -> (AppState, BatchService, UserDefaults, String) {
        let suite = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let service = BatchService()
        let state = AppState(isDemo: false, defaults: defaults, credentialStore: BatchCredentials(),
            serviceFactory: .init(makeBridgeService: { service }, makeRemoteService: { _ in service },
                                  makeBridgeServer: { BridgeServer(operations: $0, token: $1) }),
            snapshotCache: .disabled, automaticRefreshInterval: .seconds(3600))
        await state.refresh()
        return (state, service, defaults, suite)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Undo or Redo did not finish")
    }
}

@MainActor
private final class BatchService: ReminderService {
    private let service = DemoReminderService()
    var failOnceIDs: Set<String> = []
    var mutatedIDs: [String] = []
    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if request.operation != .snapshot, let id = request.id {
            if failOnceIDs.remove(id) != nil { throw ReminderServiceError.message("Expected item failure") }
            mutatedIDs.append(id)
        }
        return try await service.execute(request)
    }
}

private struct BatchCredentials: CredentialStore {
    func string(for account: String) -> String { account == "remote-bridge-token" ? "TOKEN" : "" }
    func set(_ value: String, for account: String) throws {}
    func randomToken() throws -> String { "TOKEN" }
}
