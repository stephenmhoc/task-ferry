import SwiftUI

struct InlineReminderEditor: View {
    private enum Field: Hashable { case title, notes }
    let state: AppState
    @Bindable var session: ReminderEditSession
    let onComplete: () -> Void
    let onDelete: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    onComplete()
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Mark as Completed")
                .accessibilityLabel("Mark \(session.original.title) as completed")

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: $session.title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundColor(Color(nsColor: .labelColor))
                        .lineLimit(1...4)
                        .focused($focusedField, equals: .title)
                        .onSubmit(onSave)
                        .accessibilityLabel("Reminder title")
                    TextField("Notes", text: $session.notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .font(.callout)
                        .lineLimit(1...8)
                        .focused($focusedField, equals: .notes)
                        .accessibilityLabel("Notes")
                }
            }
            metadataControls
            if let error = session.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry", action: onSave)
                    Button("Discard Changes", role: .destructive, action: onCancel)
                }
            }
            if session.phase == .saving { ProgressView("Saving…").controlSize(.small) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Done", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
        }
        // List selection changes `.primary` to white; our editor has its own neutral surface.
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)) }
        .padding(.vertical, 4)
        .disabled(session.phase == .saving)
        .onAppear { focusedField = .title }
        .onExitCommand(perform: onCancel)
    }

    private var metadataControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("List", selection: $session.listID) {
                    ForEach(state.snapshot.lists) { list in
                        Text(list.title).tag(list.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                Spacer(minLength: 8)
                Button("Delete…", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
            }
            dateControls
            timeControls
        }
        .font(.callout)
        .controlSize(.small)
    }

    private var dateControls: some View {
        HStack {
            Toggle("Date", isOn: $session.hasDue).toggleStyle(.checkbox)
            if session.hasDue {
                DatePicker("Due date", selection: $session.dueDate, displayedComponents: .date)
                    .labelsHidden()
            }
        }.fixedSize()
    }

    @ViewBuilder private var timeControls: some View {
        if session.hasDue {
            HStack {
                Toggle("Time", isOn: $session.includesTime).toggleStyle(.checkbox)
                if session.includesTime {
                    DatePicker("Due time", selection: $session.dueDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }.fixedSize()
        }
    }

}
