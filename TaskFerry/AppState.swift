import AppKit
import Foundation
import Observation

enum AppPreferences {
    static let mode = "mode"
    static let endpoint = "endpoint"
    static let port = "port"
    static let runsInBackground = "runs-in-background"
    static let cloudflareProvisioning = "cloudflare-provisioning"
    static let showsDockBadge = "shows-dock-badge"
    static let dockBadgeScope = "dock-badge-scope"
}

@MainActor
@Observable
final class AppState {
    struct StoredCredentials: Sendable {
        var accessClientID: String
        var accessClientSecret: String
        var bridgeToken: String
        var tunnelToken: String
    }

    enum ConnectionState: Equatable {
        case idle
        case loading
        case connected
        case failed
    }

    private enum SecretKey {
        static let accessClientID = "access-client-id"
        static let accessClientSecret = "access-client-secret"
        static let bridgeToken = "bridge-token"
        static let tunnelToken = "cloudflare-tunnel-token"
    }

    private enum ErrorSource: Equatable {
        case refresh
        case mutation
        case configuration
    }

    var mode: AppMode?
    var snapshot = ReminderSnapshot.empty
    private(set) var hasLoadedSnapshot = false
    var connectionState = ConnectionState.idle
    var bridgeState = BridgeServer.State.stopped
    var cloudflareConnectorState = CloudflareConnectorState.notConfigured
    var errorMessage: String?
    var runsInBackground: Bool
    var showsDockBadge: Bool
    var dockBadgeScope: DockBadgeScope

    @ObservationIgnored private let operations = ReminderOperationCoordinator()
    @ObservationIgnored private var bridge: BridgeServer?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var automaticRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private let automaticRefreshInterval: Duration
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let serviceFactory: ReminderServiceFactory
    @ObservationIgnored private let cloudflareConnector: CloudflareTunnelConnector
    @ObservationIgnored private var errorSource: ErrorSource?
    @ObservationIgnored private var demoEndpoint = "https://reminders.merimerimeri.com"
    @ObservationIgnored private var credentialsLoaded = false
    private var cachedCredentials = StoredCredentials(
        accessClientID: "",
        accessClientSecret: "",
        bridgeToken: "",
        tunnelToken: ""
    )

    var endpoint: String {
        get { isDemo ? demoEndpoint : defaults.string(forKey: AppPreferences.endpoint) ?? "https://reminders.merimerimeri.com" }
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
        guard let data = defaults.data(forKey: AppPreferences.cloudflareProvisioning) else { return nil }
        return try? JSONDecoder().decode(CloudflareProvisioning.self, from: data)
    }

    var cloudflareHostname: String? { cloudflareProvisioning?.hostname }

    init(
        isDemo: Bool? = nil,
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStore = KeychainStore(),
        serviceFactory: ReminderServiceFactory = .live,
        cloudflareConnector: CloudflareTunnelConnector = CloudflareTunnelConnector(),
        automaticRefreshInterval: Duration = .seconds(15)
    ) {
        let demoMode = isDemo ?? (ProcessInfo.processInfo.environment["TASK_FERRY_DEMO"] == "1")
        self.isDemo = demoMode
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.serviceFactory = serviceFactory
        self.cloudflareConnector = cloudflareConnector
        self.automaticRefreshInterval = automaticRefreshInterval
        runsInBackground = demoMode ? false : defaults.bool(forKey: AppPreferences.runsInBackground)
        showsDockBadge = defaults.object(forKey: AppPreferences.showsDockBadge) == nil
            ? true
            : defaults.bool(forKey: AppPreferences.showsDockBadge)
        dockBadgeScope = defaults.string(forKey: AppPreferences.dockBadgeScope)
            .flatMap(DockBadgeScope.init(rawValue:)) ?? .todayAndOverdue
        if demoMode {
            cachedCredentials = StoredCredentials(
                accessClientID: "",
                accessClientSecret: "",
                bridgeToken: "DEMO-DEMO-DEMO-DEMO-DEMO-DEMO",
                tunnelToken: ""
            )
            credentialsLoaded = true
            mode = ProcessInfo.processInfo.environment["TASK_FERRY_DEMO_ROLE"] == "bridge" ? .bridge : .remote
            operations.replaceService(DemoReminderService())
            isStarted = true
            connectionState = .connected
            if mode == .bridge {
                bridgeState = .running(8788)
            }
        } else if let value = defaults.string(forKey: AppPreferences.mode),
                  let savedMode = AppMode(rawValue: value) {
            mode = savedMode
        }
        cloudflareConnector.onStateChange = { [weak self] connectorState in
            self?.cloudflareConnectorState = connectorState
        }
    }

