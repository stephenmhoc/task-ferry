import Foundation

@MainActor
final class ReminderOperationCoordinator {
    enum Outcome: Equatable, Sendable {
        case success(RPCResult)
        case failure(String)
        case unavailable
        case superseded

        var succeeded: Bool {
            if case .success = self { return true }
            return false
        }

        var result: RPCResult? {
            if case .success(let result) = self { return result }
            return nil
        }
    }

    private var service: (any ReminderService)?
    private var generation = 0
    private var tail: Task<Void, Never>?

    init(service: (any ReminderService)? = nil) {
        self.service = service
    }

    func replaceService(_ service: (any ReminderService)?) {
        generation += 1
        self.service = service
        tail = nil
    }

    func execute(
        _ request: RPCRequest,
        apply: @escaping @MainActor @Sendable (Outcome) -> Void = { _ in }
    ) async -> Outcome {
        let requestGeneration = generation
        let requestService = service
        let predecessor = tail
        let task = Task { @MainActor [weak self] () -> Outcome in
            await predecessor?.value
            guard let self, requestGeneration == generation else { return .superseded }
            guard let requestService else {
                let outcome = Outcome.unavailable
                apply(outcome)
                return outcome
            }

            let outcome: Outcome
            let finishTiming = Diagnostics.beginOperation(request.operation)
            do {
                outcome = .success(try await requestService.execute(request))
                finishTiming(true)
            } catch {
                finishTiming(false)
                if Diagnostics.isReminderFailureReportable(error) {
                    Diagnostics.report(.reminderOperation, step: request.operation.rawValue, error: error)
                }
                outcome = .failure(error.localizedDescription)
            }
            guard requestGeneration == generation else { return .superseded }
            apply(outcome)
            return outcome
        }
        tail = Task { @MainActor in
            _ = await task.value
        }
        return await task.value
    }
}
