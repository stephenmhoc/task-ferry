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
        let toggle = app.buttons["Toggle Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // The sidebar button stays beside the traffic lights.
        let open = toggle.frame.minX
        toggle.click()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(toggle.frame.minX, open, accuracy: 1)
        toggle.click()
        Thread.sleep(forTimeInterval: 0.6)

        app.typeKey("n", modifierFlags: .command)
        let title = "Journey \(UUID().uuidString.prefix(6))"
        app.typeText(title + "\r")
        let row = reminder(title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "new reminder isn't listed")

        row.doubleClick()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(title) edited\r")
        let edited = reminder("\(title) edited", in: app)
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "edit wasn't saved")

        edited.click()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(edited.waitForNonExistence(timeout: 5), "completed reminder is still listed")
    }

    /// A row reads as one element that starts with its title.
    @MainActor private func reminder(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
