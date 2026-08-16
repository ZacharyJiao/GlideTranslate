import AppKit
import XCTest

final class PassivePanelFocusTests: XCTestCase {
    @MainActor
    func testPassiveShowPreservesFrontmostProcessAndFocusedElement() throws {
        let harness = try launchHarness()
        defer { harness.close() }
        let beforePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let beforeFocusedIdentifier = harness.fixture.focusedElementIdentifier()

        harness.fixture.triggerSyntheticResultPanel()
        XCTAssertTrue(resultPanel(in: harness.app).waitForExistence(timeout: 5))

        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            beforePID
        )
        XCTAssertEqual(
            harness.fixture.focusedElementIdentifier(),
            beforeFocusedIdentifier
        )
        XCTAssertFalse(harness.fixture.didLoseFocus)
        XCTAssertFalse(glideTranslateIsActive)
    }

    @MainActor
    func testClickEnablesActionsCopyWorksAndEscapeClosesTemporary() throws {
        let harness = try launchHarness()
        defer { harness.close() }
        let copyProbe = DistributedNotificationProbe(
            name: FocusFixtureController.copyCompletedSignal
        )
        harness.fixture.triggerSyntheticResultPanel()
        let panel = resultPanel(in: harness.app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        panel.click()
        let copy = harness.app.buttons["result-copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.click()
        XCTAssertTrue(waitUntil { copyProbe.receivedCount == 1 })

        harness.app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !panel.exists })

        let fixtureApp = harness.fixture.app
        fixtureApp.activate()
        let field = fixtureApp.textFields[FocusFixtureController.fieldIdentifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        XCTAssertTrue(waitUntil { harness.fixture.didLoseFocus })
        XCTAssertNil(harness.fixture.focusedElementIdentifier())
    }

    @MainActor
    func testClickAwayClosesTemporaryWithoutClosingFixture() throws {
        let harness = try launchHarness()
        defer { harness.close() }
        harness.fixture.triggerSyntheticResultPanel()
        let panel = resultPanel(in: harness.app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        let fixtureApp = harness.fixture.app
        fixtureApp.activate()
        let field = fixtureApp.textFields[FocusFixtureController.fieldIdentifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()

        XCTAssertTrue(waitUntil { !panel.exists })
        XCTAssertTrue(harness.fixture.hasVisibleWindow())
    }

    @MainActor
    private func launchHarness() throws -> Harness {
        continueAfterFailure = false
        let passivePanelReadyProbe = DistributedNotificationProbe(
            name: FocusFixtureController.passivePanelReadySignal
        )
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-passive-panel"]
        app.launch()
        guard app.wait(for: .runningBackground, timeout: 5) else {
            app.terminate()
            XCTFail(
                "Passive-panel launch argument must keep the accessory app background-only"
            )
            throw HarnessLaunchError.mainAppDidNotRemainBackground
        }
        guard waitUntil({ passivePanelReadyProbe.receivedCount == 1 }) else {
            app.terminate()
            XCTFail("Passive-panel UI-test fixture did not acknowledge observer readiness")
            throw HarnessLaunchError.passivePanelObserverNotReady
        }

        do {
            let fixture = try FocusFixtureController.launchAndFocusTextField()
            return Harness(app: app, fixture: fixture)
        } catch {
            app.terminate()
            throw error
        }
    }

    @MainActor
    private func resultPanel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["result-panel"]
    }

    @MainActor
    private var glideTranslateIsActive: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.zaryolabs.GlideTranslate"
        ).contains(where: \.isActive)
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

private enum HarnessLaunchError: Error {
    case mainAppDidNotRemainBackground
    case passivePanelObserverNotReady
}

@MainActor
private final class Harness {
    let app: XCUIApplication
    let fixture: FocusFixtureController
    private var isClosed = false

    init(app: XCUIApplication, fixture: FocusFixtureController) {
        self.app = app
        self.fixture = fixture
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        app.terminate()
        fixture.close()
    }
}
