import Foundation
import XCTest

/// Exercises the production Network.framework listener over real localhost TCP sockets.
/// Only its reminder store is substituted; no EventKit, Keychain or tunnel is used.
@MainActor
final class BridgeServerIntegrationTests: XCTestCase {
    private let token = UUID().uuidString

    func testListenerStartsOnLoopbackAndServesAuthenticatedSnapshot() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let response = try await send(.snapshot, port: port)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body.protocolVersion, RPCRequest.currentProtocolVersion)
        XCTAssertEqual(response.body.snapshot?.lists.count, 2)
        XCTAssertEqual(response.body.snapshot?.reminders.count, 4)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier),
                             "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let listeners = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(listeners.map(String.init), ["n127.0.0.1:\(port)"])
        print("Bridge smoke: listening only on 127.0.0.1:\(port); authenticated snapshot returned HTTP 200")
    }

    func testHTTPValidationAndAuthentication() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let missing = try await send(.snapshot, port: port, authorization: "")
        XCTAssertEqual(missing.status, 401)
        XCTAssertNil(missing.body.snapshot)
        let wrong = try await send(.snapshot, port: port, authorization: "Bearer invalid-test-token")
        XCTAssertEqual(wrong.status, 401)
        let route = try await send(.snapshot, port: port, path: "/missing")
        XCTAssertEqual(route.status, 404)
        let mediaType = try await send(.snapshot, port: port, contentType: "text/plain")
        XCTAssertEqual(mediaType.status, 415)
        let invalidJSON = try await send(.snapshot, port: port, body: Data("not json".utf8))
        XCTAssertEqual(invalidJSON.status, 400)
        let oversized = try await send(.snapshot, port: port, body: Data(repeating: 65, count: HTTPRequest.maximumBodyBytes + 1))
        XCTAssertEqual(oversized.status, 413)
        // Bad requests must not poison subsequent valid requests.
        let valid = try await send(.snapshot, port: port)
        XCTAssertEqual(valid.status, 200)
    }

    func testReminderLifecycleOverHTTPPreservesCalendarDueComponents() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let list = try await send(RPCRequest(operation: .upsertList, title: "Backend smoke list"), port: port)
        XCTAssertEqual(list.status, 200)
        let listID = try XCTUnwrap(list.body.createdID)
        let due = ReminderDue(year: 2026, month: 10, day: 4)
        let created = try await send(RPCRequest(operation: .upsertReminder, title: "Backend smoke reminder", notes: "In memory only", listID: listID, due: due), port: port)
        XCTAssertEqual(created.status, 200)
        let id = try XCTUnwrap(created.body.createdID)
        XCTAssertEqual(created.body.snapshot?.reminders.first { $0.id == id }?.due, due)
        let edited = try await send(RPCRequest(operation: .upsertReminder, id: id, title: "Updated smoke reminder", notes: "Updated notes", listID: listID, due: due), port: port)
        XCTAssertEqual(edited.body.snapshot?.reminders.first { $0.id == id }?.title, "Updated smoke reminder")
        XCTAssertEqual(edited.body.snapshot?.reminders.first { $0.id == id }?.due, due)
        let completed = try await send(RPCRequest(operation: .setCompleted, id: id, completed: true), port: port)
        XCTAssertEqual(completed.status, 200)
        XCTAssertFalse(completed.body.snapshot?.reminders.contains { $0.id == id } ?? true)
        let restored = try await send(RPCRequest(operation: .setCompleted, id: id, completed: false), port: port)
        XCTAssertEqual(restored.body.snapshot?.reminders.first { $0.id == id }?.due, due)
        let deleted = try await send(RPCRequest(operation: .deleteReminder, id: id), port: port)
        XCTAssertEqual(deleted.status, 200)
        XCTAssertFalse(deleted.body.snapshot?.reminders.contains { $0.id == id } ?? true)
        let removedList = try await send(RPCRequest(operation: .deleteList, id: listID), port: port)
        XCTAssertEqual(removedList.status, 200)
        XCTAssertEqual(removedList.body.snapshot?.lists.count, 2)
        XCTAssertEqual(removedList.body.snapshot?.reminders.count, 4)
    }

    func testStopClosesSocketAndSamePortCanRestart() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        server.stop()
        XCTAssertEqual(server.state, .stopped)
        // Network.framework cancels the listening socket asynchronously.
        var refused = false
        for _ in 0..<50 {
            do { _ = try await send(.snapshot, port: port) }
            catch { refused = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(refused, "The socket must reject requests after shutdown")
        server.start(port: port)
        try await waitForReady(server, port: port)
        let response = try await send(.snapshot, port: port)
        XCTAssertEqual(response.status, 200)
        print("Bridge smoke: stopped, refused connections, and restarted on the same port")
    }

    func testListenerReturnsUnavailableWithoutAService() async throws {
        let coordinator = ReminderOperationCoordinator()
        let (server, port) = try await startServer(operations: coordinator)
        defer { server.stop() }
        let unavailable = try await send(.snapshot, port: port)
        XCTAssertEqual(unavailable.status, 503)
        XCTAssertNil(unavailable.body.snapshot)
        coordinator.replaceService(DemoReminderService())
        let recovered = try await send(.snapshot, port: port)
        XCTAssertEqual(recovered.status, 200)
    }

    private func startServer(operations: ReminderOperationCoordinator? = nil) async throws -> (BridgeServer, UInt16) {
        let port = ProcessInfo.processInfo.environment["TASK_FERRY_BRIDGE_TEST_PORT"].flatMap(UInt16.init)
            ?? UInt16.random(in: 49_152...60_000)
        let server = BridgeServer(operations: operations ?? ReminderOperationCoordinator(service: DemoReminderService()), token: token)
        server.start(port: port)
        do { try await waitForReady(server, port: port) }
        catch { server.stop(); throw error }
        return (server, port)
    }

    private func waitForReady(_ server: BridgeServer, port: UInt16) async throws {
        for _ in 0..<250 {
            if server.state == .running(port) { return }
            if case .failed(let message) = server.state { throw ReminderServiceError.message(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ReminderServiceError.message("Listener did not become ready: \(server.state)")
    }

    private func send(_ rpc: RPCRequest, port: UInt16, authorization: String? = nil,
                      path: String = "/v1/rpc", contentType: String = "application/json",
                      body: Data? = nil) async throws -> (status: Int, body: RPCResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorization ?? "Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try body ?? JSONEncoder().encode(rpc)
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, try JSONDecoder().decode(RPCResponse.self, from: data))
    }
}
