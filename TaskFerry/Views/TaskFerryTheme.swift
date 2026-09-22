import AppKit
import SwiftUI

/// Smart-list colors are system colors, so they follow dark mode and Increase Contrast. Controls
/// use the user's accent color. Only lists keep their own colors, which come from Reminders.
enum TaskFerryPalette {
    static let defaultListHex = "007AFF"
    static var today: Color { Color(nsColor: .systemBlue) }
    static var tomorrow: Color { Color(nsColor: .systemTeal) }
    static var all: Color { Color(nsColor: .systemGray) }
    static var overdue: Color { Color(nsColor: .systemRed) }

    /// The list colors Reminders offers.
    static let listColors: [(name: LocalizedStringResource, hex: String)] = [
        ("Red", "FF3B30"),
        ("Orange", "FF9500"),
        ("Yellow", "FFCC00"),
        ("Green", "34C759"),
        ("Teal", "5AC8FA"),
        ("Blue", "007AFF"),
        ("Indigo", "5856D6"),
        ("Purple", "AF52DE"),
        ("Pink", "FF2D55"),
        ("Brown", "A2845E"),
        ("Graphite", "8E8E93")
    ]
}
