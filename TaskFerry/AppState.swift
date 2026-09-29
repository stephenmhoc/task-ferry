import AppKit
import Foundation
import Network
import Observation

enum AppPreferences {
    static let mode = "mode"
    static let endpoint = "endpoint"
    static let port = "port"
    static let runsInBackground = "runs-in-background"
    static let cloudflareProvisioning = "cloudflare-provisioning"
    static let showsDockBadge = "shows-dock-badge"
    static let dockBadgeScope = "dock-badge-scope"
    static let keepsOfflineCopy = "keeps-offline-copy"
    static let showsQuickEntryInMenuBar = "shows-quick-entry-in-menu-bar"
    static let showsBridgeStatusInMenuBar = "shows-bridge-status-in-menu-bar"
    static let quickEntryHotKeyEnabled = "quick-entry-hot-key-enabled"
    static let notifiesWhenDue = "notifies-when-due"
    static let dateOnlyNotificationHour = "date-only-notification-hour"
    static let newReminderListID = "new-reminder-list-id"
}

/// A request from outside the main window (Dock menu, notification, URL, intent) to show something.
struct NavigationRequest: Equatable {
    enum Destination: Equatable {
        case today
        case tomorrow
        case all
        case list(String)
        case reminder(String)
        case newReminder
    }

    let id = UUID()
    let destination: Destination
}

/// What a mutation produced. `createdID` is the identifier the bridge assigned to a new reminder or list.
struct MutationOutcome {
    let succeeded: Bool
    var createdID: String? = nil
}

/// Reminder collections derived from the snapshot and the current day. They are computed once
/// per change instead of on every view update.
struct DerivedReminders: Equatable {
    var today: [ReminderRecord] = []
    var tomorrow: [ReminderRecord] = []
    var all: [ReminderRecord] = []
    var byList: [String: [ReminderRecord]] = [:]
    var overdueIDs: Set<String> = []

    static let empty = DerivedReminders()
}

@MainActor
@Observable
final class AppState {
    struct StoredCredentials: Sendable {
        var accessClientID: String
        var accessClientSecret: String
        var bridgeToken: String
        var tunnelToken: String

        static let empty = StoredCredentials(accessClientID: "", accessClientSecret: "", bridgeToken: "", tunnelToken: "")
    }

    enum ConnectionState: Equatable {
        case idle
        case loading
        case connected
        case failed
    }

    /// Keychain accounts. A bridge and a remote client keep separate items. Otherwise switching
    /// roles could make a remote Mac reuse its own bridge credentials and connect to itself.
    enum SecretKey {
        static let accessClientID = "access-client-id"
        static let accessClientSecret = "access-client-secret"
        static let bridgeToken = "bridge-token"
        static let tunnelToken = "cloudflare-tunnel-token"

        static let remoteAccessClientID = "remote-access-client-id"
        static let remoteAccessClientSecret = "remote-access-client-secret"
        static let remoteBridgeToken = "remote-bridge-token"
    }

    private enum ErrorSource: Equatable {
        case refresh
        case mutation
        case configuration
    }

    /// Background syncs that fail this many times in a row before the error is shown. A laptop
    /// changing networks shouldn't raise a banner for one missed poll.
    private static let quietFailureLimit = 3

    var mode: AppMode?
    var snapshot = ReminderSnapshot.empty {
        didSet { rebuildDerived() }
    }
    private(set) var derived = DerivedReminders.empty
    /// Midnight of the current day. It is updated when the day changes, so Today and Tomorrow
    /// roll over at midnight whether or not anything else changes.
    private(set) var currentDay: Date
    private(set) var hasLoadedSnapshot = false
    /// True while the window shows the cached copy from the last session and a live sync hasn't
    /// finished yet.
    private(set) var isShowingCachedSnapshot = false
    private(set) var lastSuccessfulSync: Date?
    private(set) var consecutiveSyncFailures = 0
    var connectionState = ConnectionState.idle
    var bridgeState = BridgeServer.State.stopped
    var cloudflareConnectorState = CloudflareConnectorState.notConfigured
    var errorMessage: String?
    var runsInBackground: Bool
    var showsDockBadge: Bool
    var dockBadgeScope: DockBadgeScope
    var navigationRequest: NavigationRequest?
    var unsavedEdits: [UUID: ReminderEditSession] = [:]
    private(set) var preferredNewReminderListID: String?

    /// Called whenever the Dock badge count may have changed. The app layer owns the Dock tile.
    @ObservationIgnored var onDockBadgeChange: ((Int) -> Void)?
    /// Called with each new authoritative snapshot, for due-date notifications.
    @ObservationIgnored var onSnapshotChange: ((ReminderSnapshot) -> Void)?

