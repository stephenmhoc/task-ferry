import SwiftUI

/// Show Info: a reminder's date, time, list, and notes, in a popover like Reminders' info
/// popover. Changes are kept however it closes, because each one can be undone.
struct ReminderForm: View {
    private enum Field: Hashable { case title, notes }
    let state: AppState
    @Bindable var session: ReminderEditSession
    /// Only for a reminder that already exists.
    var onComplete: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// Saves and closes. Closing it any other way, with Esc or a click elsewhere, saves too.
    let onDone: () -> Void
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
                        .font(.title3)
                        .foregroundStyle(Color(hex: state.list(for: session.listID)?.colorHex ?? TaskFerryPalette.defaultListHex))
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
                    .onSubmit(onDone)
                    .accessibilityLabel("Reminder title")
                // A text editor, so Return starts a new line in the notes rather than closing.
                TextEditor(text: $session.notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    // Its text sits inset by the line padding; this lines it up with the title.
                    .padding(.leading, -5)
                    .frame(minHeight: 60, maxHeight: 110)
                    .focused($focusedField, equals: .notes)
                    .overlay(alignment: .topLeading) {
                        if session.notes.isEmpty {
                            Text("Notes")
                                .foregroundStyle(Color(nsColor: .placeholderTextColor))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Notes")
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
            // Return belongs to the notes while they're being typed, so there Done is ⌘Return.
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(focusedField == .notes ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction)
                .disabled(session.title.trimmed.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
