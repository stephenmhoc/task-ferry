import SwiftUI

struct InlineReminderEditor: View {
    private struct Draft: Hashable {
        var title: String
        var notes: String
        var listID: String
        var due: ReminderDue?

        var isValid: Bool {
            !title.trimmed.isEmpty && !listID.isEmpty
        }
    }

    @Bindable var state: AppState
    let reminder: ReminderRecord
    let onClose: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var listID: String
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var includesTime: Bool
    @State private var confirmingDelete = false
    @State private var isPerformingAction = false
    @State private var isCompleting = false

    init(state: AppState, reminder: ReminderRecord, onClose: @escaping () -> Void) {
        self.state = state
        self.reminder = reminder
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
                        .disabled(!draft.isValid || isPerformingAction || isCompleting)

                    Button("Delete…", role: .destructive) {
                        confirmingDelete = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isPerformingAction || isCompleting)

                    Button("Cancel", action: cancelEditing)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isPerformingAction || isCompleting)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .alert("Delete this reminder?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteReminder)
        } message: {
            Text("“\(reminder.title)” will be deleted from Apple Reminders. This can’t be undone.")
        }
    }

    private var completionButton: some View {
        Button(action: completeReminder) {
            ZStack {
                Circle()
                    .stroke(accentColor, lineWidth: 1.7)
                    .frame(width: 19, height: 19)
                if isCompleting {
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
        .disabled(isCompleting || isPerformingAction)
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
        Color(hex: selectedList?.colorHex ?? "0A69D8")
    }

    private var due: ReminderDue? {
        hasDue ? ReminderDue(date: dueDate, includesTime: includesTime) : nil
    }

    private var draft: Draft {
        Draft(title: title, notes: notes, listID: listID, due: due)
    }

    private func saveReminder() {
        let pendingDraft = draft
        guard pendingDraft.isValid, !isPerformingAction, !isCompleting else { return }
        isPerformingAction = true

        Task {
            if await state.updateReminder(
                reminder,
                title: pendingDraft.title.trimmed,
                listID: pendingDraft.listID,
                due: pendingDraft.due,
                notes: pendingDraft.notes.trimmed.isEmpty ? "" : pendingDraft.notes
            ) {
                onClose()
            } else {
                isPerformingAction = false
            }
        }
    }

    private func cancelEditing() {
        guard !isPerformingAction, !isCompleting else { return }
        onClose()
    }

    private func deleteReminder() {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        Task {
            if await state.deleteReminder(reminder) {
                onClose()
            } else {
                isPerformingAction = false
            }
        }
    }

    private func completeReminder() {
        guard !isCompleting, !isPerformingAction else { return }
        isCompleting = true
        Task {
            if await state.complete(reminder) {
                onClose()
            } else {
                isCompleting = false
            }
        }
    }
}
