import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var connectionCode = ""
    @State private var connectionCodeRevealed = false
    @State private var bridgeTokenRevealed = false
    @State private var launchAtLogin = false
    @State private var launchAtLoginLoaded = false
    @State private var launchAtLoginUpdating = false
    @State private var connectionSaving = false
    @State private var tokenGenerating = false
    @State private var message: String?
    @State private var cloudflareSheet: CloudflareSheet?

    private enum CloudflareSheet: Identifiable {
        case setup
        case remove(CloudflareProvisioning)

        var id: String {
            switch self {
            case .setup: "setup"
            case .remove: "remove"
            }
        }
    }

    var body: some View {
        Form {
            Section("Role") {
                LabeledContent("This Mac") {
                    Text(state.mode == .bridge ? "Reminders bridge" : state.mode == .remote ? "Remote client" : "Not configured")
                }
                Button("Choose a Different Role…") {
                    state.resetMode()
                    NSApplication.shared.keyWindow?.close()
                }
            }

            if state.mode == .remote {
                Section("Connection") {
                    if !state.endpoint.isEmpty {
                        LabeledContent("Current server", value: state.endpoint)
                    }
                    LabeledContent("Connection code") {
                        HStack {
                            if connectionCodeRevealed {
                                TextField("TASKFERRY1:…", text: $connectionCode)
                            } else {
                                SecureField("TASKFERRY1:…", text: $connectionCode)
                            }
                            Button {
                                connectionCodeRevealed.toggle()
                            } label: {
                                Image(systemName: connectionCodeRevealed ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(connectionCodeRevealed ? "Hide connection code" : "Show connection code")
                        }
                    }
                    .disabled(connectionSaving)
                    Text("Paste the connection code copied from the bridge Mac. It includes the server and all required credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Paste from Clipboard") {
                            pasteConnectionCode()
                        }
                        .disabled(connectionSaving)
                        Button(connectionSaving ? "Saving…" : "Save & Test") {
                            Task { await saveConnectionCodeAndTest() }
                        }
                        .disabled(connectionSaving || connectionCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !state.endpoint.isEmpty {
                            Button("Test Current Connection") {
                                Task { await testCurrentConnection() }
                            }
                            .disabled(connectionSaving)
                        }
                    }
                }
            } else if state.mode == .bridge {
                Section("Bridge") {
                    LabeledContent("Local address", value: "127.0.0.1:\(state.port)")
                    HStack {
                        Text("Bridge token")
                        Spacer()
                        Button(bridgeTokenRevealed ? "Hide" : "Show") {
                            bridgeTokenRevealed.toggle()
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.bridgeToken, forType: .string)
                            message = "Bridge token copied."
                        }
                    }
                    if bridgeTokenRevealed {
                        Text(state.bridgeToken)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("New tokens use six short, unambiguous groups for easier typing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(tokenGenerating ? "Generating…" : "Generate New Token") {
                        guard !tokenGenerating else { return }
                        tokenGenerating = true
                        Task {
                            do {
                                _ = try await state.regenerateBridgeToken()
                                message = "A new easy-to-type bridge token is ready."
                            } catch {
                                message = error.localizedDescription
                            }
                            tokenGenerating = false
                        }
                    }
                    .disabled(tokenGenerating)
                }

                Section("Remote Access") {
                    if let hostname = state.cloudflareHostname {
                        LabeledContent("Public address", value: hostname)
                        LabeledContent("Cloudflare connector", value: connectorDetail)
                        HStack {
                            Button("Copy Connection Code") {
                                copyConnectionCode()
                            }
                            Button("Remove Cloudflare Setup…", role: .destructive) {
                                guard let provisioning = state.cloudflareProvisioning else { return }
                                cloudflareSheet = .remove(provisioning)
                            }
                        }
                        Text("The connection code contains passwords. Share it only with the Mac that will connect to this bridge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Let Task Ferry create a tunnel, DNS record, and protected Access connection in your own Cloudflare account.")
                            .foregroundStyle(.secondary)
                        Button("Set Up with Cloudflare…") {
                            cloudflareSheet = .setup
                        }
                    }
                }

                Section("Background") {
                    Toggle("Run in Background", isOn: runsInBackgroundBinding)
                    Text("Hides the Dock icon while the bridge keeps running. Open Task Ferry again from Applications whenever you need its window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sync") {
                Button("Refresh Reminders") {
                    Task { await state.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Text(state.mode == .remote
                    ? "Task Ferry also checks automatically every 15 seconds and whenever the app becomes active."
                    : "Reminders access and data are checked automatically when the bridge starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Show reminder count on Dock icon", isOn: showsDockBadgeBinding)
                Picker("Include", selection: dockBadgeScopeBinding) {
                    ForEach(DockBadgeScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .disabled(!state.showsDockBadge)
                Text("The badge updates whenever Task Ferry syncs. It does not require notification permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .disabled(!launchAtLoginLoaded || launchAtLoginUpdating)
                if UpdateManager.isSupported {
                    Button("Check for Updates…") {
                        UpdateManager.checkForUpdates()
                    }
                    .disabled(!UpdateManager.canCheckForUpdates)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 540)
        .navigationTitle("Task Ferry")
        .sheet(item: $cloudflareSheet) { sheet in
            switch sheet {
            case .setup:
                CloudflareSetupView(state: state, purpose: .create)
            case .remove(let provisioning):
                CloudflareSetupView(state: state, purpose: .remove(provisioning))
            }
        }
        .task {
            let currentLaunchAtLogin = await Task.detached(priority: .utility) {
                SMAppService.mainApp.status == .enabled
            }.value
            if !launchAtLoginUpdating {
                launchAtLogin = currentLaunchAtLogin
            }
            launchAtLoginLoaded = true
        }
    }

    private func saveConnectionCodeAndTest() async {
        guard !connectionSaving else { return }
        connectionSaving = true
        defer { connectionSaving = false }
        do {
            try await state.saveConnectionCode(connectionCode)
            connectionCode = ""
            connectionCodeRevealed = false
            if await state.refresh() {
                message = "Connection saved securely and tested."
            } else {
                message = "Connection saved, but the test failed: \(state.errorMessage ?? "Unknown error")"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func pasteConnectionCode() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            message = "The clipboard is empty."
            return
        }
        do {
            _ = try TaskFerryConnectionCode.decode(value)
            connectionCode = value.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "Connection code pasted. Choose Save & Test to finish."
        } catch {
            message = error.localizedDescription
        }
    }

    private func testCurrentConnection() async {
        guard !connectionSaving else { return }
        connectionSaving = true
        defer { connectionSaving = false }
        if await state.refresh() {
            message = "Connection test succeeded."
        } else {
            message = state.errorMessage ?? "Connection test failed."
        }
    }

    private func copyConnectionCode() {
        do {
            let code = try state.connectionCode()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            message = "Connection code copied. It contains passwords, so share it securely."
        } catch {
            message = error.localizedDescription
        }
    }

    private var connectorDetail: String {
        switch state.cloudflareConnectorState {
        case .notConfigured: "Not configured"
        case .stopped: "Stopped"
        case .starting: "Connecting…"
        case .connected: "Connected"
        case .failed(let message): message
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                launchAtLogin = enabled
                launchAtLoginUpdating = true
                Task { await updateLaunchAtLogin(enabled) }
            }
        )
    }

    private var runsInBackgroundBinding: Binding<Bool> {
        Binding(
            get: { state.runsInBackground },
            set: { state.setRunsInBackground($0) }
        )
    }

    private var showsDockBadgeBinding: Binding<Bool> {
        Binding(
            get: { state.showsDockBadge },
            set: { state.setShowsDockBadge($0) }
        )
    }

    private var dockBadgeScopeBinding: Binding<DockBadgeScope> {
        Binding(
            get: { state.dockBadgeScope },
            set: { state.setDockBadgeScope($0) }
        )
    }

    private func updateLaunchAtLogin(_ enabled: Bool) async {
        let result = await Task.detached(priority: .userInitiated) {
            var errorMessage: String?
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return (SMAppService.mainApp.status == .enabled, errorMessage)
        }.value

        launchAtLogin = result.0
        launchAtLoginUpdating = false
        if let errorMessage = result.1 {
            message = errorMessage
        }
    }
}
