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
        manager?.endUndoGrouping()

        manager = nil

        XCTAssertNil(managerReference)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The undo or redo mutation did not finish.")
    }
}
