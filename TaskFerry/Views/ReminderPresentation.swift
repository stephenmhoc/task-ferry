import SwiftUI

extension Color {
    init(hex: String) {
        let value = Int(hex, radix: 16) ?? 0x0A69D8
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum ReminderDeletionCopy {
    static func message(for title: String) -> String {
        "“\(title)” will be deleted from Apple Reminders. This can’t be undone."
    }
}

extension ReminderDue {
    var summary: String {
        guard let date = date() else { return "Due date unavailable" }
        return hasTime
            ? date.formatted(date: .abbreviated, time: .shortened)
            : date.formatted(date: .abbreviated, time: .omitted)
    }

    var displayText: String? {
        if isBeforeDay(Date()) { return "Overdue" }
        guard hasTime, let date = date() else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
