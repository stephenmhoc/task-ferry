import Foundation
import XCTest

@MainActor
final class RemoteResponseTests: XCTestCase {
    func testDecodesErrorBodyBeforeGenericHTTPStatus() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/v1/rpc")!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = try JSONEncoder().encode(RPCResponse(error: "That reminder changed elsewhere."))

        XCTAssertThrowsError(try RemoteReminderService.decode(data: data, response: response)) { error in
            XCTAssertEqual(error.localizedDescription, "That reminder changed elsewhere.")
        }
    }

    func testUsesGenericStatusWhenErrorBodyIsInvalid() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/v1/rpc")!,
            statusCode: 502,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(try RemoteReminderService.decode(data: Data("gateway".utf8), response: response)) { error in
            XCTAssertEqual(error.localizedDescription, "The bridge Mac isn’t reachable. Make sure Task Ferry is running there.")
        }
    }

    func testDecodesSuccessfulSnapshot() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/v1/rpc")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let expected = ReminderSnapshot(
            lists: [ReminderListRecord(id: "personal", title: "Personal", colorHex: "5E5CE6")],
            reminders: [],
            defaultListID: "personal"
        )
        let data = try JSONEncoder().encode(RPCResponse(snapshot: expected))

        XCTAssertEqual(try RemoteReminderService.decode(data: data, response: response), expected)
    }
}
