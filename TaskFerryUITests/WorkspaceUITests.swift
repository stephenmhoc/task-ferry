import XCTest

/// The daily journey on demo data, which never leaves this machine. One test on purpose: don't add
/// checks for individual controls here.
final class WorkspaceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testAddEditAndComplete() {
        let app = XCUIApplication()
        app.launch()
        app.activate()

        // An app launched this way doesn't open its window itself, because of the menu bar extra.
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 3) { app.typeKey("n", modifierFlags: [.command, .option]) }
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // The sidebar button stays beside the traffic lights.
        let toggle = app.buttons["Hide Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let open = toggle.frame.minX
        toggle.click()
        let show = app.buttons["Show Sidebar"]
        XCTAssertTrue(show.waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(show.frame.minX, open, accuracy: 1)
        show.click()
        Thread.sleep(forTimeInterval: 0.6)

        // The floating + is a real button, and starts an empty row to type into.
        let add = app.buttons["New Reminder"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        let title = "Journey \(UUID().uuidString.prefix(6))"
        app.typeText(title + "\r")
        let row = reminder(title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "new reminder isn't listed")

        // Leave the next empty row, then rename the reminder in place.
        app.typeKey(.escape, modifierFlags: [])
        row.click()
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(title) edited\r")
        let edited = reminder("\(title) edited", in: app)
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "edit wasn't saved")

        edited.click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(edited.waitForNonExistence(timeout: 5), "completed reminder is still listed")
    }

    /// A row reads as one element that starts with its title.
    @MainActor private func reminder(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
