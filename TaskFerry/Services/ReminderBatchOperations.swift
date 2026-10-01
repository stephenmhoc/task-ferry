import Foundation

struct ReminderBatchOutcome {
    struct Change {
        let before: ReminderRecord
        let after: ReminderRecord
    }
    var changes: [Change] = []
    var failedIDs: [String] = []
    var succeeded: Bool { failedIDs.isEmpty }
}

@MainActor
extension AppState {
    @discardableResult
    func move(_ reminders: [ReminderRecord], toList listID: String) async -> Bool {
        await moveReporting(reminders, toList: listID).succeeded
    }

    /// Each successful item gets Undo even when another item in the batch fails.
    func moveReporting(_ reminders: [ReminderRecord], toList listID: String,
                       undoManager: UndoManager? = nil) async -> ReminderBatchOutcome {
        await changeReminders(reminders, name: String(localized: "Move to List"), undoManager: undoManager) { reminder in
            var updated = reminder
            updated.listID = listID
            return updated
        }
    }

    @discardableResult
    func reschedule(_ reminders: [ReminderRecord], to option: QuickDueOption) async -> Bool {
        await rescheduleReporting(reminders, to: option).succeeded
    }

    func rescheduleReporting(_ reminders: [ReminderRecord], to option: QuickDueOption,
                             undoManager: UndoManager? = nil) async -> ReminderBatchOutcome {
        // One batch uses one day, even if it crosses midnight while waiting for the bridge.
        let newDue = option.due()
        return await changeReminders(reminders, name: String(localized: "Change Due Date"), undoManager: undoManager) { reminder in
            var updated = reminder
            updated.due = newDue
            if var due = newDue, let old = reminder.due, old.hasTime {
                due.hour = old.hour
                due.minute = old.minute
                due.timeZoneIdentifier = old.timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier
                updated.due = due
            }
            return updated
        }
    }

    private func changeReminders(_ reminders: [ReminderRecord], name: String, undoManager: UndoManager?,
                                 transform: (ReminderRecord) -> ReminderRecord) async -> ReminderBatchOutcome {
        let revision = connectionRevision
        var outcome = ReminderBatchOutcome()
        var firstFailure: String?
        var visited: Set<String> = []
        for record in reminders where visited.insert(record.id).inserted {
            guard revision == connectionRevision else {
                outcome.failedIDs.append(record.id)
                continue
            }
            guard let before = reminder(for: record.id) else {
                outcome.failedIDs.append(record.id)
                firstFailure = firstFailure ?? String(localized: "A reminder was removed elsewhere. Refresh and try again.")
                continue
            }
            let after = transform(before)
            guard before != after else { continue }
            if await updateReminder(before, title: after.title, listID: after.listID,
                                    due: after.due), revision == connectionRevision {
                outcome.changes.append(.init(before: before, after: reminder(for: before.id) ?? after))
            } else {
                outcome.failedIDs.append(record.id)
                firstFailure = firstFailure ?? errorMessage ?? String(localized: "Couldn’t save this change. Try again.")
            }
        }
        guard revision == connectionRevision else { return outcome }
        ReminderUndo.registerEdit(restoring: outcome.changes.map(\.before), redoing: outcome.changes.map(\.after),
                                  name: name, state: self, undoManager: undoManager)
        // A later success must not erase an earlier item's error.
        if let firstFailure { reportMutationFailure(firstFailure) }
        return outcome
    }
}