    @ObservationIgnored private let operations = ReminderOperationCoordinator()
    @ObservationIgnored private var bridge: BridgeServer?
    @ObservationIgnored private var bridgeService: (any ReminderService)?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var automaticRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var storeChangeTask: Task<Void, Never>?
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored let demoScenario: DemoScenario
    @ObservationIgnored private var demoService: DemoReminderService?
    @ObservationIgnored private let automaticRefreshInterval: Duration
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let serviceFactory: ReminderServiceFactory
    @ObservationIgnored private let cloudflareConnector: CloudflareTunnelConnector
    @ObservationIgnored private let snapshotCache: SnapshotCache
    @ObservationIgnored private var errorSource: ErrorSource?
    @ObservationIgnored private var demoEndpoint = "https://reminders.example.com"
    @ObservationIgnored private var credentialsLoaded = false
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var isSystemAsleep = false
    @ObservationIgnored private var lastRefreshStartedAt: Date?
    @ObservationIgnored private var lastReportedBadgeCount: Int?
    @ObservationIgnored private var systemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkWasUnavailable = false
    /// True once a remote client has a working service to poll.
    @ObservationIgnored private var hasRemoteService = false
    private var cachedCredentials = StoredCredentials.empty

    var endpoint: String {
        get { isDemo ? demoEndpoint : defaults.string(forKey: AppPreferences.endpoint) ?? "" }
        set {
            if isDemo {
                demoEndpoint = newValue
            } else {
                defaults.set(newValue, forKey: AppPreferences.endpoint)
            }
        }
    }

    var port: UInt16 {
        get {
            let stored = defaults.integer(forKey: AppPreferences.port)
            return stored > 0 ? UInt16(exactly: stored) ?? 8788 : 8788
        }
        set { defaults.set(Int(newValue), forKey: AppPreferences.port) }
    }

    var accessClientID: String { cachedCredentials.accessClientID }
    var accessClientSecret: String { cachedCredentials.accessClientSecret }
    var bridgeToken: String { cachedCredentials.bridgeToken }
    var tunnelToken: String { cachedCredentials.tunnelToken }

    var cloudflareProvisioning: CloudflareProvisioning? {
        if isDemo, demoScenario == .provisionedBridge {
            return CloudflareProvisioning(accountID: "demo", zoneID: "demo", tunnelID: "demo",
                accessApplicationID: "demo", serviceTokenID: "demo", dnsRecordID: "demo", hostname: "reminders.example.com")
        }
        guard let data = defaults.data(forKey: AppPreferences.cloudflareProvisioning) else { return nil }
        return try? JSONDecoder().decode(CloudflareProvisioning.self, from: data)
    }

    var cloudflareHostname: String? { cloudflareProvisioning?.hostname }

    var keepsOfflineCopy: Bool {
        defaults.object(forKey: AppPreferences.keepsOfflineCopy) == nil
            ? true
            : defaults.bool(forKey: AppPreferences.keepsOfflineCopy)
    }

    /// True when the current error can only be fixed in Settings.
    var errorNeedsSettings: Bool { errorMessage != nil && errorSource == .configuration }

    /// True when background syncs are failing but reminders from an earlier sync are still shown.
    var isOffline: Bool { consecutiveSyncFailures > 0 && (hasLoadedSnapshot || isShowingCachedSnapshot) }

    init(
        isDemo: Bool? = nil,
        defaults: UserDefaults? = nil,
        demoScenario: DemoScenario? = nil,
        credentialStore: any CredentialStore = KeychainStore(),
        serviceFactory: ReminderServiceFactory? = nil,
        cloudflareConnector: CloudflareTunnelConnector? = nil,
        snapshotCache: SnapshotCache? = nil,
        automaticRefreshInterval: Duration = .seconds(15)
    ) {
        let demoMode = isDemo ?? (ProcessInfo.processInfo.environment["TASK_FERRY_DEMO"] == "1")
        self.isDemo = demoMode
        self.demoScenario = demoScenario ?? (demoMode ? .current : .standard)
        let defaults = demoMode
            ? (TaskFerryRuntime.isDemo ? TaskFerryRuntime.preferences : TaskFerryRuntime.makeDemoPreferences())
            : (defaults ?? .standard)
        self.defaults = defaults
        preferredNewReminderListID = defaults.string(forKey: AppPreferences.newReminderListID)
        self.credentialStore = credentialStore
        // Resolve actor-isolated defaults here. Swift 6.1 can mis-lower later default arguments
        // when an earlier parameter's default needs main-actor isolation.
        self.serviceFactory = serviceFactory ?? .live
        self.cloudflareConnector = cloudflareConnector ?? CloudflareTunnelConnector()
        self.snapshotCache = demoMode ? .disabled : (snapshotCache ?? .live)
        self.automaticRefreshInterval = automaticRefreshInterval
        currentDay = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        runsInBackground = demoMode ? false : defaults.bool(forKey: AppPreferences.runsInBackground)
        showsDockBadge = defaults.object(forKey: AppPreferences.showsDockBadge) == nil
            ? true
            : defaults.bool(forKey: AppPreferences.showsDockBadge)
        dockBadgeScope = defaults.string(forKey: AppPreferences.dockBadgeScope)
            .flatMap(DockBadgeScope.init(rawValue:)) ?? .todayAndOverdue
        if demoMode {
            if self.demoScenario == .unconfigured { demoEndpoint = "" }
            mode = self.demoScenario == .unconfigured ? nil
                : (ProcessInfo.processInfo.environment["TASK_FERRY_DEMO_ROLE"] == "bridge" || self.demoScenario == .provisionedBridge ? .bridge : .remote)
            if let mode { configureDemoService(for: mode) }
        } else if let value = defaults.string(forKey: AppPreferences.mode),
                  let savedMode = AppMode(rawValue: value) {
            mode = savedMode
            if savedMode == .remote {
                restoreCachedSnapshot()
            }
        }
        self.cloudflareConnector.onStateChange = { [weak self] connectorState in
            self?.cloudflareConnectorState = connectorState
        }
    }

