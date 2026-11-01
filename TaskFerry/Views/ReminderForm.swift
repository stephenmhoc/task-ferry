import SwiftUI

@MainActor
func reminderEscapeEventTimestamp() -> TimeInterval? {
    guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 else { return nil }
    return event.timestamp
}

/// Creating and editing a reminder are the same form, shown in a popover like a Calendar event.
struct ReminderForm: View {
    private enum Field: Hashable { case title, notes }
    let state: AppState
    @Bindable var session: ReminderEditSession
    /// Only for a reminder that already exists.
    var onComplete: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section { text }
                Section {
                    listPicker
                    dateRow
                    if session.hasDue { timeRow }
                }
                if let error = session.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            footer
        }
        .frame(width: 360)
        .disabled(session.phase == .saving)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.hasDue)
        .onExitCommand(perform: onCancel)
        .task {
            // A popover's window isn't key until it has appeared.
            await Task.yield()
            focusedField = .title
        }
    }

    private var text: some View {
        HStack(alignment: .top, spacing: 10) {
            if let onComplete {
                Button(action: onComplete) {
                    Image(systemName: "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Mark as Completed")
                .accessibilityLabel("Mark \(session.original.title) as completed")
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $session.title, prompt: Text("Title"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1...4)
                    .focused($focusedField, equals: .title)
                    .onSubmit(onSave)
                    .accessibilityLabel("Reminder title")
                ZStack(alignment: .topLeading) {
                    if session.notes.isEmpty {
                        Text("Notes")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $session.notes)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, -5)
                        .focused($focusedField, equals: .notes)
                        .accessibilityLabel("Notes")
                }
                .font(.body)
                .frame(height: 64)
            }
        }
    }

    private var listPicker: some View {
        Picker("List", selection: $session.listID) {
            ForEach(state.snapshot.lists) { list in
                Label {
                    Text(list.title)
                } icon: {
                    ListColorDot.image(hex: list.colorHex)
                }
                .tag(list.id)
            }
        }
    }

    private var dateRow: some View {
        LabeledContent("Date") {
            HStack(spacing: 10) {
                if session.hasDue {
                    DatePicker("Due date", selection: $session.dueDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                Toggle("Has a date", isOn: $session.hasDue)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var timeRow: some View {
        LabeledContent("Time") {
            HStack(spacing: 10) {
                if session.includesTime {
                    DatePicker("Due time", selection: $session.dueDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                Toggle("Has a time", isOn: $session.includesTime)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let onDelete {
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete Reminder")
                    .accessibilityLabel("Delete")
            }
            ReminderLinkMenu(urls: ReminderLinks.urls(title: session.title, notes: session.notes, url: session.original.url))
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
            Spacer()
            if session.phase == .saving { ProgressView().controlSize(.small) }
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(session.isNew ? "Add" : "Save", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.title.trimmed.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
