import AppKit
import SwiftUI

@main
struct TaskFerryApp: App {
    @NSApplicationDelegateAdaptor(TaskFerryApplicationDelegate.self) private var appDelegate
    @State private var state = AppState()

    init() {
        UpdateManager.start()
    }

    var body: some Scene {
        WindowGroup("Task Ferry") {
            MenuRootView(state: state)
        }
        .defaultSize(width: 400, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Task Ferry") {
                    NSApplication.shared.orderFrontStandardAboutPanel()
                }
            }
            CommandGroup(after: .appInfo) {
                if UpdateManager.isSupported {
                    Button("Check for Updates…") {
                        UpdateManager.checkForUpdates()
                    }
                    .disabled(!UpdateManager.canCheckForUpdates)
                }
            }
            CommandGroup(after: .help) {
                Link("Task Ferry Source & License", destination: URL(string: "https://github.com/smeriwether/task-ferry")!)
            }
        }

        MenuBarExtra(isInserted: quickEntryIsInserted) {
            QuickEntryView(state: state)
        } label: {
            Label("Quick Reminder", systemImage: "plus.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: state)
        }
    }

    private var quickEntryIsInserted: Binding<Bool> {
        Binding(
            get: { state.mode != .bridge },
            set: { _ in }
        )
    }
}

@MainActor
enum DockBadgeManager {
    static func update(count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}

final class TaskFerryApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldRunHidden else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            NSApplication.shared.windows.forEach { $0.orderOut(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        let mainWindow = sender.windows.first {
            $0.identifier?.rawValue.contains("MenuRootView") == true
        } ?? sender.windows.first(where: \.canBecomeMain)
        mainWindow?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }

    private var shouldRunHidden: Bool {
        guard ProcessInfo.processInfo.environment["TASK_FERRY_DEMO"] != "1" else { return false }
        return UserDefaults.standard.string(forKey: AppPreferences.mode) == AppMode.bridge.rawValue
            && UserDefaults.standard.bool(forKey: AppPreferences.runsInBackground)
    }
}