    // MARK: - Derived reminders

    var todayReminders: [ReminderRecord] { derived.today }
    var tomorrowReminders: [ReminderRecord] { derived.tomorrow }
    var allReminders: [ReminderRecord] { derived.all }

    var dockBadgeCount: Int {
        dockBadgeCount(on: max(Date(), currentDay))
    }

    func dockBadgeCount(on date: Date) -> Int {
        guard showsDockBadge, mode != nil else { return 0 }
        return snapshot.reminders.reduce(into: 0) { count, reminder in
            guard let due = reminder.due else { return }
            let isIncluded = due.isBeforeDay(date)
                || (dockBadgeScope == .todayAndOverdue && due.isSameDay(as: date))
            if isIncluded {
                count += 1
            }
        }
    }

    var defaultListID: String? {
        if let id = snapshot.defaultListID, snapshot.lists.contains(where: { $0.id == id }) {
            return id
        }
        return snapshot.lists.first?.id
    }

    /// The most recently chosen list in a new-reminder picker, when it still exists.
    var newReminderListID: String? {
        if let id = preferredNewReminderListID,
           snapshot.lists.contains(where: { $0.id == id }) {
            return id
        }
        return defaultListID
    }

    func rememberNewReminderList(_ id: String) {
        guard snapshot.lists.contains(where: { $0.id == id }) else { return }
        preferredNewReminderListID = id
        defaults.set(id, forKey: AppPreferences.newReminderListID)
    }

    func reminders(in listID: String) -> [ReminderRecord] {
        derived.byList[listID] ?? []
    }

    func list(for id: String) -> ReminderListRecord? {
        snapshot.lists.first { $0.id == id }
    }

    func reminder(for id: String) -> ReminderRecord? {
        snapshot.reminders.first { $0.id == id }
    }

    func isOverdue(_ reminder: ReminderRecord) -> Bool {
        derived.overdueIDs.contains(reminder.id)
    }

    /// Finds a list by identifier or, for URLs and Shortcuts, by case-insensitive title.
    func list(matching query: String) -> ReminderListRecord? {
        let query = query.trimmed
        return snapshot.lists.first { $0.id == query }
            ?? snapshot.lists.first { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame }
    }

