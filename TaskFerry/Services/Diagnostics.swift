import Foundation

/// The parts of the app that report their own failures. Each is a stable name, so a report says
/// where something went wrong without carrying anything the user wrote.
enum DiagnosticArea: String, Sendable {
    case reminderOperation = "reminder_operation"
    case bridgeListener = "bridge_listener"
    case cloudflareConnector = "cloudflare_connector"
    case cloudflareSetup = "cloudflare_setup"
    case credentials
    case globalHotKey = "global_hot_key"
}

/// Everything a handled failure sends: a place, an error type, and a code. Never add the error's
/// description or `userInfo`. They can hold reminder titles, tunnel hostnames, and request URLs.
struct DiagnosticReport: Equatable, Sendable {
    var area: DiagnosticArea
    var step: String
    var domain: String
    var code: Int

    init(area: DiagnosticArea, step: String, error: (any Error)?) {
        self.area = area
        self.step = step
        if case .unexpectedBridgeResponse(_, let status)? = error as? ReminderServiceError {
            domain = "TaskFerry.BridgeResponse"
            code = status
        } else if let error {
            let nsError = error as NSError
            domain = nsError.domain
            code = nsError.code
        } else {
            domain = "TaskFerry.Failure"
            code = 0
        }
    }

    var title: String { "\(area.rawValue).\(step)" }
    var fingerprint: [String] { [area.rawValue, step, domain, String(code)] }
}

/// Keeps failure reporting out of the core, which the tests build without Sentry. Only the app
/// target connects these hooks, and only in a released build, so everything here is a no-op
/// otherwise.
@MainActor
enum Diagnostics {
    static var reporter: ((DiagnosticReport) -> Void)?
    static var operationTracer: ((String) -> (Bool) -> Void)?
    private static var limiter = DiagnosticRateLimiter()

    static func report(_ area: DiagnosticArea, step: String, error: (any Error)? = nil) {
        guard let reporter, error.map(isReportable) ?? true else { return }
        let report = DiagnosticReport(area: area, step: step, error: error)
        guard limiter.allows(report.fingerprint, at: Date()) else { return }
        reporter(report)
    }

    /// Starts timing one reminder operation. Call the result with whether it succeeded.
    static func beginOperation(_ operation: RPCOperation) -> (Bool) -> Void {
        operationTracer?(operation.rawValue) ?? { _ in }
    }

    /// A Mac losing its network is normal, and the bridge's own failures are reported by the bridge.
    /// Messages written for the user, such as a reminder that changed elsewhere, aren't bugs.
    nonisolated static func isReminderFailureReportable(_ error: any Error) -> Bool {
        if case .message? = error as? ReminderServiceError { return false }
        return isReportable(error)
    }

    nonisolated static func isReportable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? URLError { return !expectedURLErrors.contains(error.code) }
        return true
    }

    nonisolated private static let expectedURLErrors: Set<URLError.Code> = [
        .cancelled, .timedOut, .networkConnectionLost, .notConnectedToInternet, .dataNotAllowed,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
        .callIsActive, .secureConnectionFailed,
    ]
}

/// A bridge runs unattended and a remote polls, so one lasting fault would otherwise repeat for
/// days. Each distinct failure goes out at most once an hour.
struct DiagnosticRateLimiter {
    static let interval: TimeInterval = 3600
    private var lastSent: [[String]: Date] = [:]

    mutating func allows(_ fingerprint: [String], at now: Date) -> Bool {
        if let last = lastSent[fingerprint], now.timeIntervalSince(last) < Self.interval { return false }
        lastSent[fingerprint] = now
        return true
    }
}

/// `NSAlert.runModal()` blocks the main thread in a nested run loop until someone answers it, which
/// the hang detector can't tell from a stall. Sparkle's prompts and the quit confirmation both do
/// this, so these reports are dropped here rather than by turning hang tracking off.
func isModalWaitReportedAsHang(exceptionType: String?, mechanismType: String?, frameFunctions: [String]) -> Bool {
    let isHang = mechanismType?.caseInsensitiveCompare("AppHang") == .orderedSame
        || exceptionType?.localizedCaseInsensitiveContains("hang") == true
    guard isHang else { return false }
    return frameFunctions.contains { function in
        let function = function.lowercased()
        return function.contains("runmodal") || function.contains("_domodalloop")
    }
}
