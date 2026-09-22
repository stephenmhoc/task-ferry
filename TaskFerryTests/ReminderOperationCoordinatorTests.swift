import XCTest

@MainActor
final class ReminderOperationCoordinatorTests: XCTestCase {
    func testSerializesServiceExecutions() async {
        let service = ConcurrencyTrackingService()
        let coordinator = ReminderOperationCoordinator(service: service)

        async let first = coordinator.execute(.snapshot)
        async let second = coordinator.execute(.snapshot)
        _ = await (first, second)

        XCTAssertEqual(service.maximumActiveExecutions, 1)
        XCTAssertEqual(service.executionCount, 2)
    }

    func testReturnsServiceFailure() async {
        let coordinator = ReminderOperationCoordinator(service: FailingReminderService())

        let outcome = await coordinator.execute(.snapshot)

        XCTAssertEqual(outcome, .failure("Expected failure"))
    }
}

@MainActor
private final class ConcurrencyTrackingService: ReminderService {
    private(set) var executionCount = 0
    private(set) var maximumActiveExecutions = 0
    private var activeExecutions = 0

    func execute(_ request: RPCRequest) async throws -> RPCResult {
        executionCount += 1
        activeExecutions += 1
        maximumActiveExecutions = max(maximumActiveExecutions, activeExecutions)
        try await Task.sleep(for: .milliseconds(20))
        activeExecutions -= 1
        return RPCResult(snapshot: .empty)
    }
}

@MainActor
private final class FailingReminderService: ReminderService {
    func execute(_ request: RPCRequest) async throws -> RPCResult {
        throw ReminderServiceError.message("Expected failure")
    }
}
