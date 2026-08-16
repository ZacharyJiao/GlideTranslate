import AppKit
import XCTest

final class AccessibilityAndMotionTests: XCTestCase {
    @MainActor
    func testResultPanelExposesStableAccessibilityMetadata() throws {
        let app = try launch(motionArgument: "--ui-testing-reduce-motion")
        defer { app.terminate() }
        showPanel()

        XCTAssertTrue(app.descendants(matching: .any)["result-panel"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["result-output-heading"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["result-output"].exists)
        let source = app.staticTexts["result-source"]
        XCTAssertTrue(source.exists)
        XCTAssertEqual(source.label, "Source text")
        XCTAssertEqual(source.value as? String, "focus-fixture-source")
        XCTAssertTrue(app.buttons["result-copy"].exists)
        XCTAssertTrue(app.buttons["result-retry"].exists)
        XCTAssertTrue(app.buttons["result-change-preset"].exists)
        XCTAssertTrue(app.buttons["result-pin"].exists)
        XCTAssertTrue(app.buttons["result-close"].exists)
    }

    @MainActor
    func testReducedMotionBranchIsExposedWithoutChangingPanelState() throws {
        let app = try launch(motionArgument: "--ui-testing-reduce-motion")
        defer { app.terminate() }
        showPanel()

        XCTAssertTrue(app.descendants(matching: .any)["result-motion-reduced"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["result-output"].exists)
    }

    @MainActor
    func testStandardMotionBranchIsExposedWithoutChangingPanelState() throws {
        let app = try launch(motionArgument: "--ui-testing-standard-motion")
        defer { app.terminate() }
        showPanel()

        XCTAssertTrue(app.descendants(matching: .any)["result-motion-standard"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["result-output"].exists)
    }

    @MainActor
    private func launch(motionArgument: String) throws -> XCUIApplication {
        continueAfterFailure = false
        let passivePanelReadyProbe = DistributedNotificationProbe(
            name: FocusFixtureController.passivePanelReadySignal
        )
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-testing-passive-panel",
            motionArgument,
        ]
        app.launch()
        guard app.wait(for: .runningBackground, timeout: 5) else {
            app.terminate()
            throw XCTSkip("MANUAL_BLOCKED_GUI_SESSION: accessory app did not launch")
        }
        guard waitUntil({ passivePanelReadyProbe.receivedCount == 1 }) else {
            app.terminate()
            XCTFail("Passive-panel UI-test fixture did not acknowledge observer readiness")
            throw FixtureLaunchError.passivePanelObserverNotReady
        }
        return app
    }

    @MainActor
    private func showPanel() {
        DistributedNotificationCenter.default().post(
            name: FocusFixtureController.showPanelSignal,
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

private enum FixtureLaunchError: Error {
    case passivePanelObserverNotReady
}
