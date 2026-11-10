import SwiftUI

/// The date or time popover open on one row's editor.
struct RowPopover: Hashable {
    let rowID: String
    let field: ReminderRowField
}

/// A field or control in the row being edited. Moving between them stays in the row.
enum ReminderRowField: Hashable {
    case title, notes, date, time, list, info

    /// Whether focus is given back when it goes nowhere. Only the text fields: a control loses
    /// focus when its popover opens, and taking focus back would close the popover.
    var takesFocusBack: Bool { self == .title || self == .notes }
}

/// A reminder being edited in its own row, as in Reminders: the title, notes under it, and a row
/// of compact controls for the date, time, and list. New reminders are typed into the same editor.
///
/// Return in the title saves the row. Inside a list row the keys go to the list, so the
/// workspace's Return handler is what puts a line break into the notes, saves on ⌘Return from any
/// field, and opens the date or time popover from the keyboard. Esc puts the whole row back; in a
/// popover, Esc closes just the popover.
struct InlineReminderEditor: View {
    @Bindable var session: ReminderEditSession
    /// The reminder's identifier, or the new row's.
    let rowID: String
    let lists: [ReminderListRecord]
    var focus: FocusState<WorkspaceFocus?>.Binding
    let titlePrompt: LocalizedStringKey
    let titleLabel: LocalizedStringKey
    /// Bumped to give the title focus when the editor is already on screen.
    var focusRequest = 0
    /// The date or time popover that's open, if any; Return on the control opens it.
    @Binding var popover: RowPopover?
    /// Opens Show Info. Only an existing reminder has one.
    var onShowInfo: (() -> Void)? = nil
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                titleField
                if let onShowInfo {
                    Button(action: onShowInfo) {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .focused(focus, equals: .row(rowID, .info))
                    .help("Show Info")
                    .accessibilityLabel("Show Info")
                }
            }
            notesField
            details
            if let error = session.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Esc closes an open popover first, which may not have the keyboard yet, and only then the row.
        .onExitCommand {
            if popover?.rowID == rowID {
                popover = nil
            } else {
                onCancel()
            }
        }
        // A selected row can draw its text in the selection's colours; the row's background hides
        // the selection while it's edited, so the text keeps its usual colours.
        .foregroundStyle(.primary)
        .onAppear { focus.wrappedValue = .row(rowID, .title) }
        .onChange(of: focusRequest) { _, _ in focus.wrappedValue = .row(rowID, .title) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: session.hasDue)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: session.includesTime)
    }

    /// Typing is ignored while a save is on its way, rather than disabling the field, which would
    /// take its focus away.
    private func editable(_ keyPath: ReferenceWritableKeyPath<ReminderEditSession, String>) -> Binding<String> {
        Binding(
            get: { session[keyPath: keyPath] },
            set: { if session.phase != .saving { session[keyPath: keyPath] = $0 } }
        )
    }

    private var titleField: some View {
        TextField(titlePrompt, text: editable(\.title), prompt: Text(titlePrompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.body)
            .focused(focus, equals: .row(rowID, .title))
            .onSubmit(onSubmit)
            .accessibilityLabel(titleLabel)
    }

    private var notesField: some View {
        TextField("Notes", text: editable(\.notes), prompt: Text("Notes"), axis: .vertical)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1...8)
            .focused(focus, equals: .row(rowID, .notes))
            .accessibilityLabel("Notes")
    }

    private var details: some View {
        HStack(spacing: 4) {
            DueDateControl(session: session, isPresented: presented(.date))
                .focused(focus, equals: .row(rowID, .date))
            if session.hasDue {
                DueTimeControl(session: session, isPresented: presented(.time))
                    .focused(focus, equals: .row(rowID, .time))
            }

            Picker("List", selection: $session.listID) {
                ForEach(lists) { list in
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
            .focused(focus, equals: .row(rowID, .list))
            .accessibilityLabel("List")
            .help("List")

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private func presented(_ field: ReminderRowField) -> Binding<Bool> {
        let key = RowPopover(rowID: rowID, field: field)
        return Binding(
            get: { popover == key },
            set: { shown in
                if shown {
                    popover = key
                } else if popover == key {
                    popover = nil
                }
            }
        )
    }
}
