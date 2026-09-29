import SwiftUI

enum ReminderEditorPopover: Equatable {
    case date
    case time
}

@MainActor
func reminderEscapeEventTimestamp() -> TimeInterval? {
    guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 else { return nil }
    return event.timestamp
}

struct InlineReminderEditor: View {
    private enum Field: Hashable { case title, notes }
    let state: AppState
    @Bindable var session: ReminderEditSession
    let onComplete: () -> Void
    let onDelete: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: Field?
    @Binding var editorPopover: ReminderEditorPopover?
    @Binding var consumedPopoverEscapeTimestamp: TimeInterval?

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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $session.notes)
                            .font(.callout)
                            .scrollContentBackground(.hidden)
                            .frame(height: 44)
                            .padding(5)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)) }
                            .focused($focusedField, equals: .notes)
                            .accessibilityLabel("Notes")
                    }
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
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.trailing, 8)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
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
        .onExitCommand {
            if consumedPopoverEscapeTimestamp == reminderEscapeEventTimestamp(),
               reminderEscapeEventTimestamp() != nil { return }
            if editorPopover != nil {
                dismissPopover()
            } else {
                onCancel()
            }
        }
        .onChange(of: session.hasDue) { _, hasDue in
            if !hasDue { editorPopover = nil }
        }
        .onChange(of: session.includesTime) { _, includesTime in
            if !includesTime, editorPopover == .time { editorPopover = nil }
        }
    }

    private var metadataControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("List")
                Menu {
                    ForEach(state.snapshot.lists) { list in
                        Button {
                            session.listID = list.id
                        } label: {
                            if list.id == session.listID {
                                Label(list.title, systemImage: "checkmark")
                            } else {
                                Text(list.title)
                            }
                        }
                    }
                } label: {
                    metadataControlContent(state.list(for: session.listID)?.title ?? String(localized: "Choose List"), symbol: "list.bullet", showsChevron: false)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize(horizontal: true, vertical: false)
                .modifier(MetadataControlSurface())
                .accessibilityLabel("List")
                .accessibilityValue(Text(state.list(for: session.listID)?.title ?? String(localized: "Choose List")))
                Spacer(minLength: 0)
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
                Button {
                    editorPopover = .date
                } label: {
                    metadataControl(session.dueDate.formatted(.dateTime.month(.abbreviated).day().year()), symbol: "calendar")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Due date")
                .accessibilityValue(Text(session.dueDate, format: .dateTime.month(.abbreviated).day().year()))
                .popover(isPresented: pickerPresented(.date), arrowEdge: .bottom) {
                    DatePicker("Due date", selection: $session.dueDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .onExitCommand(perform: dismissPopover)
                        .onKeyPress(.escape) {
                            dismissPopover()
                            return .handled
                        }
                }
            }
        }.fixedSize()
    }

    @ViewBuilder private var timeControls: some View {
        if session.hasDue {
            HStack {
                Toggle("Time", isOn: $session.includesTime).toggleStyle(.checkbox)
                if session.includesTime {
                    Button {
                        editorPopover = .time
                    } label: {
                        metadataControl(session.dueDate.formatted(date: .omitted, time: .shortened), symbol: "clock")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Due time")
                    .accessibilityValue(Text(session.dueDate, format: .dateTime.hour().minute()))
                    .popover(isPresented: pickerPresented(.time), arrowEdge: .bottom) {
                        VStack(alignment: .trailing, spacing: 10) {
                            DatePicker("Due time", selection: $session.dueDate, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.field)
                            Button("Done") { editorPopover = nil }
                        }
                        .padding()
                        .onExitCommand(perform: dismissPopover)
                        .onKeyPress(.escape) {
                            dismissPopover()
                            return .handled
                        }
                    }
                }
            }.fixedSize()
        }
    }

    private func pickerPresented(_ picker: ReminderEditorPopover) -> Binding<Bool> {
        Binding(
            get: { editorPopover == picker },
            set: { presented in
                if presented {
                    editorPopover = picker
                } else if editorPopover == picker {
                    dismissPopover()
                }
            }
        )
    }

    private func dismissPopover() {
        if let timestamp = reminderEscapeEventTimestamp() {
            consumedPopoverEscapeTimestamp = timestamp
        }
        editorPopover = nil
    }

    private func metadataControl(_ value: String, symbol: String) -> some View {
        metadataControlContent(value, symbol: symbol)
            .modifier(MetadataControlSurface())
    }

    private func metadataControlContent(_ value: String, symbol: String, showsChevron: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color(nsColor: .labelColor))
    }

}

private struct MetadataControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.22)) }
    }
}
