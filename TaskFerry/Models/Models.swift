import Foundation

enum AppMode: String, Codable, CaseIterable {
    case bridge
    case remote
}

enum DockBadgeScope: String, CaseIterable, Identifiable {
    case todayAndOverdue
    case overdueOnly

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .todayAndOverdue: "Today & Overdue"
        case .overdueOnly: "Overdue Only"
        }
    }
}

/// The due-date shortcuts offered by Quick Entry, menus, drag targets, notifications, and URLs.
enum QuickDueOption: String, CaseIterable, Identifiable, Sendable {
    case none
    case today
    case tomorrow

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .none: "None"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        }
    }

    func due(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> ReminderDue? {
        switch self {
        case .none:
            return nil
        case .today:
            return ReminderDue(date: now, includesTime: false, calendar: calendar)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return ReminderDue(date: tomorrow, includesTime: false, calendar: calendar)
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

    /// The calendar day this reminder falls on for someone using `calendar`.
    ///
    /// Date-only reminders float, so their stored components are the day everywhere. A timed reminder
    /// pinned to another time zone can land on a different local day, so it is converted first.
    private func localDayComponents(calendar: Calendar) -> (year: Int?, month: Int?, day: Int?) {
        if hasTime, timeZoneIdentifier != nil, let instant = date(calendar: calendar) {
            let parts = calendar.dateComponents([.year, .month, .day], from: instant)
            return (parts.year, parts.month, parts.day)
        }
        return (year, month, day)
    }

    func isSameDay(as date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let own = localDayComponents(calendar: calendar)
        return own.year == parts.year && own.month == parts.month && own.day == parts.day
    }

    func isBeforeDay(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let own = localDayComponents(calendar: calendar)
        guard let ownDate = calendar.date(from: DateComponents(year: own.year, month: own.month, day: own.day)) else {
            return false
        }
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
    /// The newest protocol this build speaks. Bridges advertise it so remotes only rely on
    /// features, such as retrying with ``requestID``, that the bridge actually honors.
    static let currentProtocolVersion = 2

    var operation: RPCOperation
    var id: String? = nil
    var title: String? = nil
    var notes: String? = nil
    var listID: String? = nil
    var due: ReminderDue? = nil
    var completed: Bool? = nil
    /// Optional list color for `upsertList`. Older bridges ignore it.
    var colorHex: String? = nil
    /// Identifies one logical mutation so a retried request is applied at most once.
    var requestID: String? = nil

    static let snapshot = RPCRequest(operation: .snapshot)
}

struct RPCResponse: Codable, Sendable {
    var snapshot: ReminderSnapshot? = nil
    var error: String? = nil
    /// The identifier EventKit assigned to a newly created reminder or list.
    var createdID: String? = nil
    var protocolVersion: Int? = nil
}

/// What a reminder service returns for every request: the authoritative snapshot, plus the
/// identifier of anything the request created.
struct RPCResult: Equatable, Sendable {
    var snapshot: ReminderSnapshot
    var createdID: String? = nil
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
