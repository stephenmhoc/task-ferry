import Foundation

/// Owns the active reminder service, loopback listener, and connector independently of windows.
@MainActor
final class ReminderConnection {
    private let operations = ReminderOperationCoordinator()
    private let factory: ReminderServiceFactory
    private let connector: CloudflareTunnelConnector
    private var bridge: BridgeServer?
    private var localService: (any ReminderService)?
    private(set) var hasRemoteService = false
    var onBridgeStateChange: ((BridgeServer.State) -> Void)?

    init(factory: ReminderServiceFactory, connector: CloudflareTunnelConnector) {
        self.factory = factory
        self.connector = connector
    }

    func configureBridge(token: String, port: UInt16, tunnelToken: String) {
        bridge?.stop()
        bridge = nil
        hasRemoteService = false
        let service = localService ?? factory.makeBridgeService()
        localService = service
        operations.replaceService(service)
        guard !token.isEmpty else { return }
        let server = factory.makeBridgeServer(operations, token)
        server.onStateChange = { [weak self] state in self?.onBridgeStateChange?(state) }
        bridge = server
        server.start(port: port)
        if tunnelToken.isEmpty { connector.stop() } else { connector.start(token: tunnelToken) }
    }

    func configureRemote(_ configuration: RemoteConfiguration?) {
        stop()
        guard let configuration else { return }
        operations.replaceService(factory.makeRemoteService(configuration))
        hasRemoteService = true
    }

    func configureDemo(_ service: DemoReminderService) {
        operations.replaceService(service)
    }

    func execute(_ request: RPCRequest,
                 apply: @escaping @MainActor @Sendable (ReminderOperationCoordinator.Outcome) -> Void = { _ in }) async -> ReminderOperationCoordinator.Outcome {
        await operations.execute(request, apply: apply)
    }

    func stop(forgetLocalService: Bool = false) {
        bridge?.stop()
        bridge = nil
        connector.stop()
        operations.replaceService(nil)
        hasRemoteService = false
        if forgetLocalService { localService = nil }
    }

    func startConnector(token: String) { connector.start(token: token) }
    func stopConnector() { connector.stop() }
    func cleanUpOrphanedConnector() { connector.cleanUpOrphan() }
}
