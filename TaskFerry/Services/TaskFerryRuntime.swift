import Foundation

/// One boundary for UI development. Demo preferences never share the installed app's domain.
@MainActor
enum TaskFerryRuntime {
    nonisolated static var isDemo: Bool { ProcessInfo.processInfo.environment["TASK_FERRY_DEMO"] == "1" }
    static let preferences: UserDefaults = isDemo ? makeDemoPreferences() : .standard

    static func makeDemoPreferences() -> UserDefaults {
        let name = "com.merimerimeri.TaskFerry.Demo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.register(defaults: [AppPreferences.showsQuickEntryInMenuBar: true,
                                     AppPreferences.showsBridgeStatusInMenuBar: true])
        return defaults
    }
}

enum DemoScenario: String {
    case standard, unconfigured, empty, loading, offline, mutationFailure = "mutation-failure", longContent = "long-content", provisionedBridge = "provisioned-bridge", unfinishedCleanup = "unfinished-cleanup"
    static var current: Self {
        Self(rawValue: ProcessInfo.processInfo.environment["TASK_FERRY_DEMO_SCENARIO"] ?? "") ?? .standard
    }
}
