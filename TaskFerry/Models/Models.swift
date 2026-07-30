import Foundation

enum AppMode: String, Codable, CaseIterable {
    case bridge
    case remote
}

enum SmartView: String, CaseIterable, Identifiable {
    case today
    case tomorrow

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum DockBadgeScope: String, CaseIterable, Identifiable {
    case todayAndOverdue
    case overdueOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .todayAndOverdue: "Today & Overdue"
        case .overdueOnly: "Overdue Only"
        }
    }
}

struct ReminderDue: Codable, Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int?
    var minute: Int?
    var timeZoneIdentifier: String?

    var hasTime: Bool { hour != nil }

    init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int? = nil,
        minute: Int? = nil,
        timeZoneIdentifier: String? = nil
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    init(date: Date, includesTime: Bool, calendar: Calendar = .autoupdatingCurrent) {
        let parts = calendar.dateComponents(in: calendar.timeZone, from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
        hour = includesTime ? parts.hour : nil
        minute = includesTime ? parts.minute : nil
        timeZoneIdentifier = includesTime ? calendar.timeZone.identifier : nil
    }

    func date(calendar baseCalendar: Calendar = .autoupdatingCurrent) -> Date? {
        var calendar = baseCalendar
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = timeZone
        }
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))
    }

    func isSameDay(as date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return year == parts.year && month == parts.month && day == parts.day
    }

    func isBeforeDay(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let ownDate = self.date(calendar: calendar) else { return false }
        return calendar.startOfDay(for: ownDate) < calendar.startOfDay(for: date)
    }
}

struct ReminderListRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var colorHex: String
}

struct ReminderRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var listID: String
    var title: String
    var notes: String? = nil
    var due: ReminderDue?
}

struct ReminderSnapshot: Codable, Equatable, Sendable {
    var lists: [ReminderListRecord]
    var reminders: [ReminderRecord]
    var defaultListID: String? = nil

    static let empty = ReminderSnapshot(lists: [], reminders: [])
}

enum RPCOperation: String, Codable, Sendable {
    case snapshot
    case upsertList
    case deleteList
    case upsertReminder
    case setCompleted
    case deleteReminder
}

struct RPCRequest: Codable, Sendable {
    var operation: RPCOperation
    var id: String? = nil
    var title: String? = nil
    var notes: String? = nil
    var listID: String? = nil
    var due: ReminderDue? = nil
    var completed: Bool? = nil

    static let snapshot = RPCRequest(operation: .snapshot)
}

struct RPCResponse: Codable, Sendable {
    var snapshot: ReminderSnapshot? = nil
    var error: String? = nil
}

enum ReminderServiceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
