import AppKit
import SwiftUI

struct MenuRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var state: AppState

    var body: some View {
        Group {
            switch state.mode {
            case nil:
                SetupView(state: state)
            case .bridge:
                BridgeView(state: state)
            case .remote:
                RemindersWorkspaceView(state: state)
            }
        }
        .frame(minWidth: minimumWidth, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowMinimumSize(width: minimumWidth, height: 540))
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

    private var minimumWidth: CGFloat {
        state.mode == .remote ? 800 : 400
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
        window.identifier = TaskFerryWindowID.mainWindow
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
