import XCTest
final class ProtocolTests: XCTestCase {
    func testRPCRequestRoundTrip() throws {
        let due = ReminderDue(year: 2026, month: 7, day: 21, hour: 9, minute: 30, timeZoneIdentifier: "America/New_York")
        let request = RPCRequest(
            operation: .upsertReminder,
            id: "abc",
            title: "Call dentist",
            notes: "Ask about the new office.",
            listID: "personal",
            due: due
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)

        XCTAssertEqual(decoded.operation, .upsertReminder)
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertEqual(decoded.title, "Call dentist")
        XCTAssertEqual(decoded.notes, "Ask about the new office.")
        XCTAssertEqual(decoded.listID, "personal")
        XCTAssertEqual(decoded.due, due)
    }

    func testReminderNotesRoundTrip() throws {
        let snapshot = ReminderSnapshot(
            lists: [ReminderListRecord(id: "personal", title: "Personal", colorHex: "5E5CE6")],
            reminders: [
                ReminderRecord(
                    id: "abc",
                    listID: "personal",
                    title: "Call dentist",
                    notes: "Ask about the new office.",
                    due: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: data)

        XCTAssertEqual(decoded.reminders.first?.notes, "Ask about the new office.")
    }

    func testReminderWithoutNotesRemainsDecodable() throws {
        let data = Data(
            #"{"lists":[],"reminders":[{"id":"abc","listID":"personal","title":"Call dentist","due":null}]}"#.utf8
        )

        let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: data)

        XCTAssertNil(decoded.reminders.first?.notes)
    }

    func testRequestWithoutNotesRemainsDecodable() throws {
        let data = Data(
            #"{"operation":"upsertReminder","id":"abc","title":"Call dentist","listID":"personal"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)

        XCTAssertNil(decoded.notes)
    }

    func testSnapshotPreservesDefaultList() throws {
        let snapshot = ReminderSnapshot(
            lists: [ReminderListRecord(id: "personal", title: "Personal", colorHex: "5E5CE6")],
            reminders: [],
            defaultListID: "personal"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: data)

        XCTAssertEqual(decoded.defaultListID, "personal")
    }

    func testSnapshotWithoutDefaultListRemainsDecodable() throws {
        let data = Data(#"{"lists":[],"reminders":[]}"#.utf8)

        let decoded = try JSONDecoder().decode(ReminderSnapshot.self, from: data)

        XCTAssertNil(decoded.defaultListID)
    }

    func testHTTPRequestWaitsForCompleteBody() throws {
        let body = try JSONEncoder().encode(RPCRequest.snapshot)
        let header = "POST /v1/rpc HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAuthorization: Bearer test\r\n\r\n"
        var complete = Data(header.utf8)
        complete.append(body)

        XCTAssertNil(HTTPRequest.parse(complete.dropLast()))
        let request = try XCTUnwrap(HTTPRequest.parse(complete))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/rpc")
        XCTAssertEqual(request.headers["authorization"], "Bearer test")
        XCTAssertEqual(request.body, body)
    }

    func testHTTPRequestRejectsChunkedBodies() {
        let request = Data("POST /v1/rpc HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        XCTAssertNil(HTTPRequest.parse(request))
        guard case .malformed = HTTPRequest.parseResult(request) else {
            return XCTFail("Expected an immediately malformed request")
        }
    }

    func testHTTPRequestRejectsDuplicateContentLength() {
        let request = Data("POST /v1/rpc HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8)

        guard case .malformed = HTTPRequest.parseResult(request) else {
            return XCTFail("Expected duplicate framing headers to be rejected")
        }
    }

    func testHTTPRequestRejectsTrailingBytes() {
        let request = Data("POST /v1/rpc HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra".utf8)

        guard case .malformed = HTTPRequest.parseResult(request) else {
            return XCTFail("Expected trailing bytes to be rejected")
        }
    }

    func testHTTPRequestRejectsOversizedBodyBeforeReadingIt() {
        let request = Data("POST /v1/rpc HTTP/1.1\r\nContent-Length: \(HTTPRequest.maximumBodyBytes + 1)\r\n\r\n".utf8)

        guard case .tooLarge = HTTPRequest.parseResult(request) else {
            return XCTFail("Expected an oversized body declaration to be rejected")
        }
    }
}
