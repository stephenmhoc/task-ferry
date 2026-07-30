import AppKit
import SwiftUI

struct MenuRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var state: AppState

    var body: some View {
        NavigationStack {
            Group {
                switch state.mode {
                case nil:
                    SetupView(state: state)
                case .bridge:
                    BridgeView(state: state)
                case .remote:
                    RemindersView(state: state)
                }
            }
            .frame(minWidth: 400, minHeight: 540)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowMinimumSize(width: 400, height: 540))
        .task {
            await state.start()
            state.applyActivationPolicy()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, state.mode != nil else { return }
            Task { await state.refresh(showLoadingIndicator: false) }
        }
        .onChange(of: state.dockBadgeCount, initial: true) { _, count in
            DockBadgeManager.update(count: count)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.stopCloudflareConnector()
        }
    }
}

private struct WindowMinimumSize: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> MinimumSizeHostingView {
        MinimumSizeHostingView(contentSize: NSSize(width: width, height: height))
    }

    func updateNSView(_ view: MinimumSizeHostingView, context: Context) {
        view.contentSize = NSSize(width: width, height: height)
        view.applyMinimumSize()
    }
}

private final class MinimumSizeHostingView: NSView {
    var contentSize: NSSize

    init(contentSize: NSSize) {
        self.contentSize = contentSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMinimumSize()
    }

    func applyMinimumSize() {
        guard let window else { return }
        window.contentMinSize = contentSize
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
            .size
        window.minSize = frameSize
    }
}

