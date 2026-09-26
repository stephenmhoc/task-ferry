import Foundation

@MainActor
final class RemoteReminderService: ReminderService {
    private let configuration: RemoteConfiguration
    private let session: URLSession
    /// The newest protocol the bridge has advertised. Retrying a mutation is only safe once the
    /// bridge has shown that it deduplicates by `requestID`.
    private var bridgeProtocolVersion = 1

    init(configuration: RemoteConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? Self.makeSession()
    }

    func execute(_ rpc: RPCRequest) async throws -> RPCResult {
        var rpc = rpc
        if rpc.operation != .snapshot, rpc.requestID == nil {
            rpc.requestID = UUID().uuidString
        }
        do {
            return try await send(rpc)
        } catch let error as AmbiguousDelivery {
            // The request may or may not have been applied. Snapshots are always safe to repeat.
            // A mutation is only repeated when the bridge will recognize its requestID and skip
            // applying it twice.
            guard rpc.operation == .snapshot || bridgeProtocolVersion >= 2 else { throw error.underlying }
            do {
                return try await send(rpc)
            } catch let retryError as AmbiguousDelivery {
                throw retryError.underlying
            }
        }
    }

    private func send(_ rpc: RPCRequest) async throws -> RPCResult {
        let url = configuration.endpoint.appending(path: "v1/rpc")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.bridgeToken)", forHTTPHeaderField: "Authorization")
        if !configuration.accessClientID.isEmpty {
            request.setValue(configuration.accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
        }
        if !configuration.accessClientSecret.isEmpty {
            request.setValue(configuration.accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        request.httpBody = try JSONEncoder().encode(rpc)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            throw AmbiguousDelivery(underlying: error)
        }
        // A gateway or bridge timeout means the bridge may still finish applying the request.
        if let status = (response as? HTTPURLResponse)?.statusCode, [408, 502, 504, 524].contains(status) {
            throw AmbiguousDelivery(underlying: ReminderServiceError.message(Self.message(forStatus: status)))
        }
        let decoded = try Self.decodeResponse(data: data, response: response)
        // A bridge that was rolled back stops advertising the newer protocol.
        bridgeProtocolVersion = decoded.protocolVersion ?? 1
        guard let snapshot = decoded.snapshot else {
            throw ReminderServiceError.message("The bridge response did not include reminders.")
        }
        return RPCResult(snapshot: snapshot, createdID: decoded.createdID)
    }

    static func decode(data: Data, response: URLResponse) throws -> ReminderSnapshot {
        let decoded = try decodeResponse(data: data, response: response)
        guard let snapshot = decoded.snapshot else {
            throw ReminderServiceError.message("The bridge response did not include reminders.")
        }
        return snapshot
    }

    private static func decodeResponse(data: Data, response: URLResponse) throws -> RPCResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ReminderServiceError.message("The bridge returned an invalid response.")
        }
        let decoded = try? JSONDecoder().decode(RPCResponse.self, from: data)
        if let error = decoded?.error {
            throw ReminderServiceError.message(error)
        }
        guard http.statusCode == 200 else {
            throw ReminderServiceError.message(message(forStatus: http.statusCode))
        }
        guard let decoded else {
            throw ReminderServiceError.message("The bridge returned invalid JSON.")
        }
        return decoded
    }

    private static func message(forStatus status: Int) -> String {
        switch status {
        case 401, 403:
            "The bridge rejected this Mac’s credentials. Paste a new connection code from the bridge Mac."
        case 408, 524:
            "The bridge took too long to answer. Refresh to see whether the change was saved."
        case 502, 503, 504, 530:
            "The bridge Mac isn’t reachable. Make sure Task Ferry is running there."
        default:
            "The bridge returned HTTP \(status)."
        }
    }

    /// A failure after which the bridge may or may not have applied the request.
    private struct AmbiguousDelivery: Error {
        let underlying: any Error
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
