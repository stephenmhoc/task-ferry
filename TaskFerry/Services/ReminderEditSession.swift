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

    /// Nothing typed or chosen: no title, no notes, and the date and list it started with. Only
    /// a blank new row goes away when it's left; anything else is kept, and says what it needs.
    var isBlank: Bool {
        title.trimmed.isEmpty && notes.trimmed.isEmpty && updated.due == original.due && listID == original.listID
    }

    /// Says why it can't be saved yet, and keeps it, as a failed save does.
    @discardableResult
    func markIncomplete() -> Bool {
        let value = updated
        guard value.title.isEmpty || value.listID.isEmpty else { return false }
        error = String(localized: "A reminder needs a title and a list.")
        phase = .failed
        return true
    }

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
        if markIncomplete() { return false }
        let value = updated
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
            guard let current = reminder(for: updated.id) else {
                return String(localized: "This reminder was removed elsewhere. Copy your draft before discarding it.")
            }
            // Every field goes to the bridge, so a field this edit didn't touch takes the value the
            // bridge has now. A change made elsewhere while the edit was open isn't overwritten.
            let sent = Self.merging(updated, over: current, startingFrom: session.original)
            guard await updateReminder(current, title: sent.title, listID: sent.listID,
                                       due: sent.due, notes: sent.notes ?? "") else {
                return errorMessage ?? String(localized: "Couldn’t save this edit. Try again.")
            }
            ReminderUndo.registerEdit(restoring: [current], redoing: [sent],
                                      name: String(localized: "Edit Reminder"), state: self, undoManager: undoManager)
            return nil
        }
        if succeeded || session.phase == .discarded { unsavedEdits[session.id] = nil }
        return succeeded
    }

    /// The edit's changes on top of the reminder as it is now: what changed since `original` comes
    /// from `edited`, and everything else from `current`.
    nonisolated static func merging(_ edited: ReminderRecord, over current: ReminderRecord,
                                    startingFrom original: ReminderRecord) -> ReminderRecord {
        var merged = current
        if edited.title != original.title.trimmed { merged.title = edited.title }
        if edited.notes != original.notes { merged.notes = edited.notes }
        if edited.listID != original.listID { merged.listID = edited.listID }
        if edited.due != original.due { merged.due = edited.due }
        return merged
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

/// Due-date changes shared by the row editor and Show Info. They follow ReminderDue's rules: a date
/// on its own stays date-only, and a day or time put back the way it was keeps its original
/// components, because the session only builds new ones for a date that differs from the start.
extension ReminderEditSession {
    /// Moves the reminder to `day`, keeping its time of day, if it has one.
    func setDueDay(_ day: Date, calendar: Calendar = .autoupdatingCurrent) {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        if includesTime {
            let time = calendar.dateComponents([.hour, .minute], from: dueDate)
            parts.hour = time.hour
            parts.minute = time.minute
        }
        dueDate = calendar.date(from: parts) ?? day
        hasDue = true
    }

    func setDueTime(hour: Int, minute: Int, calendar: Calendar = .autoupdatingCurrent) {
        dueDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dueDate) ?? dueDate
        includesTime = true
    }

    func removeDueDate() {
        hasDue = false
        includesTime = false
    }

    /// Back to the date on its own. When that's the day it started on, it's the very same
    /// components again.
    func removeDueTime(calendar: Calendar = .autoupdatingCurrent) {
        includesTime = false
        if let initial = original.due, !initial.hasTime, let start = initial.date(calendar: calendar),
           calendar.isDate(start, inSameDayAs: dueDate) {
            dueDate = start
        } else {
            dueDate = calendar.startOfDay(for: dueDate)
        }
    }

    /// What the time picker offers before there's a time: the next whole hour on a reminder due
    /// today, or 9 AM on another day.
    func proposedTime(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date {
        let day = calendar.startOfDay(for: dueDate)
        if calendar.isDateInToday(day),
           let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime),
           calendar.isDate(nextHour, inSameDayAs: day) {
            return nextHour
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// Past due, as the row shows it: a day before today, or a time that has gone by.
    func isOverdue(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard hasDue else { return false }
        return includesTime ? dueDate < now : calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: now)
    }
}
