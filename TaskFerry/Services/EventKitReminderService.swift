import AppKit
@preconcurrency import EventKit
import Foundation

@MainActor
final class EventKitReminderService: ReminderService {
    private let store = EKEventStore()

    func execute(_ request: RPCRequest) async throws -> ReminderSnapshot {
        try await ensureAccess()
        switch request.operation {
        case .snapshot:
            break
        case .upsertList:
            try upsertList(id: request.id, title: request.title)
        case .deleteList:
            try deleteList(id: request.id)
        case .upsertReminder:
            try upsertReminder(request)
        case .setCompleted:
            try setCompleted(id: request.id, completed: request.completed)
        case .deleteReminder:
            try deleteReminder(id: request.id)
        }
        return try await snapshot()
    }

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            guard try await store.requestFullAccessToReminders() else {
                throw ReminderServiceError.message("Reminders access was not granted.")
            }
        default:
            throw ReminderServiceError.message("Allow Task Ferry in System Settings → Privacy & Security → Reminders.")
        }
    }

    private func snapshot() async throws -> ReminderSnapshot {
        store.refreshSourcesIfNecessary()
        let calendars = writableCalendars()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        let reminderRecords: [ReminderRecord] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(Self.record))
            }
        }

        return ReminderSnapshot(
            lists: calendars.map { calendar in
                ReminderListRecord(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    colorHex: Self.colorHex(calendar.cgColor)
                )
            }.sorted(by: Self.sortLists),
            reminders: reminderRecords,
            defaultListID: store.defaultCalendarForNewReminders()?.calendarIdentifier
        )
    }

    private func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .reminder).filter(\.allowsContentModifications)
    }

    private func upsertList(id: String?, title: String?) throws {
        guard let title = title?.trimmed, !title.isEmpty else {
            throw ReminderServiceError.message("A list needs a name.")
        }
        if let id {
            guard let calendar = writableCalendars().first(where: { $0.calendarIdentifier == id }),
                  !calendar.isImmutable else {
                throw ReminderServiceError.message("That list is no longer editable.")
            }
            calendar.title = title
            try store.saveCalendar(calendar, commit: true)
            return
        }

        guard let source = store.defaultCalendarForNewReminders()?.source else {
            throw ReminderServiceError.message("No writable Reminders account is available.")
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
    }

    private func deleteList(id: String?) throws {
        guard let id,
              let calendar = writableCalendars().first(where: { $0.calendarIdentifier == id }),
              !calendar.isImmutable else {
            throw ReminderServiceError.message("That list is no longer editable.")
        }
        try store.removeCalendar(calendar, commit: true)
    }

    private func upsertReminder(_ request: RPCRequest) throws {
        guard let title = request.title?.trimmed, !title.isEmpty,
              let listID = request.listID,
              let calendar = writableCalendars().first(where: { $0.calendarIdentifier == listID }) else {
            throw ReminderServiceError.message("A reminder needs a title and editable list.")
        }

        let reminder: EKReminder
        if let id = request.id {
            guard let existing = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
            }
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: store)
        }
        reminder.title = title
        if let notes = request.notes {
            reminder.notes = notes.trimmed.isEmpty ? nil : notes
        }
        reminder.calendar = calendar
        reminder.dueDateComponents = request.due?.dateComponents
        try store.save(reminder, commit: true)
    }

    private func setCompleted(id: String?, completed: Bool?) throws {
        guard let id,
              let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
        }
        reminder.isCompleted = completed ?? true
        try store.save(reminder, commit: true)
    }

    private func deleteReminder(id: String?) throws {
        guard let id,
              let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
        }
        try store.remove(reminder, commit: true)
    }

    private static func record(_ reminder: EKReminder) -> ReminderRecord? {
        guard let calendar = reminder.calendar else { return nil }
        return ReminderRecord(
            id: reminder.calendarItemIdentifier,
            listID: calendar.calendarIdentifier,
            title: reminder.title ?? "Untitled Reminder",
            notes: reminder.notes,
            due: reminder.dueDateComponents.map(ReminderDue.init)
        )
    }

    private static func colorHex(_ cgColor: CGColor?) -> String {
        guard let cgColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return "5E5CE6"
        }
        return String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    private static func sortLists(_ lhs: ReminderListRecord, _ rhs: ReminderListRecord) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

private extension ReminderDue {
    init(_ components: DateComponents) {
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
        hour = components.hour
        minute = components.minute
        timeZoneIdentifier = components.timeZone?.identifier
    }

    var dateComponents: DateComponents {
        var components = DateComponents()
        components.calendar = .autoupdatingCurrent
        components.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components
    }
}
