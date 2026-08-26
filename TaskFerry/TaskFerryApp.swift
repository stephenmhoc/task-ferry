import AppKit
import SwiftUI

enum TaskFerryWindowID {
    static let mainScene = "main"
    static let mainWindow = NSUserInterfaceItemIdentifier("TaskFerry.main")
}

@main
struct TaskFerryApp: App {
    @NSApplicationDelegateAdaptor(TaskFerryApplicationDelegate.self) private var appDelegate
    @State private var state = AppState()

    init() {
        UpdateManager.start()
    }

    var body: some Scene {
        WindowGroup("Task Ferry", id: TaskFerryWindowID.mainScene) {
            MenuRootView(state: state)
        }
        .defaultSize(width: 1_180, height: 700)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            TaskFerryCommands()
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

struct TaskFerryCommandAction {
    let perform: () -> Void
}

private struct NewReminderActionKey: FocusedValueKey {
    typealias Value = TaskFerryCommandAction
}

private struct RefreshRemindersActionKey: FocusedValueKey {
    typealias Value = TaskFerryCommandAction
}

extension FocusedValues {
    var newReminderAction: TaskFerryCommandAction? {
        get { self[NewReminderActionKey.self] }
        set { self[NewReminderActionKey.self] = newValue }
    }

    var refreshRemindersAction: TaskFerryCommandAction? {
        get { self[RefreshRemindersActionKey.self] }
        set { self[RefreshRemindersActionKey.self] = newValue }
    }
}

private struct TaskFerryCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newReminderAction) private var newReminderAction
    @FocusedValue(\.refreshRemindersAction) private var refreshRemindersAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Reminder") {
                newReminderAction?.perform()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(newReminderAction == nil)

            Button("New Window") {
                openWindow(id: TaskFerryWindowID.mainScene)
            }
            .keyboardShortcut("n", modifiers: [.control, .command])
        }

        CommandMenu("Tasks") {
            Button("Refresh Reminders") {
                refreshRemindersAction?.perform()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshRemindersAction == nil)
        }
    }
}

@MainActor
enum DockBadgeManager {
    static func update(count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}

@MainActor
final class TaskFerryApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldRunHidden {
            NSApplication.shared.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApplication.shared.windows.forEach { $0.orderOut(nil) }
            }
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            // Reveal SwiftUI's registered main window without trying to create a second one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.showMainWindowIfAvailable(in: NSApplication.shared, activate: true)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        guard showMainWindowIfAvailable(in: sender, activate: true) else {
            return true
        }
        return false
    }

    @discardableResult
    private func showMainWindowIfAvailable(in application: NSApplication, activate: Bool) -> Bool {
        guard let mainWindow = application.windows.first(where: { $0.identifier == TaskFerryWindowID.mainWindow }) else {
            return false
        }
        mainWindow.makeKeyAndOrderFront(nil)

        if activate {
            application.activate(ignoringOtherApps: true)
        }
        return true
    }

    private var shouldRunHidden: Bool {
        guard ProcessInfo.processInfo.environment["TASK_FERRY_DEMO"] != "1" else { return false }
        return UserDefaults.standard.string(forKey: AppPreferences.mode) == AppMode.bridge.rawValue
            && UserDefaults.standard.bool(forKey: AppPreferences.runsInBackground)
    }
}
