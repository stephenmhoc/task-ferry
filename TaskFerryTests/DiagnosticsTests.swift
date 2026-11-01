import XCTest

@MainActor
final class DiagnosticsTests: XCTestCase {
    override func tearDown() async throws {
        Diagnostics.reporter = nil
    }

    func testReportCarriesOnlyTheTypeAndCode() {
        let error = NSError(domain: "EKErrorDomain", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Could not save “Call the oncologist”",
            NSURLErrorFailingURLErrorKey: URL(string: "https://bridge.example.com/v1/rpc")!,
        ])

        let report = DiagnosticReport(area: .reminderOperation, step: "upsertReminder", error: error)

        XCTAssertEqual(report.domain, "EKErrorDomain")
        XCTAssertEqual(report.code, 7)
        XCTAssertFalse(String(describing: report).contains("oncologist"))
        XCTAssertFalse(String(describing: report).contains("bridge.example.com"))
    }

    func testBridgeResponseReportOmitsItsMessage() {
        let error = ReminderServiceError.unexpectedBridgeResponse("The bridge returned HTTP 500.", status: 500)

        let report = DiagnosticReport(area: .reminderOperation, step: "snapshot", error: error)

        XCTAssertEqual(report.domain, "TaskFerry.BridgeResponse")
        XCTAssertEqual(report.code, 500)
        XCTAssertEqual(error.localizedDescription, "The bridge returned HTTP 500.")
    }

    func testRoutineFailuresAreNotReported() {
        XCTAssertFalse(Diagnostics.isReminderFailureReportable(URLError(.notConnectedToInternet)))
        XCTAssertFalse(Diagnostics.isReminderFailureReportable(URLError(.timedOut)))
        XCTAssertFalse(Diagnostics.isReminderFailureReportable(CancellationError()))
        XCTAssertFalse(Diagnostics.isReminderFailureReportable(ReminderServiceError.message("That reminder changed elsewhere.")))
    }

    func testFaultsAreReported() {
        XCTAssertTrue(Diagnostics.isReminderFailureReportable(URLError(.badServerResponse)))
        XCTAssertTrue(Diagnostics.isReminderFailureReportable(ReminderServiceError.unexpectedBridgeResponse("", status: 200)))
        XCTAssertTrue(Diagnostics.isReminderFailureReportable(NSError(domain: "EKErrorDomain", code: 1)))
    }

    func testRateLimiterSendsEachFailureOnceAnHour() {
        var limiter = DiagnosticRateLimiter()
        let start = Date()

        XCTAssertTrue(limiter.allows(["a"], at: start))
        XCTAssertFalse(limiter.allows(["a"], at: start.addingTimeInterval(3599)))
        XCTAssertTrue(limiter.allows(["b"], at: start.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allows(["a"], at: start.addingTimeInterval(3600)))
    }

    func testRepeatedFailureIsReportedOnce() {
        var reports: [DiagnosticReport] = []
        Diagnostics.reporter = { reports.append($0) }
        let step = UUID().uuidString

        Diagnostics.report(.bridgeListener, step: step, error: NSError(domain: "Test", code: 1))
        Diagnostics.report(.bridgeListener, step: step, error: NSError(domain: "Test", code: 1))

        XCTAssertEqual(reports.map(\.step), [step])
    }

    func testModalWaitIsDroppedOnlyFromHangs() {
        let modal = ["main", "-[NSAlert runModal]", "-[NSApplication _doModalLoop:peek:]"]

        XCTAssertTrue(isModalWaitReportedAsHang(exceptionType: "App Hanging", mechanismType: "AppHang", frameFunctions: modal))
        XCTAssertFalse(isModalWaitReportedAsHang(exceptionType: "App Hanging", mechanismType: "AppHang", frameFunctions: ["main", "-[EKEventStore saveReminder:commit:error:]"]))
        XCTAssertFalse(isModalWaitReportedAsHang(exceptionType: "EXC_BAD_ACCESS", mechanismType: "mach", frameFunctions: modal))
    }
}
