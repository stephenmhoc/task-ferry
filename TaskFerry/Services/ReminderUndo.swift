import Foundation

/// Undo and redo for reminder changes.
///
/// UndoManager wants an action's reverse registered while it's undoing or redoing, but the work
/// only finishes once the bridge answers. So each step registers its reverse straight away, and
/// that reverse waits for the step's results before it does anything. A step the bridge doesn't
/// take goes back on the undo stack, so it isn't spent.
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

    /// Set once a registered step has been chosen from the Undo or Redo menu.
    @MainActor
    private final class Invocation {
        var happened = false
    }

    /// One undoable change. Running it returns the change that reverses it, or nil when the
    /// bridge took none of it.
    private struct Step: Sendable {
        let name: String
        let run: @MainActor @Sendable (AppState) async -> Step?
    }

    // MARK: - Registering

    /// Registers undo (and, from there, redo) for completing or uncompleting reminders.
    static func registerCompletion(_ ids: [String], completed: Bool, state: AppState, undoManager: UndoManager?) {
        guard let undoManager, !ids.isEmpty else { return }
        let name = completed ? String(localized: "Mark as Completed") : String(localized: "Mark as Incomplete")
        register(setCompleted(ids, to: !completed, name: name), state: state,
                 manager: ManagerReference(undoManager), revision: state.connectionRevision)
    }

    /// Registers undo for deleting reminders. Undo creates them again from the captured records,
    /// with their title, notes, URL, list, and due date, so they come back with new identifiers.
    static func registerDeletion(_ records: [ReminderRecord], state: AppState, undoManager: UndoManager?) {
        guard let undoManager, !records.isEmpty else { return }
        let name = records.count == 1 ? String(localized: "Delete Reminder") : String(localized: "Delete Reminders")
        register(recreation(records, name: name), state: state,
                 manager: ManagerReference(undoManager), revision: state.connectionRevision)
    }

    /// Registers undo for creating reminders, which deletes them by identifier.
    static func registerCreation(_ ids: [String], state: AppState, undoManager: UndoManager?) {
        guard let undoManager, !ids.isEmpty else { return }
        let name = ids.count == 1 ? String(localized: "New Reminder") : String(localized: "New Reminders")
        register(removal(ids, name: name), state: state,
                 manager: ManagerReference(undoManager), revision: state.connectionRevision)
    }

    /// Registers undo for an edit by restoring each reminder's earlier title, notes, list, and due
    /// date. `next` is what redo puts back if a reminder isn't listed when undo runs.
    static func registerEdit(
        restoring previous: [ReminderRecord],
        redoing next: [ReminderRecord],
        name: String,
        state: AppState,
        undoManager: UndoManager?
    ) {
        guard let undoManager, !previous.isEmpty else { return }
        register(edit(restoring: previous, fallback: next, name: name), state: state,
                 manager: ManagerReference(undoManager), revision: state.connectionRevision)
    }

    private static func register(_ step: Step, state: AppState, manager: ManagerReference, revision: Int,
                                 invocation: Invocation? = nil) {
        guard let undoManager = manager.value else { return }
        undoManager.registerUndo(withTarget: state) { state in
            MainActor.assumeIsolated {
                invocation?.happened = true
                guard state.connectionRevision == revision else { return }
                perform(step, state: state, manager: manager, revision: revision)
            }
        }
        undoManager.setActionName(step.name)
    }

    /// Runs a step chosen from Undo or Redo, and registers its reverse on the other stack.
    private static func perform(_ step: Step, state: AppState, manager: ManagerReference, revision: Int) {
        let work = Task { await step.run(state) }
        let reverseChosen = Invocation()
        let reverse = Step(name: step.name) { state in
            // When the step failed, nothing changed: undoing again means trying the step again.
            guard let inverse = await work.value else { return step }
            return await inverse.run(state)
        }
        register(reverse, state: state, manager: manager, revision: revision, invocation: reverseChosen)
        Task {
            guard await work.value == nil, !reverseChosen.happened, state.connectionRevision == revision,
                  let undoManager = manager.value else { return }
            // The bridge didn't take it, so put it back. Registering outside of undo or redo also
            // clears the redo stack, which held this step's reverse.
            let opensGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
            if opensGroup { undoManager.beginUndoGrouping() }
            register(step, state: state, manager: manager, revision: revision)
            if opensGroup { undoManager.endUndoGrouping() }
        }
    }

    // MARK: - Steps

    /// A step fails only when the bridge turned all of it down. Reminders that are already gone
    /// leave nothing to do, which isn't a failure.
    private static func outcome(_ reverse: Step, succeeded: Bool, failed: Bool) -> Step? {
        failed && !succeeded ? nil : reverse
    }

    private static func setCompleted(_ ids: [String], to completed: Bool, name: String) -> Step {
        Step(name: name) { state in
            var changed: [String] = []
            for id in ids {
                let id = state.currentReminderID(for: id)
                if await state.setCompleted(reminderID: id, completed) { changed.append(id) }
            }
            return outcome(setCompleted(changed, to: !completed, name: name),
                           succeeded: !changed.isEmpty, failed: changed.count < ids.count)
        }
    }

    private static func recreation(_ records: [ReminderRecord], name: String) -> Step {
        Step(name: name) { state in
            var created: [String] = []
            var failed = false
            var succeeded = false
            for record in records {
                // Due dates go back as the same calendar components they were captured as.
                let result = await state.createReminder(title: record.title, listID: record.listID, due: record.due,
                                                        notes: record.notes, url: record.url)
                guard result.succeeded else {
                    failed = true
                    continue
                }
                succeeded = true
                if let id = result.createdID {
                    state.noteRecreatedReminder(record.id, as: id)
                    created.append(id)
                }
            }
            return outcome(removal(created, name: name), succeeded: succeeded, failed: failed)
        }
    }

    private static func removal(_ ids: [String], name: String) -> Step {
        Step(name: name) { state in
            var removed: [ReminderRecord] = []
            var failed = false
            for id in ids {
                guard let record = state.reminder(for: state.currentReminderID(for: id)) else { continue }
                if await state.deleteReminder(record) {
                    removed.append(record)
                } else {
                    failed = true
                }
            }
            return outcome(recreation(removed, name: name), succeeded: !removed.isEmpty, failed: failed)
        }
    }

    private static func edit(restoring previous: [ReminderRecord], fallback next: [ReminderRecord], name: String) -> Step {
        Step(name: name) { state in
            var restored: [ReminderRecord] = []
            var replaced: [ReminderRecord] = []
            var failed = false
            for (index, record) in previous.enumerated() {
                let id = state.currentReminderID(for: record.id)
                var current = state.reminder(for: id) ?? (index < next.count ? next[index] : record)
                current.id = id
                let succeeded = await state.updateReminder(current, title: record.title, listID: record.listID,
                                                           due: record.due, notes: record.notes ?? "")
                guard succeeded else {
                    failed = true
                    continue
                }
                var restoredRecord = record
                restoredRecord.id = id
                restored.append(restoredRecord)
                replaced.append(current)
            }
            return outcome(edit(restoring: replaced, fallback: restored, name: name),
                           succeeded: !restored.isEmpty, failed: failed)
        }
    }
}
