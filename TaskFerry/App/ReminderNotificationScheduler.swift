import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Due-date alerts for a remote Mac, with Complete, Snooze, and Tomorrow actions.
///
/// It stays silent until the user turns it on in Settings, which is when permission is requested.
@MainActor
final class ReminderNotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotificationScheduler(state: .shared)
    static let categoryIdentifier = "TASK_FERRY_REMINDER"

    enum Action {
        static let complete = "COMPLETE"
        static let snooze = "SNOOZE_HOUR"
        static let tomorrow = "TOMORROW"
    }

    private let state: AppState
    private let defaults: UserDefaults
    private var reconcileTask: Task<Void, Never>?
    private var isInstalled = false
    private lazy var center = UNUserNotificationCenter.current()

    init(state: AppState, defaults: UserDefaults = .standard) {
        self.state = state
        self.defaults = defaults
        super.init()
    }

    /// Becomes the notification delegate. This must happen before launch finishes, so actions
    /// chosen while Task Ferry wasn't running are delivered.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [
                    UNNotificationAction(identifier: Action.complete, title: String(localized: "Complete")),
                    UNNotificationAction(identifier: Action.snooze, title: String(localized: "Remind Me in 1 Hour")),
                    UNNotificationAction(identifier: Action.tomorrow, title: String(localized: "Move to Tomorrow"))
                ],
                intentIdentifiers: []
            )
        ])
    }

    var isEnabled: Bool { defaults.bool(forKey: AppPreferences.notifiesWhenDue) }

    var dateOnlyHour: Int {
        defaults.object(forKey: AppPreferences.dateOnlyNotificationHour) == nil
            ? 9
            : defaults.integer(forKey: AppPreferences.dateOnlyNotificationHour)
    }

    /// Turns alerts on or off. Returns false if macOS permission was denied.
    func setEnabled(_ enabled: Bool) async -> Bool {
        install()
        if enabled {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                defaults.set(false, forKey: AppPreferences.notifiesWhenDue)
                reconcile()
                return false
            }
        }
        defaults.set(enabled, forKey: AppPreferences.notifiesWhenDue)
        reconcile()
        return true
    }

    func setDateOnlyHour(_ hour: Int) {
        defaults.set(hour, forKey: AppPreferences.dateOnlyNotificationHour)
        reconcile()
    }

    func reconcile() {
        // Alerts have never been turned on this session, so there is nothing to schedule or clear.
        guard isEnabled || isInstalled else { return }
        install()
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            await self?.performReconcile()
        }
    }

    private func performReconcile() async {
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(ReminderNotificationPlan.identifierPrefix) }
        guard !Task.isCancelled else { return }
        guard isEnabled, state.mode == .remote else {
            center.removePendingNotificationRequests(withIdentifiers: pending)
            return
        }
        // Until reminders have been loaded, an empty list means "not known yet", not "nothing due".
        guard state.hasLoadedSnapshot || state.isShowingCachedSnapshot else { return }

        let openIDs = Set(state.snapshot.reminders.map(\.id))
        let items = ReminderNotificationPlan.items(for: state.snapshot, now: Date(), dateOnlyHour: dateOnlyHour)
        let wanted = Set(items.map(\.identifier))
        let unwanted = pending.filter { identifier in
            if let reminderID = Self.snoozedReminderID(identifier) {
                return !openIDs.contains(reminderID)
            }
            return !wanted.contains(identifier)
        }
        center.removePendingNotificationRequests(withIdentifiers: unwanted)
        let existing = Set(pending)
        for item in items where !existing.contains(item.identifier) {
            guard !Task.isCancelled else { return }
            try? await center.add(request(for: item))
        }

        // Clear alerts for reminders that were completed or deleted elsewhere.
        let stale = await center.deliveredNotifications().compactMap { notification -> String? in
            guard let id = notification.request.content.userInfo["reminderID"] as? String,
                  !openIDs.contains(id) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }

    /// Snoozes share the plan's prefix, so reconciling cancels them once their reminder is done.
    private static func snoozeIdentifier(_ reminderID: String) -> String {
        "\(ReminderNotificationPlan.identifierPrefix)snooze.\(reminderID)"
    }

    private static func snoozedReminderID(_ identifier: String) -> String? {
        let prefix = "\(ReminderNotificationPlan.identifierPrefix)snooze."
        guard identifier.hasPrefix(prefix) else { return nil }
        return String(identifier.dropFirst(prefix.count))
    }

    private func request(for item: ReminderNotificationPlan.Item, identifier: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = item.listID
        content.userInfo = ["reminderID": item.reminderID]
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: item.fireDate
        )
        return UNNotificationRequest(
            identifier: identifier ?? item.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let reminderID = content.userInfo["reminderID"] as? String
        let action = response.actionIdentifier
        let title = content.title
        let body = content.body
        let listID = content.threadIdentifier
        await handle(action: action, reminderID: reminderID, title: title, body: body, listID: listID)
    }

    private func handle(action: String, reminderID: String?, title: String, body: String, listID: String) async {
        guard let reminderID else { return }
        switch action {
        case Action.complete:
            await state.start()
            await state.setCompleted(reminderID: reminderID, true)
        case Action.snooze:
            let item = ReminderNotificationPlan.Item(
                identifier: Self.snoozeIdentifier(reminderID),
                reminderID: reminderID,
                listID: listID,
                title: title,
                body: body,
                fireDate: Date().addingTimeInterval(60 * 60)
            )
            try? await center.add(request(for: item, identifier: item.identifier))
        case Action.tomorrow:
            await state.start()
            if state.reminder(for: reminderID) == nil {
                await state.refresh(showLoadingIndicator: false)
            }
            if let reminder = state.reminder(for: reminderID) {
                await state.reschedule([reminder], to: .tomorrow)
            }
        default:
            WindowRouter.shared.showMainWindow()
            state.navigate(to: .reminder(reminderID))
        }
    }
}
