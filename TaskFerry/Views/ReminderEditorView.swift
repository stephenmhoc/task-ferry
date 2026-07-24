import SwiftUI

struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState
    let reminder: ReminderRecord?
    @State private var title: String
    @State private var notes: String
    @State private var listID: String
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var includesTime: Bool
    @State private var confirmingDelete = false
    @State private var isSaving = false
    @State private var isDeleting = false

    init(state: AppState, reminder: ReminderRecord?, defaultListID: String) {
        self.state = state
        self.reminder = reminder
        _title = State(initialValue: reminder?.title ?? "")
        _notes = State(initialValue: reminder?.notes ?? "")
        _listID = State(initialValue: reminder?.listID ?? defaultListID)
        _hasDue = State(initialValue: reminder?.due != nil)
        _dueDate = State(initialValue: reminder?.due?.date() ?? Date())
        _includesTime = State(initialValue: reminder?.due?.hasTime ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            SubviewHeader(
                title: reminder == nil ? "New Reminder" : "Edit Reminder",
                dismiss: { dismiss() }
            ) {
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isDeleting || title.trimmed.isEmpty || listID.isEmpty)
            }
            Divider()

            if let error = state.errorMessage {
                ErrorBanner(message: error) { state.dismissError() }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            Form {
                Section("Reminder") {
                    TextField("Title", text: $title)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                    Picker("List", selection: $listID) {
                        ForEach(state.snapshot.lists) { list in
                            Text(list.title).tag(list.id)
                        }
                    }
                }
                Section("Due") {
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Date", selection: $dueDate, displayedComponents: .date)
                        Toggle("Time", isOn: $includesTime)
                        if includesTime {
                            DatePicker("Time", selection: $dueDate, displayedComponents: .hourAndMinute)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if reminder != nil {
                deleteControls
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
    }

    private var due: ReminderDue? {
        hasDue ? ReminderDue(date: dueDate, includesTime: includesTime) : nil
    }

    @ViewBuilder
    private var deleteControls: some View {
        if confirmingDelete {
            HStack {
                Text("Delete this reminder?")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { confirmingDelete = false }
                    .disabled(isDeleting)
                Button(isDeleting ? "Deleting…" : "Delete", role: .destructive, action: delete)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isDeleting || isSaving)
            }
        } else {
            Button("Delete Reminder", role: .destructive) { confirmingDelete = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isSaving)
        }
    }

    private func save() {
        let cleanTitle = title.trimmed
        guard !isSaving, !isDeleting else { return }
        let selectedListID = listID
        let selectedDue = due
        let reminderNotes = notes.trimmed.isEmpty ? "" : notes
        isSaving = true
        Task {
            let succeeded: Bool
            if let reminder {
                succeeded = await state.updateReminder(
                    reminder,
                    title: cleanTitle,
                    listID: selectedListID,
                    due: selectedDue,
                    notes: reminderNotes
                )
            } else {
                succeeded = await state.createReminder(
                    title: cleanTitle,
                    listID: selectedListID,
                    due: selectedDue,
                    notes: reminderNotes
                )
            }
            if succeeded {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }

    private func delete() {
        guard let reminder, !isSaving, !isDeleting else { return }
        isDeleting = true
        Task {
            if await state.deleteReminder(reminder) {
                dismiss()
            } else {
                isDeleting = false
            }
        }
    }
}
