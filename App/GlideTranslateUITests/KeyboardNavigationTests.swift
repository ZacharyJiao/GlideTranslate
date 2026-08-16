import AppKit
import XCTest

final class KeyboardNavigationTests: XCTestCase {
    @MainActor
    func testResultPanelCommandCopyAndEscape() throws {
        let app = try launch(arguments: ["--ui-testing-passive-panel"])
        defer { app.terminate() }
        let copyProbe = DistributedNotificationProbe(
            name: FocusFixtureController.copyCompletedSignal
        )

        post(FocusFixtureController.showPanelSignal)
        let panel = app.descendants(matching: .any)["result-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.click()

        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(waitUntil { copyProbe.receivedCount == 1 })

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !panel.exists })
    }

    @MainActor
    func testManualInputCommandReturnSubmitsWithoutUsingClipboard() throws {
        let submitProbe = DistributedNotificationProbe(
            name: FocusFixtureController.manualSubmitCompletedSignal
        )
        let app = try launch(arguments: ["--ui-testing-open-manual"])
        defer { app.terminate() }

        let input = app.textViews["manual.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 2),
            "Manual-input launch argument must permit the app to become foreground"
        )
        input.click()
        input.typeText("synthetic manual input")
        app.typeKey(.return, modifierFlags: .command)

        XCTAssertTrue(waitUntil { submitProbe.receivedCount == 1 })
    }

    @MainActor
    private func launch(arguments: [String]) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 5)
                || app.wait(for: .runningForeground, timeout: 1),
            "Argument-specific UI-test app failed to launch"
        )
        return app
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().post(
            name: name,
            object: nil,
            userInfo: nil
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }
}
