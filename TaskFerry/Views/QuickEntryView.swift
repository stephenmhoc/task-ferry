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

    @State private var title = ""
    @State private var listID = ""
    @State private var due = QuickDueOption.today
    @State private var isSubmitting = false
    @State private var confirmation: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Quick Reminder", systemImage: "plus.circle.fill")
                .font(.headline)

            if state.mode != .remote || (state.endpoint.isEmpty && state.snapshot.lists.isEmpty) {
                Text("Connect this Mac to your bridge first.")
                    .foregroundStyle(.secondary)
                Button("Open Task Ferry", action: openMainWindow)
            } else if state.snapshot.lists.isEmpty {
                ProgressView("Loading lists…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                TextField("What needs doing?", text: $title, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit(addReminder)
                    .disabled(isSubmitting)

                Picker("List", selection: listSelection) {
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

                Picker("Due", selection: $due) {
                    ForEach(QuickDueOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isSubmitting)

                HStack {
                    if let confirmation {
                        Label(confirmation, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button(isSubmitting ? "Adding…" : "Add Reminder", action: addReminder)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSubmitting || title.trimmed.isEmpty || listID.isEmpty)
                }
            }

            if let error = state.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if style == .menuBar {
                Divider()
                HStack(spacing: 14) {
                    Button("Open Task Ferry", action: openMainWindow)
                    SettingsLink {
                        Text("Settings…")
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
        .padding(16)
        .frame(width: style == .panel ? 420 : 340)
        .onExitCommand { onFinish?() }
        .task {
            if title.isEmpty, !initialTitle.isEmpty {
                title = initialTitle
            }
            due = initialDue
            if let initialListID {
                listID = initialListID
            }
            selectDefaultListIfNeeded()
            titleFocused = true
            await state.refresh(showLoadingIndicator: !state.hasLoadedSnapshot && !state.isShowingCachedSnapshot)
            selectDefaultListIfNeeded()
        }
        .onChange(of: state.snapshot.lists) { _, _ in selectDefaultListIfNeeded() }
        .onChange(of: state.preferredNewReminderListID) { _, _ in
            if initialListID == nil { listID = state.newReminderListID ?? "" }
        }
    }

    private func addReminder() {
        let reminderTitle = title.trimmed
        guard !reminderTitle.isEmpty, !listID.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        let listTitle = state.list(for: listID)?.title ?? ""
        Task {
            let outcome = await state.createReminder(
                title: reminderTitle,
                listID: listID,
                due: due.due(),
                notes: initialNotes
            )
            isSubmitting = false
            guard outcome.succeeded else {
                titleFocused = true
                return
            }
            title = ""
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

    private func openMainWindow() {
        onFinish?()
        WindowRouter.shared.showMainWindow()
    }

    private func selectDefaultListIfNeeded() {
        guard !state.snapshot.lists.contains(where: { $0.id == listID }) else { return }
        listID = state.newReminderListID ?? ""
    }

    private var listSelection: Binding<String> {
        Binding(
            get: { listID },
            set: {
                listID = $0
                state.rememberNewReminderList($0)
            }
        )
    }
}
