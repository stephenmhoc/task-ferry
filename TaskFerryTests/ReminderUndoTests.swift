import Foundation
import XCTest

@MainActor
final class ReminderUndoTests: XCTestCase {
    private weak var managerReference: UndoManager?

    func testCompletionCanBeUndoneAndRedone() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let reminder = try XCTUnwrap(state.snapshot.reminders.first)
        let manager = UndoManager()
        manager.groupsByEvent = false

        let completed = await state.setCompleted(reminderID: reminder.id, true)
        XCTAssertTrue(completed)
        manager.beginUndoGrouping()
        ReminderUndo.registerCompletion([reminder.id], completed: true, state: state, undoManager: manager)
        manager.endUndoGrouping()

        manager.undo()
        try await waitUntil { state.reminder(for: reminder.id) != nil }
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        try await waitUntil { state.reminder(for: reminder.id) == nil }
        XCTAssertTrue(manager.canUndo)
    }

    func testEditUndoAndRedoRestoreAllFields() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let before = try XCTUnwrap(state.snapshot.reminders.first)
        var after = before
        after.title = "Changed title"
        after.notes = "Changed notes"
        after.listID = try XCTUnwrap(state.snapshot.lists.first { $0.id != before.listID }).id
        after.due = ReminderDue(year: 2027, month: 1, day: 2)
        let edited = await state.updateReminder(
            before, title: after.title, listID: after.listID, due: after.due, notes: after.notes ?? ""
        )
        XCTAssertTrue(edited)
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        ReminderUndo.registerEdit(restoring: [before], redoing: [after], name: "Edit", state: state, undoManager: manager)
        manager.endUndoGrouping()

        manager.undo()
        try await waitUntil { state.reminder(for: before.id) == before }
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        try await waitUntil { state.reminder(for: after.id) == after }
        XCTAssertTrue(manager.canUndo)
    }

    func testDeletionUndoRecreatesTheReminderAndRedoDeletesItAgain() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        var reminder = try XCTUnwrap(state.snapshot.reminders.first { $0.url == nil })
        reminder.due = ReminderDue(year: 2027, month: 3, day: 4)
        let edited = await state.updateReminder(reminder, title: reminder.title, listID: reminder.listID,
                                                due: reminder.due, notes: "Kept notes")
        XCTAssertTrue(edited)
        let record = try XCTUnwrap(state.reminder(for: reminder.id))
        let manager = UndoManager()
        manager.groupsByEvent = false

        let deleted = await state.deleteReminder(record)
        XCTAssertTrue(deleted)
        manager.beginUndoGrouping()
        ReminderUndo.registerDeletion([record], state: state, undoManager: manager)
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoActionName, "Delete Reminder")

        manager.undo()
        try await waitUntil { state.snapshot.reminders.contains { $0.title == record.title } }
        let restored = try XCTUnwrap(state.snapshot.reminders.first { $0.title == record.title })
        XCTAssertEqual(restored.notes, "Kept notes")
        XCTAssertEqual(restored.due, record.due)
        XCTAssertEqual(restored.listID, record.listID)
        XCTAssertEqual(manager.redoActionName, "Delete Reminder")

        manager.redo()
        try await waitUntil { state.reminder(for: restored.id) == nil }
        XCTAssertTrue(manager.canUndo)
    }

    func testCreationUndoDeletesTheReminder() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let listID = try XCTUnwrap(state.snapshot.lists.first).id
        let outcome = await state.createReminder(title: "Undo me", listID: listID, due: nil)
        let id = try XCTUnwrap(outcome.createdID)
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        ReminderUndo.registerCreation([id], state: state, undoManager: manager)
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoActionName, "New Reminder")

        manager.undo()
        try await waitUntil { state.reminder(for: id) == nil }
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        try await waitUntil { state.snapshot.reminders.contains { $0.title == "Undo me" } }
    }

    func testDeletionUndoIsIgnoredAfterTheConnectionChanges() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let record = try XCTUnwrap(state.snapshot.reminders.first)
        let manager = UndoManager()
        manager.groupsByEvent = false
        _ = await state.deleteReminder(record)
        manager.beginUndoGrouping()
        ReminderUndo.registerDeletion([record], state: state, undoManager: manager)
        manager.endUndoGrouping()
        let revision = state.connectionRevision

        try await state.saveRemoteConfiguration(endpoint: "https://other.example.com", clientID: "",
                                                clientSecret: "", bridgeToken: "OTHER")
        XCTAssertNotEqual(state.connectionRevision, revision)
        await state.refresh()
        let count = state.snapshot.reminders.count
        manager.undo()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.snapshot.reminders.count, count)
        XCTAssertFalse(manager.canRedo, "a stale undo must not register a redo")
    }

    func testUndoHandlersDoNotRetainTheirManager() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let reminder = try XCTUnwrap(state.snapshot.reminders.first)
        var manager: UndoManager? = UndoManager()
        managerReference = manager
        manager?.groupsByEvent = false
        manager?.beginUndoGrouping()
        ReminderUndo.registerCompletion([reminder.id], completed: true, state: state, undoManager: manager)
        ReminderUndo.registerEdit(restoring: [reminder], redoing: [reminder], name: "Edit", state: state, undoManager: manager)
        ReminderUndo.registerDeletion([reminder], state: state, undoManager: manager)
        ReminderUndo.registerCreation([reminder.id], state: state, undoManager: manager)
        manager?.endUndoGrouping()

        manager = nil

        XCTAssertNil(managerReference)
    }

    func testUndoFollowsAReminderThatUndoCreatedAgain() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let before = try XCTUnwrap(state.snapshot.reminders.first)
        let manager = UndoManager()
        manager.groupsByEvent = false

        _ = await state.updateReminder(before, title: "Renamed", listID: before.listID, due: before.due,
                                       notes: before.notes ?? "")
        let renamed = try XCTUnwrap(state.reminder(for: before.id))
        manager.beginUndoGrouping()
        ReminderUndo.registerEdit(restoring: [before], redoing: [renamed], name: "Edit", state: state, undoManager: manager)
        manager.endUndoGrouping()
        _ = await state.deleteReminder(renamed)
        manager.beginUndoGrouping()
        ReminderUndo.registerDeletion([renamed], state: state, undoManager: manager)
        manager.endUndoGrouping()

        manager.undo()
        try await waitUntil { state.snapshot.reminders.contains { $0.title == "Renamed" } }
        let restored = try XCTUnwrap(state.snapshot.reminders.first { $0.title == "Renamed" })
        XCTAssertNotEqual(restored.id, before.id)

        manager.undo()
        try await waitUntil { state.reminder(for: restored.id)?.title == before.title }
    }

    func testAnUndoTheBridgeTurnsDownCanBeTriedAgain() async throws {
        let (state, service, cleanup) = try await makeFlakyState()
        defer { cleanup() }
        let record = try XCTUnwrap(state.snapshot.reminders.first)
        let manager = UndoManager()
        manager.groupsByEvent = false
        _ = await state.deleteReminder(record)
        manager.beginUndoGrouping()
        ReminderUndo.registerDeletion([record], state: state, undoManager: manager)
        manager.endUndoGrouping()

        service.failsMutations = true
        manager.undo()
        try await waitUntil { manager.canUndo && !manager.canRedo }
        XCTAssertFalse(state.snapshot.reminders.contains { $0.title == record.title })
        XCTAssertEqual(manager.undoActionName, "Delete Reminder")

        service.failsMutations = false
        manager.undo()
        try await waitUntil { state.snapshot.reminders.contains { $0.title == record.title } }
        XCTAssertTrue(manager.canRedo)
    }

    func testRedoRightAfterUndoWaitsForTheUndo() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let record = try XCTUnwrap(state.snapshot.reminders.first)
        let manager = UndoManager()
        manager.groupsByEvent = false
        _ = await state.deleteReminder(record)
        manager.beginUndoGrouping()
        ReminderUndo.registerDeletion([record], state: state, undoManager: manager)
        manager.endUndoGrouping()

        manager.undo()
        manager.redo()
        try await waitUntil { manager.canUndo && !manager.canRedo }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.snapshot.reminders.contains { $0.title == record.title },
                       "redo deletes the reminder that undo brought back")

        manager.undo()
        try await waitUntil { state.snapshot.reminders.contains { $0.title == record.title } }
    }

    func testDeletingSeveralRemindersIsOneNamedStep() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let records = Array(state.snapshot.reminders.prefix(2))
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        ReminderUndo.registerDeletion(records, state: state, undoManager: manager)
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoActionName, "Delete Reminders")
    }

    private func makeFlakyState() async throws -> (AppState, FlakyService, () -> Void) {
        let suiteName = "TaskFerryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(AppMode.remote.rawValue, forKey: AppPreferences.mode)
        defaults.set("https://example.com", forKey: AppPreferences.endpoint)
        let service = FlakyService()
        let state = AppState(
            isDemo: false,
            defaults: defaults,
            credentialStore: UndoTestCredentials(),
            serviceFactory: ReminderServiceFactory(
                makeBridgeService: { service },
                makeRemoteService: { _ in service },
                makeBridgeServer: { BridgeServer(operations: $0, token: $1) }
            ),
            snapshotCache: .disabled,
            automaticRefreshInterval: .seconds(3_600)
        )
        let synced = await state.refresh()
        XCTAssertTrue(synced)
        return (state, service, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The undo or redo mutation did not finish.")
    }
}

/// The demo bridge, but it can be told to turn down every change, as an unreachable bridge would.
@MainActor
private final class FlakyService: ReminderService {
    private let demo = DemoReminderService()
    var failsMutations = false

    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if failsMutations, request.operation != .snapshot {
            throw ReminderServiceError.message("Offline")
        }
        return try await demo.execute(request)
    }
}

private struct UndoTestCredentials: CredentialStore {
    func string(for account: String) -> String { account == "remote-bridge-token" ? "TOKEN" : "" }
    func set(_ value: String, for account: String) throws {}
    func randomToken() throws -> String { "TOKEN" }
}
