import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    /// A list's color. The colors Reminders offers become the matching system colors, so they
    /// follow dark mode and Increase Contrast. Any other color is drawn exactly.
    init(hex: String) {
        self.init(nsColor: NSColor(listHex: hex))
    }
}

extension NSColor {
    convenience init(listHex hex: String) {
        if let system = Self.systemListColors[hex.uppercased()] {
            // System colors resolve for the current appearance and contrast when drawn.
            self.init(name: nil) { _ in system }
            return
        }
        let value = Int(hex, radix: 16) ?? 0x007AFF
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The colors in Reminders' list palette, as Task Ferry and EventKit spell them, in their
    /// light and dark forms.
    private static let systemListColors: [String: NSColor] = [
        "FF3B30": .systemRed, "FF453A": .systemRed, "FF2968": .systemRed,
        "FF9500": .systemOrange, "FF9F0A": .systemOrange,
        "FFCC00": .systemYellow, "FFD60A": .systemYellow,
        "34C759": .systemGreen, "30D158": .systemGreen, "63DA38": .systemGreen,
        "5AC8FA": .systemTeal, "64D2FF": .systemTeal,
        "007AFF": .systemBlue, "0A84FF": .systemBlue, "1BADF8": .systemBlue,
        "5856D6": .systemIndigo, "5E5CE6": .systemIndigo,
        "AF52DE": .systemPurple, "BF5AF2": .systemPurple, "CC73E1": .systemPurple,
        "FF2D55": .systemPink, "FF375F": .systemPink,
        "A2845E": .systemBrown, "AC8E68": .systemBrown,
        "8E8E93": .systemGray, "98989D": .systemGray
    ]
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
        let color = NSColor(listHex: hex)
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
    /// The floating + button, dragged onto a list to start a reminder there. Only Task Ferry reads it.
    static let taskFerryNewReminder = UTType(exportedAs: "com.merimerimeri.TaskFerry.new-reminder")
}

/// What the floating + button carries when it's dragged. It has no plain-text form, so other
/// apps ignore it.
struct NewReminderDragItem: Codable, Sendable, Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .taskFerryNewReminder)
    }
}

/// The reminders in the drag that's under way, if it started in Task Ferry. A drop target can't
/// read a drag's contents before the drop, and this lets it refuse a drop that would do nothing.
@MainActor
enum ReminderDragSession {
    static var ids: [String] = []
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
