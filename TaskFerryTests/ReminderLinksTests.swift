import XCTest

final class ReminderLinksTests: XCTestCase {
    func testDetectionPreservesUnicodeAndLiteralMarkdown() {
        let text = "🛳️ **Read** https://example.com/path?q=1&b=2, then www.apple.com."
        let attributed = ReminderLinks.attributed(text)

        XCTAssertEqual(String(attributed.characters), text)
        let links = attributed.runs.compactMap { run -> String? in
            guard run[AttributeScopes.FoundationAttributes.LinkAttribute.self] != nil else { return nil }
            return String(attributed[run.range].characters)
        }
        XCTAssertEqual(links, ["https://example.com/path?q=1&b=2", "www.apple.com"])
        // Newer data detectors assume https for a bare www address; older ones assume http.
        let urls = ReminderLinks.urls(title: text, notes: nil)
        XCTAssertEqual(urls.map(\.absoluteString).first, "https://example.com/path?q=1&b=2")
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.last?.host(), "www.apple.com")
        XCTAssertTrue(["http", "https"].contains(urls.last?.scheme ?? ""))
    }

    func testMenusIncludeTruncatedLinksAndDeduplicateDestinations() {
        let notes = String(repeating: "A long note.\n", count: 20) + "https://example.org"
        let urls = ReminderLinks.urls(title: "https://example.com", notes: notes + " https://example.com",
                                     url: URL(string: "https://example.org"))

        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com", "https://example.org"])
    }

    func testPlainTextHasNoLinks() {
        XCTAssertTrue(ReminderLinks.urls(title: "Buy milk", notes: "At 4:30 tomorrow").isEmpty)
        XCTAssertTrue(ReminderLinks.attributed("Buy milk").runs.allSatisfy {
            $0[AttributeScopes.FoundationAttributes.LinkAttribute.self] == nil
        })
    }

    func testURLRoundTripAndLegacyDecode() throws {
        let reminder = ReminderRecord(id: "1", listID: "work", title: "Read", due: nil,
                                      url: URL(string: "https://example.com"))
        let data = try JSONEncoder().encode(reminder)
        XCTAssertEqual(try JSONDecoder().decode(ReminderRecord.self, from: data), reminder)

        let legacy = Data(#"{"id":"1","listID":"work","title":"Read"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ReminderRecord.self, from: legacy).url)
    }

    @MainActor
    func testEditingPreservesDedicatedURLAndDoesNotSaveUntouchedDraft() async {
        let reminder = ReminderRecord(id: "1", listID: "work", title: "Read", due: nil,
                                      url: URL(string: "https://example.com"))
        let session = ReminderEditSession(reminder)
        var saved = false
        let result = await session.commit { _ in saved = true; return nil }
        XCTAssertTrue(result)
        XCTAssertFalse(saved)
        let changed = ReminderEditSession(reminder)
        changed.title = "Read again"
        var savedValue: ReminderRecord?
        let changedResult = await changed.commit { savedValue = $0; return nil }
        XCTAssertTrue(changedResult)
        XCTAssertEqual(savedValue?.title, "Read again")
        XCTAssertEqual(savedValue?.url, reminder.url)
    }
}
