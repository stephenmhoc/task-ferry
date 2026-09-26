import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    init(hex: String) {
        let value = Int(hex, radix: 16) ?? 0x007AFF
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum ReminderDeletionCopy {
    static func title(count: Int) -> String {
        count == 1
            ? String(localized: "Delete Reminder?")
            : String(localized: "Delete \(count) Reminders?")
    }

    static func message(for reminders: [ReminderRecord]) -> String {
        if reminders.count == 1, let title = reminders.first?.title {
            return String(localized: "“\(title)” will be deleted from Apple Reminders. This can’t be undone.")
        }
        return String(localized: "These reminders will be deleted from Apple Reminders. This can’t be undone.")
    }
}

/// A list's color as a small dot. Menus draw SwiftUI symbols as templates and drop their color,
/// so this is a non-template image that keeps it.
@MainActor
enum ListColorDot {
    private static var cache: [String: NSImage] = [:]

    static func image(hex: String) -> Image {
        if let image = cache[hex] {
            return Image(nsImage: image)
        }
        let value = Int(hex, radix: 16) ?? 0x007AFF
        let color = NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        cache[hex] = image
        return Image(nsImage: image)
    }
}

extension ReminderDue {
    /// "Today", "Tomorrow", or "Yesterday" for nearby days, as in Reminders. Otherwise, a short date.
    var summary: String {
        guard let date = date() else { return String(localized: "Due date unavailable") }
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let day: String
        if isSameDay(as: now) {
            day = String(localized: "Today")
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), isSameDay(as: tomorrow) {
            day = String(localized: "Tomorrow")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), isSameDay(as: yesterday) {
            day = String(localized: "Yesterday")
        } else {
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            day = sameYear
                ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                : date.formatted(date: .abbreviated, time: .omitted)
        }
        guard hasTime else { return day }
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }

    var timeText: String? {
        guard hasTime, let date = date() else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

extension UTType {
    static let taskFerryReminders = UTType(exportedAs: "com.merimerimeri.TaskFerry.reminders")
}

/// Reminders being dragged. Inside Task Ferry, dropping them on a list moves them, and dropping on
/// Today or Tomorrow reschedules them. Anywhere else, such as Mail or Notes, they drop as plain text.
struct ReminderDragItem: Codable, Sendable, Transferable {
    var ids: [String]
    var titles: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .taskFerryReminders)
        ProxyRepresentation(exporting: \.plainText)
    }

    var plainText: String { titles.joined(separator: "\n") }
}
