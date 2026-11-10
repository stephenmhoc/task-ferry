import AppKit
import SwiftUI

enum WorkspaceSize {
    static let width: CGFloat = 920
    static let height: CGFloat = 640
    /// The sidebar's 220 and the reminder column's 380, with room for its toolbar.
    static let minWidth: CGFloat = 620

    @MainActor static func apply() {
        guard let window = NSApp.keyWindow, window.frame.width < width else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

struct MenuRootView: View {
    @Bindable var state: AppState

    var body: some View {
        Group {
            switch state.mode {
            case nil:
                SetupView(state: state)
                    .frame(minWidth: 420, minHeight: 440)
            case .bridge:
                BridgeView(state: state)
                    .frame(minWidth: 420, minHeight: 480)
            case .remote:
                RemindersWorkspaceView(state: state)
                    .frame(minWidth: WorkspaceSize.minWidth, minHeight: 420)
            }
        }
        .background(MainWindowRegistrar())
        .onChange(of: state.mode) { previous, mode in
            // The window opened at the small setup size, and defaultSize only applies on opening.
            if previous == nil, mode == .remote { WorkspaceSize.apply() }
        }
    }
}

private struct SetupView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "checklist")
                    .font(.largeTitle.weight(.medium))
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

            VStack(spacing: 10) {
                modeButton(
                    title: "Use reminders from another Mac",
                    subtitle: "View and manage them here, from anywhere",
                    symbol: "laptopcomputer",
                    mode: .remote
                )
                modeButton(
                    title: "Share this Mac’s reminders",
                    subtitle: "Run the private bridge here",
                    symbol: "antenna.radiowaves.left.and.right",
                    mode: .bridge
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            Spacer(minLength: 0)
        }
    }

    private func modeButton(title: LocalizedStringKey, subtitle: LocalizedStringKey, symbol: String, mode: AppMode) -> some View {
        Button {
            Task { await state.chooseMode(mode) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .accessibilityHint(subtitle)
    }
}

private struct BridgeView: View {
    @Bindable var state: AppState
    @State private var copiedMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 46, height: 46)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.isDemo ? String(localized: "Demo bridge") : BridgeStatusText.title(for: state.bridgeState)).font(.title2.weight(.semibold))
                    Text(state.isDemo ? String(localized: "In-memory preview. No listener or connector is running.") : BridgeStatusText.detail(for: state.bridgeState)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            List {
                Section("Status") {
                    statusRow(
                        symbol: "lock.shield",
                        title: "Private listener",
                        detail: Text("127.0.0.1 only"),
                        ready: isRunning
                    )
                    statusRow(
                        symbol: "key",
                        title: "Bridge token",
                        detail: Text(state.isDemo ? "Demo token" : (state.bridgeToken.isEmpty ? "Missing" : "Stored in Keychain")),
                        ready: !state.bridgeToken.isEmpty
                    )
                    statusRow(
                        symbol: "checklist",
                        title: "Reminders access",
                        detail: remindersDetail,
                        ready: state.syncStatus == .upToDate
                    ) {
                        if remindersAccessFailed {
                            Button("Open Privacy Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                            }
                        }
                    }
                    statusRow(
                        symbol: "cloud",
                        title: "Remote access",
                        detail: Text(BridgeStatusText.connector(state.cloudflareConnectorState, hostname: state.cloudflareHostname)),
                        ready: state.cloudflareConnectorState == .connected
                    ) {
                        if state.cloudflareProvisioning == nil {
                            SettingsLink { Text("Set Up…") }
                        } else {
                            Button("Copy Connection Code", action: copyConnectionCode)
                        }
                    }
                }
            }
            .listStyle(.inset)

            if let copiedMessage {
                Text(copiedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }

            if let error = state.errorMessage {
                ErrorBanner(message: error) { state.dismissError() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = state.bridgeState { return true }
        return false
    }

    private var remindersAccessFailed: Bool {
        switch state.syncStatus {
        case .failed, .offline: true
        case .notConfigured, .loading, .updatingCachedCopy, .upToDate: false
        }
    }

    private var remindersDetail: Text {
        switch state.syncStatus {
        case .upToDate:
            Text("^[\(state.snapshot.lists.count) list](inflect: true) · ^[\(state.snapshot.reminders.count) open reminder](inflect: true)")
        case .failed, .offline:
            Text("Access needs attention")
        case .notConfigured, .loading, .updatingCachedCopy:
            Text("Checking access…")
        }
    }

    private func copyConnectionCode() {
        do {
            Pasteboard.copySecret(try state.connectionCode())
            copiedMessage = String(localized: "Connection code copied. It contains passwords, so share it securely.")
        } catch {
            copiedMessage = error.localizedDescription
        }
    }

    private func statusRow(
        symbol: String,
        title: LocalizedStringKey,
        detail: Text,
        ready: Bool,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                detail.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
                .controlSize(.small)
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? .green : .secondary)
                .accessibilityLabel(ready ? Text("Ready") : Text("Not ready"))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// The bridge's menu bar item. When the bridge runs in the background it's the only way to reach
/// the app, so it always offers the window, Settings, and Quit.
struct BridgeStatusMenu: View {
    @Bindable var state: AppState

    var body: some View {
        Text(BridgeStatusText.title(for: state.bridgeState))
        Text(BridgeStatusText.connector(state.cloudflareConnectorState, hostname: state.cloudflareHostname))
        Divider()
        if state.cloudflareProvisioning != nil {
            Button("Copy Connection Code") {
                if let code = try? state.connectionCode() {
                    Pasteboard.copySecret(code)
                }
            }
        }
        Button("Open Task Ferry") {
            WindowRouter.shared.showMainWindow()
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Task Ferry") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

enum BridgeStatusText {
    static func title(for state: BridgeServer.State) -> String {
        switch state {
        case .running: String(localized: "Bridge is ready")
        case .failed: String(localized: "Bridge could not start")
        case .starting: String(localized: "Starting bridge…")
        case .stopped: String(localized: "Bridge is stopped")
        }
    }

    static func detail(for state: BridgeServer.State) -> String {
        switch state {
        case .running(let port): String(localized: "This Mac is listening privately on localhost:\(String(port)).")
        case .failed(let message): String(localized: "\(message) Retrying automatically.")
        case .starting: String(localized: "Binding the private local listener.")
        case .stopped: String(localized: "Open Settings to configure this Mac.")
        }
    }

    static func connector(_ state: CloudflareConnectorState, hostname: String?) -> String {
        switch state {
        case .notConfigured: String(localized: "Remote access isn’t set up")
        case .stopped: String(localized: "Connector stopped")
        case .starting: String(localized: "Connecting to Cloudflare…")
        case .connected: hostname ?? String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting to Cloudflare…")
        case .failed(let message): message
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var showsSettingsLink = false
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(message)
            Spacer()
            if showsSettingsLink {
                SettingsLink { Text("Open Settings…") }
                    .controlSize(.small)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}
