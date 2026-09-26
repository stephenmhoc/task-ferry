import Foundation

/// Decides which due-date alerts a remote Mac should schedule. It is kept free of
/// UserNotifications so the rules can be tested directly.
///
/// The work Mac isn't signed in to the personal iCloud account, so Reminders' own alarms never fire
/// there. Task Ferry schedules local notifications for what's coming up instead.
enum ReminderNotificationPlan {
    struct Item: Equatable, Sendable {
        let identifier: String
        let reminderID: String
        let listID: String
        let title: String
        let body: String
        let fireDate: Date
    }

    /// macOS allows 64 pending notifications per app. A margin is kept for snoozes.
    static let limit = 56
    static let identifierPrefix = "reminder."

    static func items(
        for snapshot: ReminderSnapshot,
        now: Date,
        dateOnlyHour: Int,
        horizonDays: Int = 14,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Item] {
        guard let horizon = calendar.date(byAdding: .day, value: horizonDays, to: now) else { return [] }
        let listTitles = Dictionary(snapshot.lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        let items = snapshot.reminders.compactMap { reminder -> Item? in
            guard let due = reminder.due, let fireDate = fireDate(for: due, dateOnlyHour: dateOnlyHour, calendar: calendar),
                  fireDate > now, fireDate <= horizon else { return nil }
            let listTitle = listTitles[reminder.listID] ?? ""
            let firstNoteLine = reminder.notes?
                .split(whereSeparator: \.isNewline)
                .first
                .map { String($0).trimmed } ?? ""
            let body = [listTitle, firstNoteLine].filter { !$0.isEmpty }.joined(separator: " · ")
            return Item(
                identifier: identifier(reminderID: reminder.id, fireDate: fireDate, title: reminder.title, body: body),
                reminderID: reminder.id,
                listID: reminder.listID,
                title: reminder.title,
                body: body,
                fireDate: fireDate
            )
        }
        return Array(items.sorted { $0.fireDate < $1.fireDate }.prefix(limit))
    }

    static func fireDate(for due: ReminderDue, dateOnlyHour: Int, calendar: Calendar) -> Date? {
        if due.hasTime {
            return due.date(calendar: calendar)
        }
        return calendar.date(from: DateComponents(
            year: due.year,
            month: due.month,
            day: due.day,
            hour: min(max(dateOnlyHour, 0), 23)
        ))
    }

    /// The identifier includes the fire time and a digest of the text, so editing a reminder
    /// replaces its pending alert instead of leaving a stale one.
    static func identifier(reminderID: String, fireDate: Date, title: String, body: String) -> String {
        "\(identifierPrefix)\(reminderID).\(Int(fireDate.timeIntervalSince1970)).\(digest(title + "\u{1F}" + body))"
    }

    /// FNV-1a, because `hashValue` changes on every launch.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }
}
