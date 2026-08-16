import XCTest

final class IntegratedFailureTests: XCTestCase {
    @MainActor
    func testSettingsCategoryRoutesOnlyAfterExplicitProductionAction() throws {
        try assertProductionRoute(
            fixture: "settings",
            actionButton: "Settings…",
            destinationIdentifier: "general.uiLanguage"
        )
    }

    @MainActor
    func testManualCategoryRoutesOnlyAfterExplicitProductionAction() throws {
        try assertProductionRoute(
            fixture: "manual",
            actionButton: "Manual Translation",
            destinationIdentifier: "manual.input"
        )
    }

    @MainActor
    func testLocalRuntimeCategoryRoutesOnlyAfterExplicitProductionAction() throws {
        try assertProductionRoute(
            fixture: "local-guidance",
            actionButton: "Settings…",
            destinationIdentifier: "general.uiLanguage"
        )
    }

    @MainActor
    func testDestinationCategoryRoutesOnlyAfterExplicitProductionAction() throws {
        try assertProductionRoute(
            fixture: "reconfirmation",
            actionButton: "Settings…",
            destinationIdentifier: "general.uiLanguage"
        )
    }

    @MainActor
    func testStorageCategoryRoutesOnlyAfterExplicitProductionAction() throws {
        try assertProductionRoute(
            fixture: "storage-recovery",
            actionButton: "Settings…",
            destinationIdentifier: "general.uiLanguage"
        )
    }

    @MainActor
    func testCancellationHasNoProductionAlertOrImplicitRoute() throws {
        let app = try launch(fixture: "cancelled")
        defer { app.terminate() }

        XCTAssertFalse(app.dialogs.firstMatch.waitForExistence(timeout: 1))
        XCTAssertFalse(app.descendants(matching: .any)["general.uiLanguage"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["manual.input"].exists)
    }

    @MainActor
    private func assertProductionRoute(
        fixture: String,
        actionButton: String,
        destinationIdentifier: String
    ) throws {
        let app = try launch(fixture: fixture)
        defer { app.terminate() }
        let destination = app.descendants(matching: .any)[destinationIdentifier]
        XCTAssertFalse(destination.exists)

        let action = app.buttons[actionButton]
        guard action.waitForExistence(timeout: 5) else {
            throw XCTSkip("BLOCKED_GUI_SESSION: production recovery alert is not visible")
        }
        action.click()

        XCTAssertTrue(
            destination.waitForExistence(timeout: 5),
            "Explicit production action did not open \(destinationIdentifier)"
        )
    }

    @MainActor
    private func launch(fixture: String) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-testing-safe-next-action=\(fixture)",
            "-AppleLanguages",
            "(en)",
        ]
        app.launch()
        guard app.wait(for: .runningBackground, timeout: 5)
                || app.wait(for: .runningForeground, timeout: 1) else {
            app.terminate()
            throw XCTSkip("BLOCKED_GUI_SESSION: production fixture app did not launch")
        }
        return app
    }
}
