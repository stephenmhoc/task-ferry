import AppKit

/// Adds Services ▸ New Task Ferry Reminder, which works in any app with selected text. The first
/// line becomes the title, and the rest becomes notes, in a Quick Entry panel you can adjust.
@MainActor
final class ServicesProvider: NSObject {
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    @objc func newReminder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string)?.trimmed, !text.isEmpty else {
            error.pointee = String(localized: "Select some text to turn into a reminder.") as NSString
            return
        }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = String(lines[0]).trimmed
        let notes = lines.count > 1 ? String(lines[1]).trimmed : nil
        QuickEntryPanelController.shared.show(state: state, title: title, notes: notes?.isEmpty == true ? nil : notes)
    }
}
