import XCTest

final class MenuBarCommandCenterUITests: XCTestCase {
    @MainActor
    func testEnglishSettingsKeepBrandHeaderInsideTheWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-testing-command-center",
            "-AppleLanguages",
            "(en)",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5)
                || app.wait(for: .runningBackground, timeout: 1)
        )
        let settingsButton = app.buttons["menu-command-settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        var languagePicker = app.popUpButtons["general.uiLanguage"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        languagePicker.click()
        let simplifiedChinese = app.menuItems["Simplified Chinese"]
        XCTAssertTrue(simplifiedChinese.waitForExistence(timeout: 2))
        simplifiedChinese.click()

        languagePicker = app.popUpButtons["general.uiLanguage"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        languagePicker.click()
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        languagePicker = app.popUpButtons["general.uiLanguage"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        XCTAssertEqual(languagePicker.value as? String, "English")

        let brandHeader = app.descendants(matching: .any)["settings.brand"]
        XCTAssertTrue(brandHeader.waitForExistence(timeout: 5))
        XCTAssertEqual(brandHeader.value as? String, "Glide Translate")
        let settingsWindow = app.windows.element(boundBy: 0)
        XCTAssertTrue(settingsWindow.exists)
        let windowFrame = settingsWindow.frame
        let brandFrame = brandHeader.frame
        XCTAssertGreaterThanOrEqual(
            brandFrame.minY,
            windowFrame.minY,
            "Brand frame \(brandFrame) escaped above settings window \(windowFrame)"
        )
        XCTAssertLessThanOrEqual(
            brandFrame.maxY,
            windowFrame.maxY,
            "Brand frame \(brandFrame) escaped below settings window \(windowFrame)"
        )
    }

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
