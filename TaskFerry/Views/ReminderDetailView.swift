import SwiftUI

struct InlineReminderEditor: View {
    private enum PendingAction {
        case saving
        case completing
    }

    let state: AppState
    let reminder: ReminderRecord
    let onDeleteRequested: () -> Void
    let onClose: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var listID: String
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var includesTime: Bool
    @State private var pendingAction: PendingAction?

    init(
        state: AppState,
        reminder: ReminderRecord,
        onDeleteRequested: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.state = state
        self.reminder = reminder
        self.onDeleteRequested = onDeleteRequested
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
        HStack(alignment: .top, spacing: 12) {
            completionButton

            VStack(alignment: .leading, spacing: 10) {
                titleControl
                notesControl
                metadataControls

                HStack(spacing: 8) {
                    Button("Save", action: saveReminder)
                        .buttonStyle(.borderedProminent)
                        .tint(TaskFerryPalette.ocean)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!isValid || isBusy)

                    Button("Delete…", role: .destructive) {
                        onDeleteRequested()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isBusy)

                    Button("Cancel", action: cancelEditing)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isBusy)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
    }

    private var completionButton: some View {
        Button(action: completeReminder) {
            ZStack {
                Circle()
                    .stroke(accentColor, lineWidth: 1.7)
                    .frame(width: 19, height: 19)
                if pendingAction == .completing {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: 27, height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mark as Complete")
        .accessibilityLabel("Complete \(reminder.title)")
        .disabled(isBusy)
    }

    private var titleControl: some View {
        TextField("Task", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body.weight(.medium))
            .lineLimit(1...3)
            .accessibilityLabel("Reminder title")
    }

    private var notesControl: some View {
        TextField("Add notes…", text: $notes, axis: .vertical)
            .textFieldStyle(.plain)
            .foregroundStyle(.secondary)
            .lineLimit(1...5)
            .accessibilityLabel("Notes")
    }

    private var listPicker: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accentColor)
                .frame(width: 6, height: 6)

            Picker("List", selection: $listID) {
                ForEach(state.snapshot.lists) { list in
                    Text(list.title).tag(list.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var metadataControls: some View {
        HStack(spacing: 12) {
            listPicker

            Divider()
                .frame(height: 14)

            Toggle("Due", isOn: $hasDue)
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
        }
        .font(.caption)
        .controlSize(.small)
    }

    private var selectedList: ReminderListRecord? {
        state.list(for: listID)
    }

    private var accentColor: Color {
        Color(hex: selectedList?.colorHex ?? TaskFerryPalette.defaultListHex)
    }

    private var due: ReminderDue? {
        hasDue ? ReminderDue(date: dueDate, includesTime: includesTime) : nil
    }

    private var isValid: Bool {
        !title.trimmed.isEmpty && !listID.isEmpty
    }

    private var isBusy: Bool {
        pendingAction != nil
    }

    private func saveReminder() {
        guard isValid, !isBusy else { return }
        let pendingTitle = title.trimmed
        let pendingNotes = notes
        let pendingListID = listID
        let pendingDue = due
        pendingAction = .saving

        Task {
            if await state.updateReminder(
                reminder,
                title: pendingTitle,
                listID: pendingListID,
                due: pendingDue,
                notes: pendingNotes
            ) {
                onClose()
            } else {
                pendingAction = nil
            }
        }
    }

    private func cancelEditing() {
        guard !isBusy else { return }
        onClose()
    }

    private func completeReminder() {
        guard !isBusy else { return }
        pendingAction = .completing
        Task {
            if await state.complete(reminder) {
                onClose()
            } else {
                pendingAction = nil
            }
        }
    }
}