    var todayReminders: [ReminderRecord] {
        snapshot.reminders.filter { reminder in
            guard let due = reminder.due else { return false }
            return due.isBeforeDay(Date()) || due.isSameDay(as: Date())
        }.sorted(by: sortReminders)
    }

    var tomorrowReminders: [ReminderRecord] {
        guard let tomorrow = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date()) else { return [] }
        return snapshot.reminders.filter { $0.due?.isSameDay(as: tomorrow) == true }.sorted(by: sortReminders)
    }

    var allReminders: [ReminderRecord] {
        snapshot.reminders.sorted(by: sortReminders)
    }

    var dockBadgeCount: Int {
        dockBadgeCount(on: Date())
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

    func reminders(in listID: String) -> [ReminderRecord] {
        snapshot.reminders.filter { $0.listID == listID }.sorted(by: sortReminders)
    }

    func list(for id: String) -> ReminderListRecord? {
        snapshot.lists.first { $0.id == id }
    }

    func chooseMode(_ mode: AppMode) async {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: AppPreferences.mode)
        applyActivationPolicy()
        await start()
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

    func resetMode() {
        startGeneration += 1
        startTask?.cancel()
        startTask = nil
        stopAutomaticRefresh()
        cloudflareConnector.stop()
        bridge?.stop()
        bridge = nil
        bridgeState = .stopped
        operations.replaceService(nil)
        isStarted = false
        mode = nil
        snapshot = .empty
        hasLoadedSnapshot = false
        connectionState = .idle
        clearError()
        defaults.removeObject(forKey: AppPreferences.mode)
        applyActivationPolicy()
    }

    @discardableResult
    func refresh(showLoadingIndicator: Bool = true) async -> Bool {
        guard !isRefreshing else { return connectionState == .connected }
        isRefreshing = true
        defer { isRefreshing = false }
        await start()
        if showLoadingIndicator || snapshot == .empty {
            connectionState = .loading
        }
        let outcome = await operations.execute(.snapshot) { [weak self] outcome in
            self?.apply(outcome, source: .refresh, clearAllErrorsOnSuccess: showLoadingIndicator)
        }
        return outcome.succeeded
    }

    @discardableResult
    func createReminder(title: String, listID: String, due: ReminderDue?, notes: String? = nil) async -> Bool {
        await perform(RPCRequest(operation: .upsertReminder, title: title, notes: notes, listID: listID, due: due))
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
        ))
    }

    @discardableResult
    func complete(_ reminder: ReminderRecord) async -> Bool {
        await perform(RPCRequest(operation: .setCompleted, id: reminder.id, completed: true))
    }

    @discardableResult
    func deleteReminder(_ reminder: ReminderRecord) async -> Bool {
        await perform(RPCRequest(operation: .deleteReminder, id: reminder.id))
    }

    @discardableResult
    func createList(title: String) async -> Bool {
        await perform(RPCRequest(operation: .upsertList, title: title))
    }

    @discardableResult
    func renameList(_ list: ReminderListRecord, title: String) async -> Bool {
        await perform(RPCRequest(operation: .upsertList, id: list.id, title: title))
    }

    @discardableResult
    func deleteList(_ list: ReminderListRecord) async -> Bool {
        await perform(RPCRequest(operation: .deleteList, id: list.id))
    }

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
                    (SecretKey.accessClientID, configuration.accessClientID),
                    (SecretKey.accessClientSecret, configuration.accessClientSecret),
                    (SecretKey.bridgeToken, configuration.bridgeToken)
                ])
            }.value
        }
        cachedCredentials = StoredCredentials(
            accessClientID: configuration.accessClientID,
            accessClientSecret: configuration.accessClientSecret,
            bridgeToken: configuration.bridgeToken,
            tunnelToken: tunnelToken
        )
        credentialsLoaded = true
        self.endpoint = configuration.endpoint.absoluteString
        if mode == .remote { configureService(for: .remote) }
    }

    func loadStoredCredentials() async -> StoredCredentials {
        if isDemo || credentialsLoaded { return cachedCredentials }
        let store = credentialStore
        let credentials = await Task.detached(priority: .utility) {
            StoredCredentials(
                accessClientID: store.string(for: SecretKey.accessClientID),
                accessClientSecret: store.string(for: SecretKey.accessClientSecret),
                bridgeToken: store.string(for: SecretKey.bridgeToken),
                tunnelToken: store.string(for: SecretKey.tunnelToken)
            )
        }.value
        cachedCredentials = credentials
        credentialsLoaded = true
        return credentials
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
    }

    func setDockBadgeScope(_ scope: DockBadgeScope) {
        dockBadgeScope = scope
        if !isDemo {
            defaults.set(scope.rawValue, forKey: AppPreferences.dockBadgeScope)
        }
    }

    func saveCloudflareProvisioning(_ result: CloudflareProvisioningResult) async throws {
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
        endpoint = "https://\(result.provisioning.hostname)"
        cachedCredentials.accessClientID = result.secrets.accessClientID
        cachedCredentials.accessClientSecret = result.secrets.accessClientSecret
        cachedCredentials.tunnelToken = result.secrets.tunnelToken
        credentialsLoaded = true
        cloudflareConnector.start(token: result.secrets.tunnelToken)
    }

    func removeStoredCloudflareProvisioning() async throws {
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
        defaults.removeObject(forKey: AppPreferences.endpoint)
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
        guard mode == .bridge, !tunnelToken.isEmpty else { return }
        cloudflareConnector.start(token: tunnelToken)
    }

    func dismissError() {
        clearError()
    }

    func applyActivationPolicy() {
        guard !isDemo else { return }
        let policy: NSApplication.ActivationPolicy = mode == .bridge && runsInBackground ? .accessory : .regular
        NSApplication.shared.setActivationPolicy(policy)
    }

    private func prepareService(for mode: AppMode, generation: Int) async {
        _ = await loadStoredCredentials()
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
        stopAutomaticRefresh()
        bridge?.stop()
        bridge = nil
        switch mode {
        case .bridge:
            let localService = serviceFactory.makeBridgeService()
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
            do {
                let configuration = try RemoteConfiguration(
                    endpoint: endpoint,
                    accessClientID: accessClientID,
                    accessClientSecret: accessClientSecret,
                    bridgeToken: bridgeToken
                )
                operations.replaceService(serviceFactory.makeRemoteService(configuration))
                connectionState = .idle
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
        guard mode == .remote, !isDemo else { return }
        automaticRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.automaticRefreshInterval else { return }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.refresh(showLoadingIndicator: false)
            }
        }
    }

    private func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    private func perform(_ request: RPCRequest) async -> Bool {
        let outcome = await operations.execute(request) { [weak self] outcome in
            self?.apply(outcome, source: .mutation, clearAllErrorsOnSuccess: true)
        }
        return outcome.succeeded
    }

    private func apply(
        _ outcome: ReminderOperationCoordinator.Outcome,
        source: ErrorSource,
        clearAllErrorsOnSuccess: Bool
    ) {
        switch outcome {
        case .success(let snapshot):
            self.snapshot = snapshot
            hasLoadedSnapshot = true
            connectionState = .connected
            if clearAllErrorsOnSuccess || errorSource == source {
                clearError()
            }
        case .failure(let message):
            setError(message, source: source)
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

    private func sortReminders(_ lhs: ReminderRecord, _ rhs: ReminderRecord) -> Bool {
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
