import XCTest

final class MenuBarCommandCenterUITests: XCTestCase {
    @MainActor
    func testCommandCenterInventoryAndManualInputRoute() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-command-center"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5)
                || app.wait(for: .runningBackground, timeout: 1)
        )

        let commandCenter = app.descendants(matching: .any)["menu-command-center"]
        XCTAssertTrue(commandCenter.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["menu-command-translate"].exists)
        XCTAssertTrue(app.buttons["menu-command-manual"].exists)
        XCTAssertTrue(app.buttons["menu-command-settings"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["result-output"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["result-source"].exists)

        app.buttons["menu-command-manual"].click()
        XCTAssertTrue(app.textViews["manual.input"].waitForExistence(timeout: 5))
    }
}
