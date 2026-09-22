import SwiftUI

/// Edits a reminder in place, the way Reminders and Things do. There's no Save button: changes
/// are kept when you press Return, click another reminder, switch lists, or close the window.
/// Esc discards them.
struct InlineReminderEditor: View {
    private enum Field: Hashable {
        case title
        case notes
    }

    let state: AppState
    let reminder: ReminderRecord
    let onSave: (_ title: String, _ notes: String, _ listID: String, _ due: ReminderDue?) -> Void
    let onComplete: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var listID: String
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var includesTime: Bool
    @State private var isFinished = false
    @FocusState private var focusedField: Field?

    init(
        state: AppState,
        reminder: ReminderRecord,
        onSave: @escaping (_ title: String, _ notes: String, _ listID: String, _ due: ReminderDue?) -> Void,
        onComplete: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.state = state
        self.reminder = reminder
        self.onSave = onSave
        self.onComplete = onComplete
        self.onDelete = onDelete
        self.onClose = onClose

        let initialDue = reminder.due
        _title = State(initialValue: reminder.title)
        _notes = State(initialValue: reminder.notes ?? "")
        _listID = State(initialValue: reminder.listID)
        _hasDue = State(initialValue: initialDue != nil)
        _dueDate = State(initialValue: initialDue?.date() ?? Date())
        _includesTime = State(initialValue: initialDue?.hasTime ?? false)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                // Keep what was typed, then complete, as clicking the circle does in Reminders.
                commit()
                onComplete()
            } label: {
                Circle()
                    .strokeBorder(accentColor, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mark as Completed")
            .accessibilityLabel("Mark \(reminder.title) as completed")
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focusedField, equals: .title)
                    .onSubmit(commitAndClose)
                    .accessibilityLabel("Reminder title")

                TextField("Notes", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...8)
                    .focused($focusedField, equals: .notes)
                    .accessibilityLabel("Notes")

                metadataControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .onAppear { focusedField = .title }
        .onDisappear(perform: commit)
        .onExitCommand(perform: revertAndClose)
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            commitAndClose()
            return .handled
        }
    }

    private var metadataControls: some View {
        HStack(spacing: 12) {
            Picker("List", selection: $listID) {
                ForEach(state.snapshot.lists) { list in
                    Label {
                        Text(list.title)
                    } icon: {
                        ListColorDot.image(hex: list.colorHex)
                    }
                    .tag(list.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Toggle("Date", isOn: $hasDue)
                .toggleStyle(.checkbox)
                .fixedSize()

            if hasDue {
                DatePicker("Date", selection: $dueDate, displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()

                Toggle("Time", isOn: $includesTime)
                    .toggleStyle(.checkbox)
                    .fixedSize()

                if includesTime {
                    DatePicker("Time", selection: $dueDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                }
            }

            Spacer()

            // Only asks for confirmation. If the user cancels, editing and autosave carry on.
            Button("Delete…", role: .destructive, action: onDelete)
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .font(.callout)
        .controlSize(.small)
    }

    private var accentColor: Color {
        Color(hex: state.list(for: listID)?.colorHex ?? TaskFerryPalette.defaultListHex)
    }

    /// The edited due date. When the date controls weren't touched, the original value is returned
    /// exactly, so an edit to the title never rewrites a reminder's time zone or floating time.
    private var editedDue: ReminderDue? {
        let initial = reminder.due
        let untouched = hasDue == (initial != nil)
            && includesTime == (initial?.hasTime ?? false)
            && (initial == nil || dueDate == initial?.date())
        if untouched { return initial }
        return hasDue ? ReminderDue(date: dueDate, includesTime: includesTime) : nil
    }

    private func commit() {
        guard !isFinished else { return }
        isFinished = true
        // Deleted or completed elsewhere while open: there's nothing left to save to.
        guard state.reminder(for: reminder.id) != nil else { return }
        let cleanTitle = title.trimmed
        guard !cleanTitle.isEmpty, !listID.isEmpty else { return }
        let due = editedDue
        let changed = cleanTitle != reminder.title
            || notes != (reminder.notes ?? "")
            || listID != reminder.listID
            || due != reminder.due
        if changed {
            onSave(cleanTitle, notes, listID, due)
        }
    }

    private func commitAndClose() {
        commit()
        onClose()
    }

    private func revertAndClose() {
        isFinished = true
        onClose()
    }
}
