import AppKit
import SwiftUI

extension AppState {
    /// The one app-wide state. The delegate, menus, intents, and scenes all share it.
    static let shared = AppState()
}

@main
struct TaskFerryApp: App {
    @NSApplicationDelegateAdaptor(TaskFerryApplicationDelegate.self) private var appDelegate
    @State private var state = AppState.shared
    @AppStorage(AppPreferences.showsQuickEntryInMenuBar) private var showsQuickEntry = true
    @AppStorage(AppPreferences.showsBridgeStatusInMenuBar) private var showsBridgeStatus = true

    var body: some Scene {
        WindowGroup("Task Ferry", id: TaskFerryWindowID.mainScene) {
            MenuRootView(state: state)
        }
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            TaskFerryCommands(state: state)
        }

        MenuBarExtra("Quick Reminder", systemImage: "plus.circle", isInserted: quickEntryIsInserted) {
            QuickEntryView(state: state, style: .menuBar)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra("Task Ferry Bridge", systemImage: "antenna.radiowaves.left.and.right", isInserted: bridgeStatusIsInserted) {
            BridgeStatusMenu(state: state)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(state: state)
        }
    }

    /// Quick Entry belongs to a configured remote client, and the user can remove it by
    /// ⌘-dragging it out of the menu bar or in Settings.
    private var quickEntryIsInserted: Binding<Bool> {
        Binding(
            get: { state.mode == .remote && showsQuickEntry },
            set: { showsQuickEntry = $0 }
        )
    }

    /// A bridge running in the background has no Dock icon, so its status item is its only visible
    /// presence. It can't be hidden in that mode.
    private var bridgeStatusIsInserted: Binding<Bool> {
        Binding(
            get: { state.mode == .bridge && (showsBridgeStatus || state.runsInBackground) },
            set: { showsBridgeStatus = $0 }
        )
    }
}

// MARK: - Commands

/// The main window publishes this so menu commands act on its current view and selection.
struct WorkspaceActions {
    var newReminder: () -> Void
    var newList: () -> Void
    var find: () -> Void
    var refresh: () -> Void
    var show: (NavigationRequest.Destination) -> Void
    var lists: [ReminderListRecord]
    var hasSelection: Bool
    var editSelection: () -> Void
    var completeSelection: () -> Void
    var rescheduleSelection: (QuickDueOption) -> Void
    var moveSelection: (String) -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

private struct TaskFerryCommands: Commands {
    let state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @FocusedValue(\.workspaceActions) private var actions

    private static let helpURL = URL(string: "https://github.com/smeriwether/task-ferry#readme")!
    private static let sourceURL = URL(string: "https://github.com/smeriwether/task-ferry")!

    var body: some Commands {
        let _ = WindowRouter.shared.install(openWindow)

        SidebarCommands()
        ToolbarCommands()

        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }

