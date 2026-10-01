import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsPane(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }

            switch state.mode {
            case .remote:
                ConnectionSettingsPane(state: state)
                    .tabItem { Label("Connection", systemImage: "link") }
                NotificationSettingsPane(state: state)
                    .tabItem { Label("Notifications", systemImage: "bell.badge") }
            case .bridge:
                BridgeSettingsPane(state: state)
                    .tabItem { Label("Bridge", systemImage: "antenna.radiowaves.left.and.right") }
            case nil:
                EmptyView()
            }

            AdvancedSettingsPane(state: state)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 540)
    }
}

/// Sizes each pane to its content, as standard Settings windows do.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable var state: AppState
    @State private var loginItem: LoginItemModel

    init(state: AppState) {
        self.state = state
        _loginItem = State(initialValue: LoginItemModel(isDemo: state.isDemo))
    }
    @State private var updates = UpdateManager.shared
    @AppStorage(AppPreferences.showsQuickEntryInMenuBar) private var showsQuickEntry = true
    @AppStorage(AppPreferences.showsBridgeStatusInMenuBar) private var showsBridgeStatus = true
    @AppStorage(AppPreferences.quickEntryHotKeyEnabled) private var hotKeyEnabled = false

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .disabled(loginItem.isUpdating)
                if loginItem.requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    } label: {
                        Text("Allow Task Ferry in System Settings to finish.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = loginItem.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            if state.mode == .remote {
                Section("Quick Entry") {
                    Toggle("Show Quick Reminder in the menu bar", isOn: $showsQuickEntry)
                    Toggle("Open Quick Entry with \(GlobalHotKey.displayString)", isOn: $hotKeyEnabled)
                        .onChange(of: hotKeyEnabled) { _, _ in
                            GlobalHotKey.shared.applyPreference()
                        }
                    Text(state.isDemo ? "Demo mode does not register a system shortcut or Services provider." : "Quick Entry is also in the Services menu of other apps, as New Task Ferry Reminder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state.mode == .bridge {
                Section("Menu Bar") {
                    Toggle("Show bridge status in the menu bar", isOn: $showsBridgeStatus)
                        .disabled(state.runsInBackground)
                    if state.runsInBackground {
                        Text("Always shown while the bridge runs in the background, since it has no Dock icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Dock") {
                Toggle("Show reminder count on the Dock icon", isOn: Binding(
                    get: { state.showsDockBadge },
                    set: { state.setShowsDockBadge($0) }
                ))
                Picker("Count", selection: Binding(
                    get: { state.dockBadgeScope },
                    set: { state.setDockBadgeScope($0) }
                )) {
                    ForEach(DockBadgeScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .disabled(!state.showsDockBadge)
            }

            if UpdateManager.isSupported {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                    Toggle("Download and install updates automatically", isOn: $updates.automaticallyDownloadsUpdates)
                        .disabled(!updates.automaticallyChecksForUpdates)
                    LabeledContent {
                        Button("Check Now") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates && updates.hasStarted)
                    } label: {
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.reload()
        }
    }
}

/// Mirrors `SMAppService.mainApp`, including the case where macOS is waiting for approval.
@MainActor
@Observable
private final class LoginItemModel {
    private(set) var status = SMAppService.Status.notRegistered
    private(set) var isUpdating = false
    private(set) var message: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    private let isDemo: Bool

    init(isDemo: Bool) {
        self.isDemo = isDemo
        reload()
    }

    func reload() {
        guard !isDemo else { return }
        Task {
            let status = await Task.detached(priority: .utility) { SMAppService.mainApp.status }.value
            if !isUpdating { self.status = status }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if isDemo {
            status = enabled ? .enabled : .notRegistered
            message = String(localized: "Demo only. Login registration was not changed.")
            return
        }
        isUpdating = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (SMAppService.Status, String?) in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return (SMAppService.mainApp.status, nil)
                } catch {
                    return (SMAppService.mainApp.status, error.localizedDescription)
                }
            }.value
            status = result.0
            message = result.1
            isUpdating = false
        }
    }
}

// MARK: - Connection (remote)

private struct ConnectionSettingsPane: View {
    @Bindable var state: AppState
    @State private var connectionCode = ""
    @State private var connectionCodeRevealed = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var connectionTestMessage: String?
    @State private var keepsOfflineCopy = true

    var body: some View {
        SettingsPane {
            Section {
                LabeledContent("Bridge") {
                    Text(state.endpoint.isEmpty ? String(localized: "Not connected") : state.endpoint)
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    Text(status)
                }
                if !state.endpoint.isEmpty {
                    Button(isWorking ? "Testing…" : "Test Connection") {
                        Task { await testCurrentConnection() }
                    }
                    .disabled(isWorking)
                }
                if let connectionTestMessage { Text(connectionTestMessage).font(.callout) }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection code")
                    HStack {
                        Group {
                            if connectionCodeRevealed {
                                TextField("TASKFERRY1:…", text: $connectionCode)
                            } else {
                                SecureField("TASKFERRY1:…", text: $connectionCode)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel("Connection code")
                        Button {
                            connectionCodeRevealed.toggle()
                        } label: {
                            Image(systemName: connectionCodeRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(connectionCodeRevealed ? "Hide connection code" : "Show connection code")
                        .help(connectionCodeRevealed ? "Hide connection code" : "Show connection code")
                    }
                }
                .disabled(isWorking)
                HStack {
                    Button("Paste") { pasteConnectionCode() }
                        .disabled(isWorking)
                    Spacer()
                    Button(isWorking ? "Connecting…" : "Connect") {
                        Task { await saveConnectionCodeAndTest() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || connectionCode.trimmed.isEmpty)
                }
                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(state.endpoint.isEmpty ? "Connect" : "Replace Connection")
            } footer: {
                Text("Copy the code on the bridge Mac with Copy Connection Code. It contains passwords, so send it securely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep a copy for instant launch", isOn: $keepsOfflineCopy)
                    .onChange(of: keepsOfflineCopy) { _, enabled in
                        state.setKeepsOfflineCopy(enabled)
                    }
            } footer: {
                Text("Task Ferry shows your last-synced reminders the moment it opens, then refreshes them. The copy stays in this Mac’s Caches folder and is only readable by you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }


        }
        .onAppear { keepsOfflineCopy = state.keepsOfflineCopy }
    }

    private var status: String {
        if state.isOffline { return String(localized: "Offline — retrying") }
        switch state.connectionState {
        case .connected: return String(localized: "Connected")
        case .loading: return String(localized: "Connecting…")
        case .failed: return state.errorMessage ?? String(localized: "Needs attention")
        case .idle: return state.endpoint.isEmpty ? String(localized: "Not set up") : String(localized: "Waiting")
        }
    }

    private func saveConnectionCodeAndTest() async {
        guard !isWorking else { return }
        isWorking = true
        messageIsError = false
        defer { isWorking = false }
        do {
            try await state.saveConnectionCode(connectionCode)
            connectionCode = ""
            connectionCodeRevealed = false
            if await state.refresh() {
                message = state.isDemo ? String(localized: "Demo connection ready. Nothing was saved to Keychain.") : String(localized: "Connected. The connection is stored in your keychain.")
            } else {
                messageIsError = true
                message = String(localized: "Saved, but the bridge didn’t answer: \(state.errorMessage ?? String(localized: "Unknown error"))")
            }
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }

    private func pasteConnectionCode() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            messageIsError = true
            message = String(localized: "The clipboard is empty.")
            return
        }
        do {
            _ = try TaskFerryConnectionCode.decode(value)
            connectionCode = value.trimmed
            message = nil
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }

    private func testCurrentConnection() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        connectionTestMessage = await state.refresh()
            ? String(localized: "The bridge answered.")
            : state.errorMessage ?? String(localized: "The bridge didn’t answer.")
    }
}

// MARK: - Bridge

private struct BridgeSettingsPane: View {
    private enum CloudflareSheet: Identifiable {
        case setup
        case remove(CloudflareProvisioning)
        case cleanup

        var id: String {
            switch self {
            case .setup: "setup"
            case .remove: "remove"
            case .cleanup: "cleanup"
            }
        }
    }

    @Bindable var state: AppState
    @State private var tokenRevealed = false
    @State private var isGenerating = false
    @State private var confirmingRegenerate = false
    @State private var message: String?
    @State private var cloudflareSheet: CloudflareSheet?

    var body: some View {
        SettingsPane {
            Section("Remote Access") {
                if let hostname = state.cloudflareHostname {
                    LabeledContent("Address", value: hostname)
                    LabeledContent("Cloudflare") {
                        Text(BridgeStatusText.connector(state.cloudflareConnectorState, hostname: nil))
                    }
                    HStack {
                        Button("Copy Connection Code", action: copyConnectionCode)
                        Spacer()
                        Button("Remove Cloudflare Setup…", role: .destructive) {
                            if let provisioning = state.cloudflareProvisioning {
                                cloudflareSheet = .remove(provisioning)
                            }
                        }
                    }
                } else {
                    Text("Let Task Ferry create a tunnel, DNS record, and protected Access connection in your own Cloudflare account.")
                        .foregroundStyle(.secondary)
                    Button("Set Up with Cloudflare…") {
                        cloudflareSheet = .setup
                    }
                }
            }

            if !state.pendingCloudflareCleanups.isEmpty {
                Section("Unfinished Cleanup") {
                    Text("Some resources from a previous setup still need to be removed.")
                        .foregroundStyle(.secondary)
                    ForEach(state.pendingCloudflareCleanups) { cleanup in
                        Text(cleanup.hostname).textSelection(.enabled)
                    }
                    Button("Retry Cleanup…") { cloudflareSheet = .cleanup }
                }
            }

            Section {
                LabeledContent("Local address", value: "127.0.0.1:\(String(state.port))")
                HStack {
                    Text("Bridge token")
                    Spacer()
                    HStack {
                        Text(tokenRevealed ? state.bridgeToken : String(repeating: "•", count: 12))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Button {
                            tokenRevealed.toggle()
                        } label: {
                            Image(systemName: tokenRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(tokenRevealed ? "Hide bridge token" : "Show bridge token")
                        .help(tokenRevealed ? "Hide bridge token" : "Show bridge token")
                    }
                }
                Button(isGenerating ? "Generating…" : "Generate New Token…") {
                    confirmingRegenerate = true
                }
                .disabled(isGenerating)
            } header: {
                Text("Bridge")
            } footer: {
                Text("The token is part of the connection code. A new token disconnects every remote Mac until it gets a new code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Run in the background", isOn: Binding(
                    get: { state.runsInBackground },
                    set: { state.setRunsInBackground($0) }
                ))
            } footer: {
                Text("Hides the Dock icon while the bridge keeps running. Use the menu bar item to open Task Ferry or quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Generate a new bridge token?",
            isPresented: $confirmingRegenerate
        ) {
            Button("Generate New Token", role: .destructive, action: regenerateToken)
        } message: {
            Text("Remote Macs stop syncing until you copy the new connection code to them.")
        }
        .sheet(item: $cloudflareSheet) { sheet in
            switch sheet {
            case .setup:
                CloudflareSetupView(state: state, purpose: .create)
            case .remove(let provisioning):
                CloudflareSetupView(state: state, purpose: .remove(provisioning))
            case .cleanup:
                CloudflareSetupView(state: state, purpose: .cleanup)
            }
        }
    }

    private func regenerateToken() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            do {
                _ = try await state.regenerateBridgeToken()
                message = state.cloudflareProvisioning == nil
                    ? String(localized: "New token ready.")
                    : String(localized: "New token ready. Copy the connection code again for each remote Mac.")
            } catch {
                message = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func copyConnectionCode() {
        do {
            Pasteboard.copySecret(try state.connectionCode())
            message = String(localized: "Connection code copied. It contains passwords, so share it securely.")
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Notifications (remote)

private struct NotificationSettingsPane: View {
    @Bindable var state: AppState
    @AppStorage(AppPreferences.notifiesWhenDue) private var notifiesWhenDue = false
    @AppStorage(AppPreferences.dateOnlyNotificationHour) private var dateOnlyHour = 9
    @State private var message: String?

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Alert me when reminders are due", isOn: Binding(
                    get: { notifiesWhenDue },
                    set: { enabled in
                        Task {
                            let granted = await ReminderNotificationScheduler.shared.setEnabled(enabled)
                            notifiesWhenDue = enabled && granted
                            message = enabled && !granted
                                ? String(localized: "Allow notifications for Task Ferry in System Settings → Notifications.")
                                : nil
                        }
                    }
                ))
                Picker("Reminders without a time", selection: $dateOnlyHour) {
                    ForEach(5..<23, id: \.self) { hour in
                        Text(Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: 0, second: 0, of: Date())?
                            .formatted(date: .omitted, time: .shortened) ?? "\(hour)")
                            .tag(hour)
                    }
                }
                .disabled(!notifiesWhenDue)
                .onChange(of: dateOnlyHour) { _, hour in
                    ReminderNotificationScheduler.shared.setDateOnlyHour(hour)
                }
            } footer: {
                Text(state.isDemo ? "Demo only. No notification permission is requested and no alerts are scheduled." : "Get alerts on this Mac for reminders from your bridge. Task Ferry schedules the next two weeks, with Complete, Remind Me in 1 Hour, and Move to Tomorrow actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsPane: View {
    @Bindable var state: AppState
    @State private var confirmingRoleChange = false

    var body: some View {
        SettingsPane {
            Section {
                LabeledContent("This Mac") {
                    Text(roleTitle)
                }
                Button("Choose a Different Role…") {
                    confirmingRoleChange = true
                }
                .disabled(state.mode == nil)
            } footer: {
                Text(roleFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Change this Mac’s role?", isPresented: $confirmingRoleChange) {
            Button("Change Role", role: .destructive) {
                state.resetMode()
                WindowRouter.shared.showMainWindow()
            }
        } message: {
            Text(roleFootnote)
        }
    }

    private var roleTitle: String {
        switch state.mode {
        case .bridge: String(localized: "Reminders bridge")
        case .remote: String(localized: "Remote client")
        case nil: String(localized: "Not configured")
        }
    }

    private var roleFootnote: String {
        switch state.mode {
        case .remote:
            String(localized: "This Mac will forget its connection code and cached reminders. Your reminders stay on the bridge.")
        case .bridge:
            String(localized: "The bridge stops, so remote Macs can’t sync. Its Keychain items and Cloudflare setup are kept, so choosing the bridge role again restores it.")
        case nil:
            String(localized: "Choose a role in the Task Ferry window.")
        }
    }
}