    /// Recomputes the day, e.g. after `NSCalendarDayChanged`, a time-zone change, or waking from sleep.
    func dayDidChange(now: Date = Date()) {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: now)
        guard day != currentDay else {
            reportDockBadge()
            return
        }
        currentDay = day
        rebuildDerived()
    }

    private func rebuildDerived() {
        let calendar = Calendar.autoupdatingCurrent
        let now = max(Date(), currentDay)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let sorted = snapshot.reminders.sorted(by: Self.sortReminders)
        var result = DerivedReminders(all: sorted)
        for reminder in sorted {
            result.byList[reminder.listID, default: []].append(reminder)
            guard let due = reminder.due else { continue }
            if due.isBeforeDay(now, calendar: calendar) {
                result.overdueIDs.insert(reminder.id)
                result.today.append(reminder)
            } else if due.isSameDay(as: now, calendar: calendar) {
                result.today.append(reminder)
            } else if due.isSameDay(as: tomorrow, calendar: calendar) {
                result.tomorrow.append(reminder)
            }
        }
        if result != derived {
            derived = result
        }
        reportDockBadge()
    }

    private func reportDockBadge() {
        let count = dockBadgeCount
        guard count != lastReportedBadgeCount else { return }
        lastReportedBadgeCount = count
        onDockBadgeChange?(count)
    }

    // MARK: - Lifecycle

    func chooseMode(_ mode: AppMode) async {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: AppPreferences.mode)
        applyActivationPolicy()
        await start()
        await refresh()
    }

    /// Starts connecting as soon as the app launches, without waiting for any window, so a sync is
    /// already in flight by the time the first frame is on screen.
    func launch() {
        guard mode != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.start()
            await self.refresh(showLoadingIndicator: !self.isShowingCachedSnapshot)
        }
    }

    func start() async {
        guard !isStarted, let mode else { return }
        if let startTask {
            await startTask.value
            return
        }

        startGeneration += 1
        let generation = startGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareService(for: mode, generation: generation)
        }
        startTask = task
        await task.value
        if startGeneration == generation {
            startTask = nil
        }
    }

    /// Leaves the current role. A remote client's connection code, endpoint, and cached reminders
    /// are forgotten. A bridge keeps its Keychain items and Cloudflare setup, so choosing the
    /// bridge role again picks up where it left off without breaking its paired Mac.
    func resetMode() {
        let previousMode = mode
        for draft in unsavedEdits.values { draft.discard() }
        unsavedEdits.removeAll()
        startGeneration += 1
        startTask?.cancel()
        startTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        stopAutomaticRefresh()
        storeChangeTask?.cancel()
        cloudflareConnector.stop()
        bridge?.stop()
        bridge = nil
        bridgeService = nil
        bridgeState = .stopped
        operations.replaceService(nil)
        hasRemoteService = false
        isStarted = false
        mode = nil
        snapshot = .empty
        hasLoadedSnapshot = false
        isShowingCachedSnapshot = false
        lastSuccessfulSync = nil
        consecutiveSyncFailures = 0
        connectionState = .idle
        clearError()
        defaults.removeObject(forKey: AppPreferences.mode)
        defaults.removeObject(forKey: AppPreferences.endpoint)
        credentialsLoaded = false
        cachedCredentials = .empty
        if previousMode == .remote, !isDemo {
            snapshotCache.clear()
            let store = credentialStore
            Task.detached(priority: .utility) {
                try? store.setAtomically([
                    (SecretKey.remoteAccessClientID, ""),
                    (SecretKey.remoteAccessClientSecret, ""),
                    (SecretKey.remoteBridgeToken, "")
                ])
            }
        }
        applyActivationPolicy()
        // Lets observers such as due-date alerts drop anything that belonged to the old role.
        onSnapshotChange?(.empty)
    }

    /// Watches the system events that should trigger a sync: waking from sleep, the network
    /// returning, the app becoming active, the day changing, and (on a bridge) Reminders changing.
    func observeSystemEvents() {
        guard systemObservers.isEmpty, !isDemo else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        func observe(_ notificationCenter: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (AppState) -> Void) {
            let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
            systemObservers.append(token)
        }

        observe(workspace, NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { state in
            state.isSystemAsleep = false
            state.dayDidChange()
            state.syncSoon()
        }
        observe(center, NSApplication.didBecomeActiveNotification) { state in
            state.isAppActive = true
            state.syncSoon(ifOlderThan: .seconds(5))
        }
        observe(center, NSApplication.didResignActiveNotification) { $0.isAppActive = false }
        observe(center, .NSCalendarDayChanged) { $0.dayDidChange() }
        observe(center, .NSSystemTimeZoneDidChange) { $0.dayDidChange() }
        observe(center, .NSSystemClockDidChange) { $0.dayDidChange() }
        observe(center, Notification.Name("EKEventStoreChangedNotification")) { $0.reminderStoreDidChange() }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if satisfied, self.networkWasUnavailable {
                    self.syncSoon()
                }
                self.networkWasUnavailable = !satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "TaskFerry.NetworkPath"))
        pathMonitor = monitor
    }

    /// Syncs now and restarts the polling timer, e.g. after waking or regaining the network.
    func syncSoon(ifOlderThan age: Duration? = nil) {
        guard mode == .bridge || hasRemoteService, !isDemo else { return }
        if let age, let last = lastRefreshStartedAt, Date().timeIntervalSince(last) < age.seconds { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh(showLoadingIndicator: false)
            if self.mode == .remote {
                self.startAutomaticRefresh()
            }
        }
    }

    /// EventKit posts a change for edits made anywhere: Reminders.app, iCloud sync, or this bridge.
    /// Bursts are coalesced into one local refresh, so the bridge window and Dock badge stay current.
    private func reminderStoreDidChange() {
        guard mode == .bridge else { return }
        storeChangeTask?.cancel()
        storeChangeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            await self?.refresh(showLoadingIndicator: false)
        }
    }

    // MARK: - Sync

    @discardableResult
    func refresh(showLoadingIndicator: Bool = true) async -> Bool {
        if let refreshTask {
            // Join the sync already in flight instead of reporting a stale result.
            let succeeded = await refreshTask.value
            if !succeeded, showLoadingIndicator, errorMessage == nil, let message = lastFailureMessage {
                setError(message, source: .refresh)
            }
            return succeeded
        }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performRefresh(interactive: showLoadingIndicator)
        }
        refreshTask = task
        let succeeded = await task.value
        if refreshTask == task {
            refreshTask = nil
        }
        return succeeded
    }

    @ObservationIgnored private var lastFailureMessage: String?

    private func performRefresh(interactive: Bool) async -> Bool {
        lastRefreshStartedAt = Date()
        await start()
        if isDemo, mode == .remote, demoScenario == .unconfigured, endpoint.isEmpty { return false }
        if isDemo, demoScenario == .loading {
            connectionState = .loading
            return false
        }
        if isDemo, demoScenario == .offline {
            consecutiveSyncFailures = 1
            connectionState = .failed
            errorMessage = String(localized: "Demo: the bridge is offline. Your last-synced reminders are shown.")
            return false
        }
        if interactive && !hasLoadedSnapshot || snapshot == .empty && !isShowingCachedSnapshot {
            connectionState = .loading
        }
        let outcome = await operations.execute(.snapshot) { [weak self] outcome in
            self?.apply(outcome, source: .refresh, interactive: interactive)
        }
        return outcome.succeeded
    }

    @discardableResult
    func createReminder(title: String, listID: String, due: ReminderDue?, notes: String? = nil) async -> MutationOutcome {
        let knownIDs = Set(snapshot.reminders.map(\.id))
        var outcome = await perform(RPCRequest(operation: .upsertReminder, title: title, notes: notes, listID: listID, due: due))
        if outcome.succeeded, outcome.createdID == nil {
            // Bridges older than protocol 2 don't report the new identifier.
            outcome.createdID = snapshot.reminders.first { !knownIDs.contains($0.id) && $0.title == title.trimmed }?.id
        }
        return outcome
    }

    @discardableResult
    func updateReminder(
        _ reminder: ReminderRecord,
        title: String,
        listID: String,
        due: ReminderDue?,
        notes: String? = nil
    ) async -> Bool {
        await perform(RPCRequest(
            operation: .upsertReminder,
            id: reminder.id,
            title: title,
            notes: notes,
            listID: listID,
            due: due
        )).succeeded
    }

    /// Moves reminders to another list, keeping everything else exactly as it was.
    @discardableResult
    func move(_ reminders: [ReminderRecord], toList listID: String) async -> Bool {
        var succeeded = true
        for reminder in reminders where reminder.listID != listID {
            succeeded = await updateReminder(reminder, title: reminder.title, listID: listID, due: reminder.due) && succeeded
        }
        return succeeded
    }

    /// Gives reminders a new date. A time of day is kept, as when rescheduling in Reminders.
    @discardableResult
    func reschedule(_ reminders: [ReminderRecord], to option: QuickDueOption) async -> Bool {
        var succeeded = true
        for reminder in reminders {
            var due = option.due()
            if var newDue = due, let old = reminder.due, old.hasTime {
                newDue.hour = old.hour
                newDue.minute = old.minute
                newDue.timeZoneIdentifier = old.timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier
                due = newDue
            }
            guard due != reminder.due else { continue }
            succeeded = await updateReminder(reminder, title: reminder.title, listID: reminder.listID, due: due) && succeeded
        }
        return succeeded
    }

    @discardableResult
    func complete(_ reminder: ReminderRecord) async -> Bool {
        await setCompleted(reminderID: reminder.id, true)
    }

    @discardableResult
    func setCompleted(reminderID: String, _ completed: Bool) async -> Bool {
        await perform(RPCRequest(operation: .setCompleted, id: reminderID, completed: completed)).succeeded
    }

    @discardableResult
    func deleteReminder(_ reminder: ReminderRecord) async -> Bool {
        await perform(RPCRequest(operation: .deleteReminder, id: reminder.id)).succeeded
    }

    @discardableResult
    func createList(title: String, colorHex: String? = nil) async -> MutationOutcome {
        let knownIDs = Set(snapshot.lists.map(\.id))
        var outcome = await perform(RPCRequest(operation: .upsertList, title: title, colorHex: colorHex))
        if outcome.succeeded, outcome.createdID == nil {
            // Protocol-1 bridges return the updated snapshot without a created identifier.
            let candidates = snapshot.lists.filter { !knownIDs.contains($0.id) && $0.title == title.trimmed }
            // Don't navigate to an arbitrary list if another client created the same title.
            if candidates.count == 1 { outcome.createdID = candidates[0].id }
        }
        return outcome
    }

    @discardableResult
    func renameList(_ list: ReminderListRecord, title: String, colorHex: String? = nil) async -> Bool {
        await perform(RPCRequest(operation: .upsertList, id: list.id, title: title, colorHex: colorHex)).succeeded
    }

    @discardableResult
    func deleteList(_ list: ReminderListRecord) async -> Bool {
        await perform(RPCRequest(operation: .deleteList, id: list.id)).succeeded
    }

    func navigate(to destination: NavigationRequest.Destination) {
        navigationRequest = NavigationRequest(destination: destination)
    }

    // MARK: - Configuration

    func saveRemoteConfiguration(endpoint: String, clientID: String, clientSecret: String, bridgeToken: String) async throws {
        let configuration = try RemoteConfiguration(
            endpoint: endpoint,
            accessClientID: clientID,
            accessClientSecret: clientSecret,
            bridgeToken: bridgeToken
        )
        if !isDemo {
            let store = credentialStore
            try await Task.detached(priority: .userInitiated) {
                try store.setAtomically([
                    (SecretKey.remoteAccessClientID, configuration.accessClientID),
                    (SecretKey.remoteAccessClientSecret, configuration.accessClientSecret),
                    (SecretKey.remoteBridgeToken, configuration.bridgeToken)
                ])
            }.value
        }
        cachedCredentials = StoredCredentials(
            accessClientID: configuration.accessClientID,
            accessClientSecret: configuration.accessClientSecret,
            bridgeToken: configuration.bridgeToken,
            tunnelToken: ""
        )
        credentialsLoaded = true
        let endpointChanged = self.endpoint != configuration.endpoint.absoluteString
        self.endpoint = configuration.endpoint.absoluteString
        if endpointChanged {
            snapshotCache.clear()
        }
        if mode == .remote { configureService(for: .remote) }
    }

    func loadStoredCredentials() async throws -> StoredCredentials {
        if isDemo || credentialsLoaded { return cachedCredentials }
        let store = credentialStore
        let mode = mode
        // Only a Mac that was actually connected as a remote has a legacy connection to move: it
        // has an endpoint and never set up Cloudflare as a bridge.
        let mayMigrateLegacy = cloudflareProvisioning == nil && !endpoint.isEmpty
        let credentials = try await Task.detached(priority: .userInitiated) {
            try Self.readCredentials(from: store, mode: mode, mayMigrateLegacy: mayMigrateLegacy)
        }.value
        // A connection saved while this read was pending is newer. Keep it.
        guard !credentialsLoaded else { return cachedCredentials }
        cachedCredentials = credentials
        credentialsLoaded = true
        return credentials
    }

    nonisolated private static func readCredentials(
        from store: any CredentialStore,
        mode: AppMode?,
        mayMigrateLegacy: Bool
    ) throws -> StoredCredentials {
        switch mode {
        case .remote:
            var credentials = StoredCredentials(
                accessClientID: try store.read(SecretKey.remoteAccessClientID),
                accessClientSecret: try store.read(SecretKey.remoteAccessClientSecret),
                bridgeToken: try store.read(SecretKey.remoteBridgeToken),
                tunnelToken: ""
            )
            // Versions before role-scoped items stored a remote's connection in the shared
            // accounts. Move it once, but never adopt credentials that belong to a bridge.
            if credentials.bridgeToken.isEmpty, mayMigrateLegacy {
                let legacy = StoredCredentials(
                    accessClientID: try store.read(SecretKey.accessClientID),
                    accessClientSecret: try store.read(SecretKey.accessClientSecret),
                    bridgeToken: try store.read(SecretKey.bridgeToken),
                    tunnelToken: ""
                )
                if !legacy.bridgeToken.isEmpty {
                    try store.setAtomically([
                        (SecretKey.remoteAccessClientID, legacy.accessClientID),
                        (SecretKey.remoteAccessClientSecret, legacy.accessClientSecret),
                        (SecretKey.remoteBridgeToken, legacy.bridgeToken)
                    ])
                    try? store.setAtomically([
                        (SecretKey.accessClientID, ""),
                        (SecretKey.accessClientSecret, ""),
                        (SecretKey.bridgeToken, "")
                    ])
                    credentials = legacy
                }
            }
            return credentials
        case .bridge:
            return StoredCredentials(
                accessClientID: try store.read(SecretKey.accessClientID),
                accessClientSecret: try store.read(SecretKey.accessClientSecret),
                bridgeToken: try store.read(SecretKey.bridgeToken),
                tunnelToken: try store.read(SecretKey.tunnelToken)
            )
        case nil:
            return .empty
        }
    }

    @discardableResult
    func regenerateBridgeToken() async throws -> String {
        if isDemo { return bridgeToken }
        let token = try await generateAndStoreBridgeToken()
        if mode == .bridge { configureService(for: .bridge) }
        return token
    }

    func setRunsInBackground(_ enabled: Bool) {
        runsInBackground = enabled
        if !isDemo {
            defaults.set(enabled, forKey: AppPreferences.runsInBackground)
        }
        applyActivationPolicy()
    }

    func setShowsDockBadge(_ enabled: Bool) {
        showsDockBadge = enabled
        if !isDemo {
            defaults.set(enabled, forKey: AppPreferences.showsDockBadge)
        }
        reportDockBadge()
    }

    func setDockBadgeScope(_ scope: DockBadgeScope) {
        dockBadgeScope = scope
        if !isDemo {
            defaults.set(scope.rawValue, forKey: AppPreferences.dockBadgeScope)
        }
        reportDockBadge()
    }

    func setKeepsOfflineCopy(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppPreferences.keepsOfflineCopy)
        if enabled {
            saveCachedSnapshot()
        } else {
            snapshotCache.clear()
        }
    }

    func saveCloudflareProvisioning(_ result: CloudflareProvisioningResult) async throws {
        guard !isDemo else { throw ReminderServiceError.message("Cloudflare provisioning is disabled in demo mode.") }
        guard mode == .bridge else {
            throw ReminderServiceError.message("Cloudflare setup must be completed on the reminders bridge Mac.")
        }
        let store = credentialStore
        try await Task.detached(priority: .userInitiated) {
            try store.setAtomically([
                (SecretKey.accessClientID, result.secrets.accessClientID),
                (SecretKey.accessClientSecret, result.secrets.accessClientSecret),
                (SecretKey.tunnelToken, result.secrets.tunnelToken)
            ])
        }.value
        let data = try JSONEncoder().encode(result.provisioning)
        defaults.set(data, forKey: AppPreferences.cloudflareProvisioning)
        cachedCredentials.accessClientID = result.secrets.accessClientID
        cachedCredentials.accessClientSecret = result.secrets.accessClientSecret
        cachedCredentials.tunnelToken = result.secrets.tunnelToken
        credentialsLoaded = true
        cloudflareConnector.start(token: result.secrets.tunnelToken)
    }

    func removeStoredCloudflareProvisioning() async throws {
        guard !isDemo else { throw ReminderServiceError.message("Cloudflare provisioning is disabled in demo mode.") }
        let store = credentialStore
        try await Task.detached(priority: .userInitiated) {
            try store.setAtomically([
                (SecretKey.accessClientID, ""),
                (SecretKey.accessClientSecret, ""),
                (SecretKey.tunnelToken, "")
            ])
        }.value
        cachedCredentials.accessClientID = ""
        cachedCredentials.accessClientSecret = ""
        cachedCredentials.tunnelToken = ""
        defaults.removeObject(forKey: AppPreferences.cloudflareProvisioning)
        cloudflareConnector.stop()
    }

    func connectionCode() throws -> String {
        guard mode == .bridge, let provisioning = cloudflareProvisioning else {
            throw ReminderServiceError.message("Set up Cloudflare before copying a connection code.")
        }
        guard !accessClientID.isEmpty, !accessClientSecret.isEmpty, !bridgeToken.isEmpty else {
            throw ReminderServiceError.message("Task Ferry could not load all connection credentials from Keychain.")
        }
        return try TaskFerryConnectionCode(
            endpoint: "https://\(provisioning.hostname)",
            accessClientID: accessClientID,
            accessClientSecret: accessClientSecret,
            bridgeToken: bridgeToken
        ).encoded()
    }

    func saveConnectionCode(_ code: String) async throws {
        let connection = try TaskFerryConnectionCode.decode(code)
        try await saveRemoteConfiguration(
            endpoint: connection.endpoint,
            clientID: connection.accessClientID,
            clientSecret: connection.accessClientSecret,
            bridgeToken: connection.bridgeToken
        )
    }

    func stopCloudflareConnector() {
        cloudflareConnector.stop()
    }

    func startCloudflareConnector() {
        guard !isDemo, mode == .bridge, !tunnelToken.isEmpty else { return }
        cloudflareConnector.start(token: tunnelToken)
    }

    /// Stops a connector left behind by a crash, whatever role this Mac has now.
    func cleanUpOrphanedConnector() {
        guard !isDemo else { return }
        cloudflareConnector.cleanUpOrphan()
    }

    /// Stops everything that must not outlive the app, such as the cloudflared child process.
    func prepareForTermination() {
        cloudflareConnector.stop()
        bridge?.stop()
        pathMonitor?.cancel()
    }

    func dismissError() {
        clearError()
    }

    func applyActivationPolicy() {
        guard !isDemo else { return }
        let policy: NSApplication.ActivationPolicy = mode == .bridge && runsInBackground ? .accessory : .regular
        guard NSApplication.shared.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
    }

    // MARK: - Private

    private func restoreCachedSnapshot() {
        guard !isDemo, keepsOfflineCopy, !endpoint.isEmpty,
              let entry = snapshotCache.load(endpoint: endpoint) else { return }
        snapshot = entry.snapshot
        isShowingCachedSnapshot = true
        lastSuccessfulSync = entry.savedAt
    }

    private func saveCachedSnapshot() {
        guard mode == .remote, !isDemo, keepsOfflineCopy, hasLoadedSnapshot, !endpoint.isEmpty else { return }
        let entry = SnapshotCache.Entry(endpoint: endpoint, savedAt: lastSuccessfulSync ?? Date(), snapshot: snapshot)
        let cache = snapshotCache
        Task { await cache.save(entry) }
    }

    private func configureDemoService(for mode: AppMode) {
        let service = demoService ?? DemoReminderService(scenario: demoScenario)
        demoService = service
        operations.replaceService(service)
        cachedCredentials = StoredCredentials(accessClientID: "DEMO-CLIENT", accessClientSecret: "DEMO-SECRET",
            bridgeToken: "DEMO-BRIDGE-TOKEN", tunnelToken: "")
        credentialsLoaded = true
        isStarted = true
        connectionState = .connected
        bridgeState = mode == .bridge ? .running(8788) : .stopped
        if demoScenario == .offline {
            snapshot = service.initialSnapshot
            isShowingCachedSnapshot = true
            lastSuccessfulSync = Date().addingTimeInterval(-3600)
        }
        if demoScenario == .provisionedBridge { cloudflareConnectorState = .connected }
    }

    private func prepareService(for mode: AppMode, generation: Int) async {
        if isDemo { configureDemoService(for: mode); return }
        do {
            _ = try await loadStoredCredentials()
        } catch {
            // Never treat an unreadable Keychain as an empty one: on a bridge that would replace
            // the token every paired Mac depends on.
            guard startGeneration == generation, self.mode == mode, !Task.isCancelled else { return }
            setError(error.localizedDescription, source: .configuration)
            return
        }
        guard startGeneration == generation, self.mode == mode, !Task.isCancelled else { return }

        if mode == .bridge, bridgeToken.isEmpty {
            do {
                try await ensureBridgeToken()
            } catch {
                guard startGeneration == generation, self.mode == mode, !Task.isCancelled else { return }
                configureService(for: mode)
                setError(error.localizedDescription, source: .configuration)
                isStarted = true
                return
            }
        }

        guard startGeneration == generation, self.mode == mode, !Task.isCancelled else { return }
        configureService(for: mode)
        isStarted = true
    }

    private func ensureBridgeToken() async throws {
        guard bridgeToken.isEmpty else { return }
        _ = try await generateAndStoreBridgeToken()
    }

    private func generateAndStoreBridgeToken() async throws -> String {
        if isDemo { return "DEMO-BRIDGE-TOKEN" }
        let store = credentialStore
        let token = try await Task.detached(priority: .userInitiated) {
            let token = try store.randomToken()
            try store.set(token, for: SecretKey.bridgeToken)
            return token
        }.value
        cachedCredentials.bridgeToken = token
        credentialsLoaded = true
        return token
    }

    private func configureService(for mode: AppMode) {
        if isDemo { configureDemoService(for: mode); return }
        stopAutomaticRefresh()
        // A sync still running against the previous service can only end as superseded. Don't let
        // new refreshes join it, and don't carry its failures over to the new connection.
        refreshTask = nil
        consecutiveSyncFailures = 0
        lastFailureMessage = nil
        hasRemoteService = false
        bridge?.stop()
        bridge = nil
        switch mode {
        case .bridge:
            let localService = bridgeService ?? serviceFactory.makeBridgeService()
            bridgeService = localService
            operations.replaceService(localService)
            let token = bridgeToken
            guard !token.isEmpty else {
                setError("Could not create a bridge token in Keychain.", source: .configuration)
                return
            }
            let server = serviceFactory.makeBridgeServer(operations, token)
            server.onStateChange = { [weak self] newState in
                self?.bridgeState = newState
            }
            server.start(port: port)
            bridge = server
            if tunnelToken.isEmpty {
                cloudflareConnector.stop()
            } else {
                cloudflareConnector.start(token: tunnelToken)
            }
            if errorSource == .configuration { clearError() }
        case .remote:
            cloudflareConnector.stop()
            guard !endpoint.isEmpty else {
                operations.replaceService(nil)
                connectionState = .idle
                return
            }
            do {
                let configuration = try RemoteConfiguration(
                    endpoint: endpoint,
                    accessClientID: accessClientID,
                    accessClientSecret: accessClientSecret,
                    bridgeToken: bridgeToken
                )
                operations.replaceService(serviceFactory.makeRemoteService(configuration))
                hasRemoteService = true
                connectionState = isShowingCachedSnapshot ? .loading : .idle
                startAutomaticRefresh()
                if errorSource == .configuration { clearError() }
            } catch {
                operations.replaceService(nil)
                connectionState = .idle
                setError(error.localizedDescription, source: .configuration)
            }
        }
    }

    private func startAutomaticRefresh() {
        guard mode == .remote, hasRemoteService, !isDemo else { return }
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextRefreshDelay() else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                if self.isSystemAsleep { continue }
                await self.refresh(showLoadingIndicator: false)
            }
        }
    }

    /// Polls often while someone is looking and backs off while the app is in the background or
    /// the bridge is unreachable. Waking, reconnecting, and activating trigger an immediate sync.
    private func nextRefreshDelay() -> Duration {
        var delay = automaticRefreshInterval
        if !isAppActive {
            delay *= 4
        }
        if consecutiveSyncFailures > 0 {
            let backoff = automaticRefreshInterval * (1 << min(consecutiveSyncFailures, 5))
            delay = max(delay, min(backoff, automaticRefreshInterval * 20))
        }
        return delay
    }

    private func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    private func perform(_ request: RPCRequest) async -> MutationOutcome {
        let outcome = await operations.execute(request) { [weak self] outcome in
            self?.apply(outcome, source: .mutation, interactive: true)
        }
        return MutationOutcome(succeeded: outcome.succeeded, createdID: outcome.result?.createdID)
    }

    private func apply(
        _ outcome: ReminderOperationCoordinator.Outcome,
        source: ErrorSource,
        interactive: Bool
    ) {
        switch outcome {
        case .success(let result):
            if snapshot != result.snapshot {
                snapshot = result.snapshot
            }
            hasLoadedSnapshot = true
            isShowingCachedSnapshot = false
            lastSuccessfulSync = Date()
            consecutiveSyncFailures = 0
            lastFailureMessage = nil
            connectionState = .connected
            if interactive || errorSource == source || errorSource == .refresh {
                clearError()
            }
            onSnapshotChange?(result.snapshot)
            saveCachedSnapshot()
        case .failure(let message):
            lastFailureMessage = message
            if source == .refresh {
                consecutiveSyncFailures += 1
            }
            let isQuietBackgroundFailure = source == .refresh
                && !interactive
                && (hasLoadedSnapshot || isShowingCachedSnapshot)
                && consecutiveSyncFailures < Self.quietFailureLimit
            if !isQuietBackgroundFailure {
                setError(message, source: source)
            }
        case .unavailable:
            connectionState = .idle
            setError("Finish configuring the remote connection in Settings.", source: .configuration)
        case .superseded:
            break
        }
    }

    private func setError(_ message: String, source: ErrorSource) {
        connectionState = .failed
        errorMessage = message
        errorSource = source
    }

    private func clearError() {
        errorMessage = nil
        errorSource = nil
    }

    nonisolated private static func sortReminders(_ lhs: ReminderRecord, _ rhs: ReminderRecord) -> Bool {
        switch (lhs.due?.date(), rhs.due?.date()) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
        }
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
