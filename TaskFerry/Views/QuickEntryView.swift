import AppKit
import SwiftUI

struct QuickEntryView: View {
    enum Style {
        /// The menu bar popover, which stays open for rapid entry.
        case menuBar
        /// The floating panel from the global shortcut, Services, or a URL, which closes once added.
        case panel
    }

    @Bindable var state: AppState
    var style: Style = .menuBar
    var initialTitle = ""
    var initialNotes: String? = nil
    var initialListID: String? = nil
    var initialDue: QuickDueOption = .today
    var onFinish: (() -> Void)? = nil
    /// Told about each change, so a draft survives the panel closing when you click elsewhere.
    var onDraftChange: ((_ title: String, _ notes: String, _ listID: String, _ due: QuickDueOption) -> Void)? = nil
    /// The panel has to stay put while a reminder is on its way.
    var onSubmittingChange: ((Bool) -> Void)? = nil

    @State private var title = ""
    @State private var notes = ""
    @State private var listID = ""
    @State private var due = QuickDueOption.today
    @State private var isSubmitting = false
    @State private var confirmation: String?
    /// The window shows sync errors in its own banner, so only say why this reminder failed.
    @State private var addError: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch style {
            case .panel: panel
            case .menuBar: menuBar
            }
        }
        .onExitCommand(perform: close)
        .task {
            if title.isEmpty, !initialTitle.isEmpty {
                title = initialTitle
            }
            if notes.isEmpty, let initialNotes {
                notes = initialNotes
            }
            due = initialDue
            if let initialListID {
                listID = initialListID
            }
            selectDefaultListIfNeeded()
            titleFocused = true
            await state.refresh(showLoadingIndicator: !state.hasSnapshotToShow)
            selectDefaultListIfNeeded()
        }
        .onChange(of: state.snapshot.lists) { _, _ in selectDefaultListIfNeeded() }
        .onChange(of: title) { reportDraft() }
        .onChange(of: notes) { reportDraft() }
        .onChange(of: listID) { reportDraft() }
        .onChange(of: due) { reportDraft() }
        .onChange(of: isSubmitting) { _, isSubmitting in onSubmittingChange?(isSubmitting) }
        .onChange(of: state.preferredNewReminderListID) { _, _ in
            if initialListID == nil { listID = state.newReminderListID ?? "" }
        }
    }

    /// Like Spotlight: one large field on glass, with the list and due date in a row beneath it.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let unavailable {
                unavailable
            } else {
                TextField("New Reminder", text: $title, prompt: Text("New Reminder"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit(addReminder)
                    .disabled(isSubmitting)
                    .accessibilityLabel("Reminder title")

                if showsNotes {
                    notesField
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    listPicker
                        .labelsHidden()
                        .fixedSize()
                    duePicker
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    Spacer(minLength: 8)
                    addButton
                }
                .controlSize(.small)
            }
            errorText
        }
        .padding(18)
        .frame(width: 520)
        .glassEffect(in: .rect(cornerRadius: 20))
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Quick Entry", systemImage: "plus.circle.fill")
                .font(.headline)

            if let unavailable {
                unavailable
            } else {
                TextField("What needs doing?", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit(addReminder)
                    .disabled(isSubmitting)

                if showsNotes {
                    notesField
                        .textFieldStyle(.roundedBorder)
                }

                listPicker
                duePicker
                    .pickerStyle(.segmented)

                HStack {
                    if let confirmation {
                        Label(confirmation, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Spacer()
                    addButton
                }
            }

            errorText

            Divider()
            HStack(spacing: 14) {
                Button("Open Task Ferry", action: openMainWindow)
                // Not SettingsLink: clicking the menu bar doesn't activate Task Ferry, and Settings
                // would open behind the app in front.
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
    }

    /// Shown instead of the form until there's somewhere to add a reminder.
    private var unavailable: AnyView? {
        if state.mode != .remote || (state.endpoint.isEmpty && state.snapshot.lists.isEmpty) {
            return AnyView(VStack(alignment: .leading, spacing: 10) {
                Text("Connect this Mac to your bridge first.")
                    .foregroundStyle(.secondary)
                Button("Open Task Ferry", action: openMainWindow)
            })
        }
        if state.snapshot.lists.isEmpty {
            return AnyView(ProgressView("Loading lists…")
                .frame(maxWidth: .infinity, minHeight: 80))
        }
        return nil
    }

    /// Text from the Services menu or a URL puts everything after the first line in the notes,
    /// so it has to be visible before it's sent.
    private var showsNotes: Bool { initialNotes != nil || !notes.isEmpty }

    private var notesField: some View {
        TextField("Notes", text: $notes, prompt: Text("Notes"), axis: .vertical)
            .labelsHidden()
            .lineLimit(1...4)
            .disabled(isSubmitting)
            .accessibilityLabel("Notes")
    }

    private var listPicker: some View {
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
        .disabled(isSubmitting)
    }

    private var duePicker: some View {
        Picker("Due", selection: $due) {
            ForEach(QuickDueOption.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .disabled(isSubmitting)
    }

    private var addButton: some View {
        Button(isSubmitting ? "Adding…" : "Add Reminder", action: addReminder)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSubmitting || title.trimmed.isEmpty || listID.isEmpty)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = addError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    /// Esc closes either style. The menu bar's window is dismissed the way clicking elsewhere
    /// would, so the menu bar item knows it's closed.
    private func close() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }

    private func addReminder() {
        let reminderTitle = title.trimmed
        guard !reminderTitle.isEmpty, !listID.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        addError = nil
        let listTitle = state.list(for: listID)?.title ?? ""
        Task {
            let outcome = await state.createReminder(
                title: reminderTitle,
                listID: listID,
                due: due.due(),
                notes: notes.trimmed.isEmpty ? nil : notes
            )
            isSubmitting = false
            onSubmittingChange?(false)
            guard outcome.succeeded else {
                addError = state.errorMessage
                titleFocused = true
                return
            }
            title = ""
            notes = ""
            let message = String(localized: "Added to \(listTitle)")
            AccessibilityNotification.Announcement(message).post()
            if style == .panel {
                onFinish?()
            } else {
                withAnimation(reduceMotion ? nil : .default) { confirmation = message }
                titleFocused = true
                try? await Task.sleep(for: .seconds(2))
                withAnimation(reduceMotion ? nil : .default) { confirmation = nil }
            }
        }
    }

    private func reportDraft() {
        onDraftChange?(title, notes, listID, due)
    }

    private func openMainWindow() {
        onFinish?()
        WindowRouter.shared.showMainWindow()
    }

    private func selectDefaultListIfNeeded() {
        guard !state.snapshot.lists.contains(where: { $0.id == listID }) else { return }
        listID = state.newReminderListID ?? ""
    }

}
