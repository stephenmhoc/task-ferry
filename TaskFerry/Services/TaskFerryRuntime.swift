import Foundation

/// One boundary for UI development. Demo preferences never share the installed app's domain.
@MainActor
enum TaskFerryRuntime {
    /// Local builds are demos unless they opt out with TASK_FERRY_DEMO=0, so running one can't
    /// change real reminders. The released app is a demo only if asked.
    nonisolated static var isDemo: Bool {
        let setting = ProcessInfo.processInfo.environment["TASK_FERRY_DEMO"]
        #if TASK_FERRY_DEV
        return setting != "0"
        #else
        return setting == "1"
        #endif
    }

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
    case standard, unconfigured, empty, loading, offline, links, mutationFailure = "mutation-failure", longContent = "long-content", provisionedBridge = "provisioned-bridge", unfinishedCleanup = "unfinished-cleanup"
    static var current: Self {
        Self(rawValue: ProcessInfo.processInfo.environment["TASK_FERRY_DEMO_SCENARIO"] ?? "") ?? .standard
    }
}