        CommandGroup(replacing: .newItem) {
            Button("New Reminder") {
                if let actions {
                    actions.newReminder()
                } else {
                    WindowRouter.shared.showMainWindow()
                    state.navigate(to: .newReminder)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(state.mode != .remote)

            Button("New List…") {
                actions?.newList()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Quick Reminder…") {
                QuickEntryPanelController.shared.show(state: state)
            }
            .disabled(state.mode != .remote)

            Divider()

            Button("New Window") {
                openWindow(id: TaskFerryWindowID.mainScene)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(state.mode != .remote)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") {
                actions?.find()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)
        }

        CommandGroup(before: .toolbar) {
            Button("Today") { actions?.show(.today) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(actions == nil)
            Button("Tomorrow") { actions?.show(.tomorrow) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(actions == nil)
            Button("All Reminders") { actions?.show(.all) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button("Refresh") {
                if let actions {
                    actions.refresh()
                } else {
                    Task { await state.refresh() }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.mode == nil)
            Divider()
        }

        CommandMenu("Reminder") {
            Button("Show Info") { actions?.editSelection() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions?.hasSelection != true)
            Button("Mark as Completed") { actions?.completeSelection() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(actions?.hasSelection != true)
            Divider()
            Button("Due Today") { actions?.rescheduleSelection(.today) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions?.hasSelection != true)
            Button("Due Tomorrow") { actions?.rescheduleSelection(.tomorrow) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(actions?.hasSelection != true)
            Button("Remove Due Date") { actions?.rescheduleSelection(.none) }
                .disabled(actions?.hasSelection != true)
            Menu("Move to List") {
                ForEach(actions?.lists ?? []) { list in
                    Button(list.title) { actions?.moveSelection(list.id) }
                }
            }
            .disabled(actions?.hasSelection != true)
        }

        CommandGroup(replacing: .help) {
            Button("Task Ferry Help") {
                openURL(Self.helpURL)
            }
            Link("Task Ferry Source & License", destination: Self.sourceURL)
        }
    }
}

struct CheckForUpdatesButton: View {
    @State private var updates = UpdateManager.shared

    var body: some View {
        if UpdateManager.isSupported {
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates && updates.hasStarted)
        }
    }
}

// MARK: - Dock

@MainActor
enum DockBadgeManager {
    static func update(count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}

// MARK: - Application delegate

@MainActor
final class TaskFerryApplicationDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var notifications: ReminderNotificationScheduler { .shared }
    private var servicesProvider: ServicesProvider?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Decide the Dock presence before anything is drawn, so a background bridge never flashes
        // a Dock icon or window.
        if shouldRunHidden {
            NSApp.setActivationPolicy(.accessory)
        }
        // Notification actions chosen while the app wasn't running arrive during launch, so the
        // delegate must be in place first. When alerts are off, UserNotifications isn't touched.
        if notifications.isEnabled {
            notifications.install()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.onDockBadgeChange = { DockBadgeManager.update(count: $0) }
        state.onSnapshotChange = { [weak self] _ in self?.notifications.reconcile() }
        DockBadgeManager.update(count: state.dockBadgeCount)

        // Start syncing now, in parallel with SwiftUI building the first window. A remote Mac
        // already shows its cached reminders, and this replaces them within one round trip.
        state.launch()

        // Registered now, not deferred: a Services request can be what launched the app.
        servicesProvider = ServicesProvider(state: state)
        NSApp.servicesProvider = servicesProvider

        if shouldRunHidden {
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.orderOut(nil) }
            }
        }

        // Nothing below is needed to use the window. The cheap hooks wait for the first frame, and
        // the rest waits until the app has settled, so none of it competes with the first
        // interaction. The Services entry itself comes from Info.plist, so there's no registry to
        // update.
        DispatchQueue.main.async { [self] in
            state.observeSystemEvents()
            state.cleanUpOrphanedConnector()
            GlobalHotKey.shared.applyPreference()
        }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(1))
            notifications.reconcile()
            UpdateManager.shared.startAfterLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.prepareForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        // Bring back the existing window if there is one. Otherwise SwiftUI opens a new one.
        return !WindowRouter.shared.revealExistingMainWindow()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard state.mode == .remote else { return nil }
        let menu = NSMenu()
        menu.addItem(item(String(localized: "New Reminder"), action: #selector(dockNewReminder)))
        menu.addItem(item(String(localized: "Quick Reminder…"), action: #selector(dockQuickReminder)))

        let today = state.todayReminders.prefix(10)
        if !today.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: String(localized: "Today")))
            for reminder in today {
                let entry = item(reminder.title, action: #selector(dockShowReminder(_:)))
                entry.representedObject = reminder.id
                if state.isOverdue(reminder) {
                    entry.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: String(localized: "Overdue"))
                }
                menu.addItem(entry)
            }
        }
        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = TaskFerryURL(url) else { continue }
            handle(action)
        }
    }

    // MARK: Actions

    private func handle(_ action: TaskFerryURL) {
        switch action {
        case .add(let title, let listQuery, let due, let notes):
            // Any web page can open a URL, so a URL only fills in Quick Entry and you confirm with
            // Return. Shortcuts and App Intents are the way to add reminders silently.
            let listID = listQuery.flatMap { state.list(matching: $0)?.id }
            QuickEntryPanelController.shared.show(state: state, title: title ?? "", notes: notes, listID: listID, due: due)
        case .show(let destination):
            WindowRouter.shared.showMainWindow()
            if case .list(let query) = destination, let list = state.list(matching: query) {
                state.navigate(to: .list(list.id))
            } else {
                state.navigate(to: destination)
            }
        }
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func dockNewReminder() {
        WindowRouter.shared.showMainWindow()
        state.navigate(to: .newReminder)
    }

    @objc private func dockQuickReminder() {
        QuickEntryPanelController.shared.show(state: state)
    }

    @objc private func dockShowReminder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        WindowRouter.shared.showMainWindow()
        state.navigate(to: .reminder(id))
    }

    private var shouldRunHidden: Bool {
        guard ProcessInfo.processInfo.environment["TASK_FERRY_DEMO"] != "1" else { return false }
        return UserDefaults.standard.string(forKey: AppPreferences.mode) == AppMode.bridge.rawValue
            && UserDefaults.standard.bool(forKey: AppPreferences.runsInBackground)
    }
}
