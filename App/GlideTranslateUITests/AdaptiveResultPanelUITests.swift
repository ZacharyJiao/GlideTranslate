import AppKit
import XCTest

final class AdaptiveResultPanelUITests: XCTestCase {
    @MainActor
    func testAdaptivePanelShowsCollapsedSourceDisclosureAndSelectableOutput() throws {
        let app = try launch()
        defer { app.terminate() }

        DistributedNotificationCenter.default().post(
            name: FocusFixtureController.showPanelSignal,
            object: nil,
            userInfo: nil
        )

        let panel = app.descendants(matching: .any)["result-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["result-source-disclosure"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["result-output"].exists)
        XCTAssertTrue(app.buttons["result-copy"].exists)
    }

    @MainActor
    func testAdaptivePanelExposesBackToLatestOnlyWhenReaderScrollsAway() throws {
        let app = try launch(longOutput: true)
        defer { app.terminate() }

        DistributedNotificationCenter.default().post(
            name: FocusFixtureController.showPanelSignal,
            object: nil,
            userInfo: nil
        )

        let panel = app.descendants(matching: .any)["result-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let output = app.descendants(matching: .any)["result-output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        output.swipeDown(velocity: .fast)
        let backToLatest = app.buttons["result-back-to-latest"]
        XCTAssertTrue(backToLatest.waitForExistence(timeout: 5))
        for identifier in ["result-copy", "result-retry", "result-close"] {
            let action = app.buttons[identifier]
            XCTAssertTrue(action.exists)
            XCTAssertTrue(
                panel.frame.contains(action.frame),
                "\(identifier) must remain fully inside the capped panel"
            )
            XCTAssertGreaterThanOrEqual(
                panel.frame.maxY - action.frame.maxY,
                12,
                "\(identifier) must preserve the panel's bottom padding"
            )
        }
        backToLatest.click()
        XCTAssertTrue(waitUntil { !backToLatest.exists })
    }

    @MainActor
    private func launch(longOutput: Bool = false) throws -> XCUIApplication {
        continueAfterFailure = false
        let readyProbe = DistributedNotificationProbe(
            name: FocusFixtureController.passivePanelReadySignal
        )
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-passive-panel"]
        if longOutput {
            app.launchArguments.append("--ui-testing-long-result")
        }
        app.launch()
        guard app.wait(for: .runningBackground, timeout: 5) else {
            app.terminate()
            throw AdaptivePanelFixtureLaunchError.didNotLaunch
        }
        guard waitUntil({ readyProbe.receivedCount == 1 }) else {
            app.terminate()
            throw AdaptivePanelFixtureLaunchError.observerNotReady
        }
        return app
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

private enum AdaptivePanelFixtureLaunchError: Error {
    case didNotLaunch
    case observerNotReady
}
