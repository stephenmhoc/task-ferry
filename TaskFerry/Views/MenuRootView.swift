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
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Welcome to Task Ferry")
                    .font(.title.weight(.semibold))
                Text("Choose the role for this Mac. You can change it later in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                RoleCard(
                    title: "Use reminders from another Mac",
                    subtitle: "View and manage them here, from anywhere",
                    symbol: "laptopcomputer"
                ) { Task { await state.chooseMode(.remote) } }
                RoleCard(
                    title: "Share this Mac’s reminders",
                    subtitle: "Make them available to your other Macs",
                    symbol: "antenna.radiowaves.left.and.right"
                ) { Task { await state.chooseMode(.bridge) } }
            }
        }
        .padding(32)
        .frame(maxWidth: 460, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}

/// One choice on the welcome screen: a card that's a button, with hover feedback like a list row.
private struct RoleCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(isHovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
                    Text(state.isDemo ? String(localized: "Sample reminders only. Nothing on this Mac is shared.") : BridgeStatusText.detail(for: state.bridgeState)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            List {
                Section("Status") {
                    statusRow(
                        symbol: "lock.shield",
                        title: "Local connection",
                        detail: Text("Only reachable from this Mac"),
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
                    .task(id: copiedMessage) {
                        try? await Task.sleep(for: .seconds(5))
                        if !Task.isCancelled { self.copiedMessage = nil }
                    }
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
    @Environment(\.openSettings) private var openSettings

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
        // Not SettingsLink: a background bridge isn't active, and Settings would open behind
        // other apps.
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Task Ferry") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

/// The bridge's menu bar icon: the app's ferry, with a warning badge while something needs
/// attention, so a stopped bridge is visible without opening the menu.
struct BridgeStatusIcon: View {
    let state: AppState

    var body: some View {
        let healthy = BridgeStatusText.isHealthy(bridge: state.bridgeState, connector: state.cloudflareConnectorState)
        Image(nsImage: MenuBarSymbol.image(badged: !healthy))
            .accessibilityLabel(healthy ? Text("Task Ferry Bridge") : Text("Task Ferry Bridge needs attention"))
    }
}

@MainActor
enum MenuBarSymbol {
    private static var cache: [Bool: NSImage] = [:]

    static func image(badged: Bool) -> NSImage {
        if let image = cache[badged] { return image }
        let base = NSImage(systemSymbolName: "ferry", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
        var image = base
        if badged, let badge = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) {
            let size = NSSize(width: base.size.width + 3, height: base.size.height)
            image = NSImage(size: size, flipped: false) { _ in
                base.draw(in: NSRect(origin: .zero, size: base.size))
                let spot = NSRect(x: size.width - badge.size.width, y: 0, width: badge.size.width, height: badge.size.height)
                // Cut a gap around the badge, so it reads as separate from the ferry.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: spot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                badge.draw(in: spot)
                return true
            }
        }
        image.isTemplate = true
        cache[badged] = image
        return image
    }
}

enum BridgeStatusText {
    /// Starting up counts as healthy, so the icon doesn't flash a warning at every launch.
    static func isHealthy(bridge: BridgeServer.State, connector: CloudflareConnectorState) -> Bool {
        switch bridge {
        case .running, .starting: break
        case .stopped, .failed: return false
        }
        switch connector {
        case .notConfigured, .starting, .connected: return true
        case .stopped, .reconnecting, .failed: return false
        }
    }

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
        case .running: String(localized: "Your other Macs can reach this Mac’s reminders through your private connection.")
        case .failed(let message): String(localized: "\(message) Retrying automatically.")
        case .starting: String(localized: "Getting ready to share this Mac’s reminders.")
        case .stopped: String(localized: "Open Settings to configure this Mac.")
        }
    }

    static func connector(_ state: CloudflareConnectorState, hostname: String?) -> String {
        switch state {
        case .notConfigured: String(localized: "Remote access isn’t set up")
        case .stopped: String(localized: "Remote access is paused")
        case .starting: String(localized: "Connecting to Cloudflare…")
        case .connected: hostname ?? String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting to Cloudflare…")
        case .failed(let message): message
        }
    }
}

/// A warning above the reminders: what went wrong, and what can be done about it.
struct Banner<Message: View, Actions: View>: View {
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            message
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.orange, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ErrorBanner: View {
    let message: String
    var showsSettingsLink = false
    let dismiss: () -> Void

    var body: some View {
        Banner {
            Text(message)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(message)
        } actions: {
            if showsSettingsLink {
                SettingsLink { Text("Open Settings…") }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss error")
        }
    }
}

/// An edit that couldn't be saved. It stays until it's saved or discarded, and is never written
/// to disk.
struct DraftBanner: View {
    let draft: ReminderEditSession
    /// False once the reminder is gone from the bridge, when only copying or discarding is left.
    let canRetry: Bool
    let review: () -> Void
    let retry: () -> Void
    let copy: () -> Void
    let discard: () -> Void

    var body: some View {
        Banner {
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t save “\(draft.title)”")
                    .fontWeight(.medium)
                    .lineLimit(2)
                if let error = draft.error {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .disabled(!canRetry)
            Menu {
                Button("Review", action: review)
                    .disabled(!canRetry)
                Button("Copy Draft", action: copy)
                Divider()
                Button("Discard Draft", role: .destructive, action: discard)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Actions")
            .accessibilityLabel("More actions for this draft")
        }
    }
}
