import AppKit
import SwiftUI

enum TaskFerryWindowID {
    static let mainScene = "main"
}

/// Finds or opens the main window for code that runs outside any view: the Dock menu,
/// notifications, URLs, Services, and the menu bar items.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var openWindowAction: OpenWindowAction?
    private let mainWindows = NSHashTable<NSWindow>.weakObjects()

    /// Commands install SwiftUI's window opener when the menu bar is built at launch.
    func install(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    func register(_ window: NSWindow) {
        guard !mainWindows.contains(window) else { return }
        mainWindows.add(window)
        if TaskFerryRuntime.isDemo,
           ProcessInfo.processInfo.environment["TASK_FERRY_DEMO_SIZE"] == "compact" {
            Task { @MainActor [weak window] in
                window?.setContentSize(NSSize(width: 580, height: 420))
            }
        }
        // A closed window must never be revived. Only windows that are open, even if ordered out
        // like a background bridge's, may be brought back.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window { WindowRouter.shared.mainWindows.remove(window) }
            }
        }
    }

    var visibleMainWindowCount: Int {
        mainWindows.allObjects.filter(\.isVisible).count
    }

    /// Brings an existing main window forward. Returns false when there isn't one.
    @discardableResult
    func revealExistingMainWindow(activate: Bool = true) -> Bool {
        let windows = mainWindows.allObjects
        guard let window = windows.first(where: \.isKeyWindow)
            ?? windows.first(where: \.isVisible)
            ?? windows.first else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        if activate {
            NSApp.activate()
        }
        return true
    }

    func showMainWindow() {
        if !revealExistingMainWindow() {
            openWindowAction?(id: TaskFerryWindowID.mainScene)
            NSApp.activate()
        }
    }
}

/// Registers the hosting window with ``WindowRouter``.
struct MainWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> RegistrarView { RegistrarView() }
    func updateNSView(_ view: RegistrarView, context: Context) {}

    final class RegistrarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                WindowRouter.shared.register(window)
            }
        }
    }
}