private struct SetupView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Reminders, within reach")
                    .font(.title.weight(.semibold))
                Text("Choose the role for this Mac. You can change it later in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            List {
                Section("This Mac should") {
                    modeButton(
                        title: "Connect to my Mac mini",
                        subtitle: "View and manage tasks from anywhere",
                        symbol: "laptopcomputer.and.iphone",
                        mode: .remote
                    )
                    modeButton(
                        title: "Share its reminders",
                        subtitle: "Run the private bridge on this Mac",
                        symbol: "antenna.radiowaves.left.and.right",
                        mode: .bridge
                    )
                }
            }
            .listStyle(.inset)
        }
    }

    private func modeButton(title: String, subtitle: String, symbol: String, mode: AppMode) -> some View {
        Button {
            Task { await state.chooseMode(mode) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(subtitle)
    }
}

private struct BridgeView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 46, height: 46)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            List {
                Section("Status") {
                    statusRow(
                        symbol: "lock.shield",
                        title: "Private listener",
                        detail: "127.0.0.1 only",
                        ready: isRunning
                    )
                    statusRow(
                        symbol: "key",
                        title: "Bridge token",
                        detail: state.bridgeToken.isEmpty ? "Missing" : "Stored in Keychain",
                        ready: !state.bridgeToken.isEmpty
                    )
                    statusRow(
                        symbol: "checklist",
                        title: "Reminders access",
                        detail: remindersDetail,
                        ready: state.connectionState == .connected
                    )
                    statusRow(
                        symbol: "cloud",
                        title: "Remote access",
                        detail: cloudflareDetail,
                        ready: state.cloudflareConnectorState == .connected
                    )
                }
            }
            .listStyle(.inset)

            if let error = state.errorMessage {
                ErrorBanner(message: error) { state.dismissError() }
                    .padding(.horizontal, 24)
            }
        }
        .task { await state.refresh() }
    }

    private var isRunning: Bool {
        if case .running = state.bridgeState { return true }
        return false
    }

    private var title: String {
        switch state.bridgeState {
        case .running: "Bridge is ready"
        case .failed: "Bridge could not start"
        case .starting: "Starting bridge…"
        case .stopped: "Bridge is stopped"
        }
    }

    private var detail: String {
        switch state.bridgeState {
        case .running(let port): "This Mac is listening privately on localhost:\(port)."
        case .failed(let message): message
        case .starting: "Binding the private local listener."
        case .stopped: "Open Settings to configure this Mac."
        }
    }

    private var remindersDetail: String {
        switch state.connectionState {
        case .connected:
            "\(state.snapshot.lists.count) lists · \(state.snapshot.reminders.count) open reminders"
        case .loading:
            "Checking access…"
        case .failed:
            "Access needs attention"
        case .idle:
            "Not checked yet"
        }
    }

    private var cloudflareDetail: String {
        switch state.cloudflareConnectorState {
        case .notConfigured:
            "Not configured"
        case .stopped:
            "Connector stopped"
        case .starting:
            "Connecting to Cloudflare…"
        case .connected:
            state.cloudflareHostname ?? "Connected"
        case .failed(let message):
            message
        }
    }

    private func statusRow(symbol: String, title: String, detail: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct RemindersView: View {
    @Bindable var state: AppState
    @State private var quickTitle = ""
    @State private var quickListID = ""
    @State private var isAddingReminder = false
    @FocusState private var quickAddFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = state.errorMessage {
                ErrorBanner(message: error) { state.dismissError() }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            reminderContent
            QuickAddView(
                title: $quickTitle,
                selectedListID: $quickListID,
                lists: state.snapshot.lists,
                isSubmitting: isAddingReminder,
                focused: $quickAddFocused,
                submit: addReminder
            )
        }
        .task {
            await state.refresh()
            selectDefaultListIfNeeded()
        }
        .onChange(of: state.snapshot.lists) { _, _ in selectDefaultListIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.selectedView.title)
                        .font(.system(size: 27, weight: .semibold))
                    Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NavigationLink {
                    ListsView(state: state)
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Lists")
                .accessibilityLabel("Lists")
            }
            Picker("Day", selection: $state.selectedView) {
                ForEach(SmartView.allCases) { view in
                    Text(view.title).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
    }

    private var selectedDate: Date {
        guard state.selectedView == .tomorrow else { return Date() }
        return Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }

    @ViewBuilder
    private var reminderContent: some View {
        if state.connectionState == .loading && state.snapshot.reminders.isEmpty {
            Spacer()
            ProgressView("Loading reminders…")
            Spacer()
        } else if state.visibleReminders.isEmpty {
            Spacer()
            ContentUnavailableView(
                state.selectedView == .today ? "A clear day" : "Tomorrow is open",
                systemImage: "checkmark.circle",
                description: Text("Add a reminder below when something comes up.")
            )
            Spacer()
        } else {
            List {
                ForEach(state.visibleReminders) { reminder in
                    ReminderRow(state: state, reminder: reminder, context: .day)
                }
            }
            .listStyle(.inset)
        }
    }

    private func addReminder() {
        let title = quickTitle.trimmed
        guard !title.isEmpty, !quickListID.isEmpty, !isAddingReminder else { return }
        let calendar = Calendar.autoupdatingCurrent
        let day = state.selectedView == .today
            ? Date()
            : (calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        isAddingReminder = true
        Task {
            let succeeded = await state.createReminder(
                title: title,
                listID: quickListID,
                due: ReminderDue(date: day, includesTime: false)
            )
            if succeeded {
                quickTitle = ""
            }
            isAddingReminder = false
            quickAddFocused = true
        }
    }

    private func selectDefaultListIfNeeded() {
        guard !state.snapshot.lists.contains(where: { $0.id == quickListID }) else { return }
        quickListID = state.defaultListID ?? ""
    }
}

private struct QuickAddView: View {
    @Binding var title: String
    @Binding var selectedListID: String
    let lists: [ReminderListRecord]
    let isSubmitting: Bool
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(lists) { list in
                    Button(list.title) { selectedListID = list.id }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(selectedListColor)
                        .frame(width: 7, height: 7)
                    Text(selectedListTitle)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose list")
            .disabled(isSubmitting)

            TextField("New reminder", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .onSubmit(submit)
                .accessibilityHint("Press Return to add the reminder")
                .disabled(isSubmitting)

            Button(action: submit) {
                Image(systemName: isSubmitting ? "clock" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(title.trimmed.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || title.trimmed.isEmpty || selectedListID.isEmpty)
            .accessibilityLabel("Add reminder")
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectedListTitle: String {
        lists.first { $0.id == selectedListID }?.title ?? "List"
    }

    private var selectedListColor: Color {
        Color(hex: lists.first { $0.id == selectedListID }?.colorHex ?? "5E5CE6")
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
