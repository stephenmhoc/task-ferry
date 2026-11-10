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
    /// What the bridge last accepted. An editor can stay open after a save, when you choose to keep
    /// editing rather than quit, so anything typed after it still has to go through.
    @ObservationIgnored private var savedValue: ReminderRecord?

    /// True when there's something a save would still have to send.
    var hasUnsavedChanges: Bool { phase != .discarded && updated != (savedValue ?? original) }

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

    /// A reminder that doesn't exist yet. It shares the form, and only saving it differs.
    convenience init(newIn listID: String, due: ReminderDue?, connectionRevision: Int? = nil) {
        self.init(ReminderRecord(id: "", listID: listID, title: "", notes: nil, due: due, url: nil),
                  connectionRevision: connectionRevision)
    }

    var isNew: Bool { original.id.isEmpty }

    var updated: ReminderRecord {
        let initial = original.due
        let untouched = hasDue == (initial != nil)
            && includesTime == (initial?.hasTime ?? false)
            && (initial == nil || dueDate == initial?.date())
        let due = untouched ? initial : (hasDue ? ReminderDue(date: dueDate, includesTime: includesTime) : nil)
        // A copy of the original, so fields the form doesn't show compare equal.
        var record = original
        record.listID = listID
        record.title = title.trimmed
        record.notes = notes.trimmed.isEmpty ? nil : notes
        record.due = due
        return record
    }

    func discard() {
        guard phase != .saving else { return }
        phase = .discarded
        error = nil
    }

    /// Coalesces Return, disappearance and completion into one mutation. A failure is retryable.
    func commit(_ save: @escaping @MainActor (ReminderRecord) async -> String?) async -> Bool {
        if let saveTask { return await saveTask.value }
        if phase == .discarded { return false }
        let value = updated
        guard !value.title.isEmpty, !value.listID.isEmpty else {
            error = String(localized: "A reminder needs a title and a list.")
            phase = .failed
            return false
        }
        guard value != (savedValue ?? original) else {
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
            self.savedValue = value
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
        guard mode == .remote, session.phase != .failed, session.phase != .discarded else { return }
        // Retain synchronously so immediately reopening the row joins this same draft/save.
        unsavedEdits[session.id] = session
        Task { await saveEdit(session, undoManager: undoManager) }
    }

    /// Retains in-flight and failed drafts even after their window closes. No drafts go on disk.
    @discardableResult
    func saveEdit(_ session: ReminderEditSession, undoManager: UndoManager?) async -> Bool {
        if session.isNew { return await saveNewReminder(session, undoManager: undoManager).saved }
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

    /// Creates the reminder a new session describes, and returns its identifier once it exists.
    /// Like an edit, it's kept here while it's on its way and after it fails, so quitting waits
    /// for it and a failure can be retried from the draft banner.
    @discardableResult
    func saveNewReminder(_ session: ReminderEditSession, undoManager: UndoManager?) async -> (saved: Bool, id: String?) {
        guard session.phase != .discarded else { return (false, nil) }
        if let revision = session.connectionRevision, revision != connectionRevision {
            discardEdit(session)
            return (false, nil)
        }
        unsavedEdits[session.id] = session
        var createdID: String?
        let saved = await session.commit { [self] value in
            guard list(for: value.listID) != nil else {
                return String(localized: "This list was removed elsewhere. Copy your draft before discarding it.")
            }
            let outcome = await createReminder(title: value.title, listID: value.listID, due: value.due, notes: value.notes)
            guard outcome.succeeded else {
                return errorMessage ?? String(localized: "Couldn’t add this reminder. Try again.")
            }
            createdID = outcome.createdID
            if let id = outcome.createdID {
                ReminderUndo.registerCreation([id], state: self, undoManager: undoManager)
            }
            return nil
        }
        if saved || session.phase == .discarded { unsavedEdits[session.id] = nil }
        return (saved, createdID)
    }

    /// Edits that quitting now would lose, including ones that failed to save earlier.
    var editsAtRisk: [ReminderEditSession] {
        guard mode == .remote else { return [] }
        let edits: [UUID: ReminderEditSession] = unsavedEdits.merging(openEdits) { kept, _ in kept }
        return edits.values.filter { $0.hasUnsavedChanges }
    }

    /// Saves everything before the app quits, giving up after `timeout` because an unreachable
    /// bridge mustn't hold up quitting. Returns the edits still unsaved.
    func finishEdits(timeout: Duration = .seconds(6)) async -> [ReminderEditSession] {
        let edits = editsAtRisk
        var finished = false
        Task {
            for edit in edits { await saveEdit(edit, undoManager: nil) }
            finished = true
        }
        let deadline = ContinuousClock.now + timeout
        while !finished || !completingIDs.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return editsAtRisk
    }

    func discardEdit(_ session: ReminderEditSession) {
        session.discard()
        if session.phase == .discarded { unsavedEdits[session.id] = nil }
    }
}
