import Foundation

@MainActor
enum ReminderUndo {
    /// UndoManager retains its handlers. Keep the manager weak and access it only on the main
    /// actor, including on SDKs where UndoManager does not conform to Sendable.
    @MainActor
    private final class ManagerReference {
        weak var value: UndoManager?

        init(_ value: UndoManager) {
            self.value = value
        }
    }

    /// Registers undo (and, from there, redo) for completing or uncompleting reminders.
    static func registerCompletion(_ ids: [String], completed: Bool, state: AppState, undoManager: UndoManager?) {
        guard let undoManager, !ids.isEmpty else { return }
        let manager = ManagerReference(undoManager)
        undoManager.registerUndo(withTarget: state) { state in
            MainActor.assumeIsolated {
                registerCompletion(ids, completed: !completed, state: state, undoManager: manager.value)
                Task {
                    for id in ids {
                        await state.setCompleted(reminderID: id, !completed)
                    }
                }
            }
        }
        undoManager.setActionName(completed
            ? String(localized: "Mark as Completed")
            : String(localized: "Mark as Incomplete"))
    }

    /// Registers undo for an edit by restoring each reminder's earlier title, notes, list, and due date.
    static func registerEdit(
        restoring previous: [ReminderRecord],
        redoing next: [ReminderRecord],
        name: String,
        state: AppState,
        undoManager: UndoManager?
    ) {
        guard let undoManager, !previous.isEmpty else { return }
        let manager = ManagerReference(undoManager)
        undoManager.registerUndo(withTarget: state) { state in
            MainActor.assumeIsolated {
                registerEdit(restoring: next, redoing: previous, name: name, state: state, undoManager: manager.value)
                Task {
                    for record in previous {
                        let current = state.reminder(for: record.id) ?? record
                        await state.updateReminder(
                            current,
                            title: record.title,
                            listID: record.listID,
                            due: record.due,
                            notes: record.notes ?? ""
                        )
                    }
                }
            }
        }
        undoManager.setActionName(name)
    }
}
