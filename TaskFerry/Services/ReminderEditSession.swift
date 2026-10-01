import Foundation
import Observation

/// A reference-backed draft has an explicit lifetime independent of SwiftUI row reuse.
@MainActor
@Observable
final class ReminderEditSession: Identifiable {
    enum Phase { case editing, saving, saved, discarded, failed }

    let id = UUID()
    let original: ReminderRecord
    let connectionRevision: Int?
    var title: String
    var notes: String
    var listID: String
    var hasDue: Bool
    var dueDate: Date
    var includesTime: Bool
    private(set) var phase = Phase.editing
    private(set) var error: String?
    @ObservationIgnored private var saveTask: Task<Bool, Never>?

    init(_ reminder: ReminderRecord, connectionRevision: Int? = nil) {
        original = reminder
        self.connectionRevision = connectionRevision
        title = reminder.title
        notes = reminder.notes ?? ""
        listID = reminder.listID
        hasDue = reminder.due != nil
        dueDate = reminder.due?.date() ?? Date()
        includesTime = reminder.due?.hasTime ?? false
    }

    var updated: ReminderRecord {
        let initial = original.due
        let untouched = hasDue == (initial != nil)
            && includesTime == (initial?.hasTime ?? false)
            && (initial == nil || dueDate == initial?.date())
        let due = untouched ? initial : (hasDue ? ReminderDue(date: dueDate, includesTime: includesTime) : nil)
        return ReminderRecord(id: original.id, listID: listID, title: title.trimmed,
                              notes: notes.trimmed.isEmpty ? nil : notes, due: due)
    }

    func discard() {
        guard phase != .saving else { return }
        phase = .discarded
        error = nil
    }

    /// Coalesces Return, disappearance and completion into one mutation. A failure is retryable.
    func commit(_ save: @escaping @MainActor (ReminderRecord) async -> String?) async -> Bool {
        if let saveTask { return await saveTask.value }
        if phase == .saved { return true }
        if phase == .discarded { return false }
        let value = updated
        guard !value.title.isEmpty, !value.listID.isEmpty else {
            error = String(localized: "A reminder needs a title and a list.")
            phase = .failed
            return false
        }
        guard value != original else {
            phase = .saved
            return true
        }
        phase = .saving
        error = nil
        let task = Task { @MainActor in
            if let message = await save(value) {
                self.error = message
                self.phase = .failed
                return false
            }
            self.phase = .saved
            return true
        }
        saveTask = task
        let succeeded = await task.value
        saveTask = nil
        return succeeded
    }
}

extension AppState {
    func saveEditWhenLeaving(_ session: ReminderEditSession, undoManager: UndoManager?) {
        guard mode == .remote, session.phase == .editing || session.phase == .saving else { return }
        // Retain synchronously so immediately reopening the row joins this same draft/save.
        unsavedEdits[session.id] = session
        Task { await saveEdit(session, undoManager: undoManager) }
    }

    /// Retains in-flight and failed drafts even after their window closes. No drafts go on disk.
    @discardableResult
    func saveEdit(_ session: ReminderEditSession, undoManager: UndoManager?) async -> Bool {
        guard session.phase != .discarded else { return false }
        if let revision = session.connectionRevision, revision != connectionRevision {
            discardEdit(session)
            return false
        }
        unsavedEdits[session.id] = session
        let succeeded = await session.commit { [self] updated in
            guard reminder(for: updated.id) != nil else {
                return String(localized: "This reminder was removed elsewhere. Copy your draft before discarding it.")
            }
            guard await updateReminder(session.original, title: updated.title, listID: updated.listID,
                                       due: updated.due, notes: updated.notes ?? "") else {
                return errorMessage ?? String(localized: "Couldn’t save this edit. Try again.")
            }
            ReminderUndo.registerEdit(restoring: [session.original], redoing: [updated],
                                      name: String(localized: "Edit Reminder"), state: self, undoManager: undoManager)
            return nil
        }
        if succeeded || session.phase == .discarded { unsavedEdits[session.id] = nil }
        return succeeded
    }

    func discardEdit(_ session: ReminderEditSession) {
        session.discard()
        if session.phase == .discarded { unsavedEdits[session.id] = nil }
    }
}
