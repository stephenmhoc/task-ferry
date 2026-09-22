import Foundation
import Network

@MainActor
final class BridgeServer {
    enum State: Equatable {
        case stopped
        case starting
        case running(UInt16)
        case failed(String)
    }

    private static let maximumConnections = 32
    private static let requestTimeout: Duration = .seconds(15)

    private let operations: ReminderOperationCoordinator
    private let token: String
    private let queue = DispatchQueue(label: "TaskFerry.Bridge")
    private var listener: NWListener?
    private var generation = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timeoutTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var ledger = RequestLedger()
    private var inFlightMutations: [String: Task<ReminderOperationCoordinator.Outcome, Never>] = [:]
    private var requestedPort: UInt16?
    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .stopped {
        didSet { onStateChange?(state) }
    }

    init(operations: ReminderOperationCoordinator, token: String) {
        self.operations = operations
        self.token = token
    }

    func start(port: UInt16) {
        stop()
        requestedPort = port
        listen(port: port)
    }

    private func listen(port: UInt16) {
        generation += 1
        let listenerGeneration = generation
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port) ?? 8788
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self,
                          let listener,
                          self.listener === listener,
                          self.generation == listenerGeneration else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection, generation: listenerGeneration)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] newState in
                Task { @MainActor [weak self, weak listener] in
                    guard let self,
                          let listener,
                          self.listener === listener,
                          self.generation == listenerGeneration else { return }
                    switch newState {
                    case .ready:
                        self.restartAttempt = 0
                        self.state = .running(port)
                    case .failed(let error):
                        self.state = .failed(error.localizedDescription)
                        self.scheduleRestart()
                    case .cancelled:
                        self.state = .stopped
                    default:
                        break
                    }
                }
            }
            state = .starting
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
            scheduleRestart()
        }
    }

    /// Retries a listener that failed, typically because another process briefly held the port,
    /// so a bridge left running unattended recovers without anyone opening its window.
    private func scheduleRestart() {
        guard let port = requestedPort else { return }
        restartTask?.cancel()
        restartAttempt += 1
        let delay = min(60, 1 << min(restartAttempt, 6))
        restartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.requestedPort == port else { return }
            // Connections from the failed listener can't be answered after the generation
            // changes, so close them rather than leave them counting against the limit.
            self.timeoutTasks.values.forEach { $0.cancel() }
            self.timeoutTasks.removeAll()
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.listen(port: port)
        }
    }

    func stop() {
        requestedPort = nil
        restartTask?.cancel()
        restartTask = nil
        restartAttempt = 0
        generation += 1
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        state = .stopped
    }

    private func accept(_ connection: NWConnection, generation: Int) {
        guard connections.count < Self.maximumConnections else {
            connection.start(queue: queue)
            respond(connection, status: 503, response: RPCResponse(error: "Bridge is busy."), tracked: false)
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard case .failed = newState else {
                if case .cancelled = newState {
                    Task { @MainActor [weak self, weak connection] in
                        guard let connection else { return }
                        self?.finish(connection)
                    }
                }
                return
            }
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                self?.finish(connection)
            }
        }
        timeoutTasks[identifier] = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(for: Self.requestTimeout)
            } catch {
                return
            }
            guard let self, let connection, self.generation == generation else { return }
            self.respond(connection, status: 408, response: RPCResponse(error: "Request timed out."))
        }
        receive(connection: connection, data: Data(), generation: generation)
        connection.start(queue: queue)
    }

    private func receive(connection: NWConnection, data: Data, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPRequest.maximumBodyBytes) {
            [weak self, weak connection] chunk, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self,
                      let connection,
                      self.generation == generation,
                      self.connections[ObjectIdentifier(connection)] != nil else { return }
                var accumulated = data
                if let chunk { accumulated.append(chunk) }
                switch HTTPRequest.parseResult(accumulated) {
                case .request(let request):
                    self.handle(request, connection: connection, generation: generation)
                case .tooLarge:
                    self.respond(connection, status: 413, response: RPCResponse(error: "Request too large."))
                case .malformed:
                    self.respond(connection, status: 400, response: RPCResponse(error: "Malformed request."))
                case .incomplete where error != nil || isComplete:
                    self.respond(connection, status: 400, response: RPCResponse(error: "Malformed request."))
                case .incomplete:
                    self.receive(connection: connection, data: accumulated, generation: generation)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection, generation: Int) {
        guard request.method == "POST", request.path == "/v1/rpc" else {
            respond(connection, status: 404, response: RPCResponse(error: "Not found."))
            return
        }
        let mediaType = request.headers["content-type"]?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json" else {
            respond(connection, status: 415, response: RPCResponse(error: "JSON required."))
            return
        }
        guard Self.securelyMatches(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            respond(connection, status: 401, response: RPCResponse(error: "Unauthorized."))
            return
        }

        let rpc: RPCRequest
        do {
            rpc = try JSONDecoder().decode(RPCRequest.self, from: request.body)
        } catch {
            respond(connection, status: 400, response: RPCResponse(error: "Invalid JSON."))
            return
        }

        Task { @MainActor [weak self, weak connection] in
            guard let self, let connection, self.generation == generation else { return }
            let outcome = await self.execute(rpc)
            guard self.generation == generation else {
                self.finish(connection)
                return
            }
            switch outcome {
            case .success(let result):
                self.respond(connection, status: 200, response: RPCResponse(
                    snapshot: result.snapshot,
                    createdID: result.createdID,
                    protocolVersion: RPCRequest.currentProtocolVersion
                ))
            case .failure(let message):
                self.respond(connection, status: 400, response: RPCResponse(error: message))
            case .unavailable, .superseded:
                self.respond(connection, status: 503, response: RPCResponse(error: "Bridge is unavailable."))
            }
        }
    }

    /// Applies a mutation at most once per `requestID`. A repeat gets a fresh snapshot and the
    /// identifier created the first time.
    private func execute(_ rpc: RPCRequest) async -> ReminderOperationCoordinator.Outcome {
        guard rpc.operation != .snapshot, let requestID = rpc.requestID else {
            return await operations.execute(rpc)
        }
        if let original = inFlightMutations[requestID] {
            // The original records its result before it finishes, so after waiting the ledger
            // always knows about it, whichever waiter resumes first.
            _ = await original.value
        }
        if let entry = ledger.entry(for: requestID) {
            let outcome = await operations.execute(.snapshot)
            guard case .success(var result) = outcome else { return outcome }
            result.createdID = entry.createdID
            return .success(result)
        }
        let task = Task { @MainActor [weak self, operations] () -> ReminderOperationCoordinator.Outcome in
            let outcome = await operations.execute(rpc)
            if case .success(let result) = outcome {
                self?.ledger.record(requestID, createdID: result.createdID)
            }
            return outcome
        }
        inFlightMutations[requestID] = task
        let outcome = await task.value
        if inFlightMutations[requestID] == task {
            inFlightMutations.removeValue(forKey: requestID)
        }
        return outcome
    }

    private func respond(_ connection: NWConnection, status: Int, response: RPCResponse, tracked: Bool = true) {
        let body = (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] _ in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                if tracked {
                    self?.finish(connection)
                } else {
                    connection.cancel()
                }
            }
        })
    }

    private func finish(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        timeoutTasks.removeValue(forKey: identifier)?.cancel()
        connections.removeValue(forKey: identifier)
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private static func securelyMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt64(left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= UInt64(leftByte ^ rightByte)
        }
        return difference == 0
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

enum HTTPRequestParseResult {
    case incomplete
    case request(HTTPRequest)
    case malformed
    case tooLarge
}

struct HTTPRequest {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard case .request(let request) = parseResult(data) else { return nil }
        return request
    }

    static func parseResult(_ data: Data) -> HTTPRequestParseResult {
        guard data.count <= maximumHeaderBytes + maximumBodyBytes else { return .tooLarge }
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else {
            return data.count > maximumHeaderBytes ? .tooLarge : .incomplete
        }
        guard range.lowerBound <= maximumHeaderBytes,
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return range.lowerBound > maximumHeaderBytes ? .tooLarge : .malformed
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .malformed }
        let requestLine = first.split(separator: " ")
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            return .malformed
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return .malformed }
            let name = String(parts[0]).lowercased()
            guard !name.isEmpty, headers[name] == nil else { return .malformed }
            headers[name] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let lengthText = headers["content-length"],
              let length = Int(lengthText),
              length >= 0 else {
            return .malformed
        }
        guard length <= maximumBodyBytes else { return .tooLarge }
        let bodyStart = range.upperBound
        let expectedLength = bodyStart + length
        guard data.count >= expectedLength else { return .incomplete }
        guard data.count == expectedLength else { return .malformed }
        return .request(HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(data[bodyStart..<expectedLength])
        ))
    }
}
