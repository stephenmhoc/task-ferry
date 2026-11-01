import Foundation
import Sentry

/// Sends crashes, hangs, and the failures in ``Diagnostics`` to Sentry from released builds. Task
/// Ferry carries people's reminders and connection secrets, so this only turns on what can't
/// contain them: every source that records URLs, screen contents, or free-form text stays off.
@MainActor
enum CrashReporting {
    private static var dsn: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String)?.trimmed
        return value?.isEmpty == false ? value : nil
    }

    /// Local builds have no DSN, so they can't report. A released app run as a demo doesn't either.
    static var isAvailable: Bool { dsn != nil && !TaskFerryRuntime.isDemo }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferences.sendsCrashReports) as? Bool ?? true
    }

    static func start() {
        guard isAvailable, isEnabled, !SentrySDK.isEnabled, let dsn else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "production"
            options.sendDefaultPii = false

            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            // AppKit swallows exceptions raised in the run loop unless this is on.
            options.enableUncaughtNSExceptionReporting = true
            options.enableAutoSessionTracking = true

            // Off because each can record URLs, file paths, or request details. A failed request's
            // URL is a private tunnel hostname, and its headers hold the bridge token.
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableFileIOTracing = false
            options.enableAutoBreadcrumbTracking = false
            options.tracePropagationTargets = []

            // Only the reminder operations timed in ReminderOperationCoordinator are traced.
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = 0.1

            options.beforeSend = { event in
                let exception = event.exceptions?.first
                let isModalWait = isModalWaitReportedAsHang(
                    exceptionType: exception?.type,
                    mechanismType: exception?.mechanism?.type,
                    frameFunctions: exception?.stacktrace?.frames.compactMap(\.function) ?? []
                )
                return isModalWait ? nil : event
            }
        }
        Diagnostics.reporter = send
        Diagnostics.operationTracer = startOperation
    }

    static func stop() {
        Diagnostics.reporter = nil
        Diagnostics.operationTracer = nil
        SentrySDK.close()
    }

    static func setEnabled(_ enabled: Bool, role: AppMode?) {
        UserDefaults.standard.set(enabled, forKey: AppPreferences.sendsCrashReports)
        if enabled {
            start()
            setRole(role)
        } else {
            stop()
        }
    }

    /// The same app is either side of a connection, so every event says which it was.
    static func setRole(_ role: AppMode?) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.configureScope { $0.setTag(value: role?.rawValue ?? "unconfigured", key: "role") }
    }

    private static func send(_ report: DiagnosticReport) {
        let error = NSError(domain: report.domain, code: report.code,
                            userInfo: [NSDebugDescriptionErrorKey: report.title])
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: report.area.rawValue, key: "area")
            scope.setTag(value: report.step, key: "step")
            scope.setFingerprint(report.fingerprint)
        }
    }

    private static func startOperation(_ name: String) -> (Bool) -> Void {
        let transaction = SentrySDK.startTransaction(name: "rpc.\(name)", operation: "rpc")
        return { succeeded in transaction.finish(status: succeeded ? .ok : .internalError) }
    }
}
