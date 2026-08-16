import XCTest

@MainActor
final class FocusFixtureController {
    static let bundleIdentifier = "com.zaryolabs.GlideTranslate.FocusFixture"
    static let fieldIdentifier = "focus-fixture-field"
    static let windowTitle = "Focus Fixture"
    static let focusedWindowTitle = "Focus Fixture Focused"
    static let lostFocusWindowTitle = "Focus Fixture Lost Focus"
    static let showPanelSignal = Notification.Name(
        "com.zaryolabs.GlideTranslate.ui-testing.show-passive-panel"
    )
    static let passivePanelReadySignal = Notification.Name(
        "com.zaryolabs.GlideTranslate.ui-testing.passive-panel-ready"
    )
    static let copyCompletedSignal = Notification.Name(
        "com.zaryolabs.GlideTranslate.ui-testing.copy-completed"
    )
    static let manualSubmitCompletedSignal = Notification.Name(
        "com.zaryolabs.GlideTranslate.ui-testing.manual-submit-completed"
    )

    enum LaunchError: Error {
        case applicationDidNotReachForeground
        case textFieldDidNotAppear
        case textFieldDidNotGainFocus
    }

    let app: XCUIApplication
    private let textField: XCUIElement
    private var isClosed = false

    private init(app: XCUIApplication) {
        self.app = app
        textField = app.textFields[Self.fieldIdentifier]
    }

    static func launchAndFocusTextField() throws -> FocusFixtureController {
        let app = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        app.launch()
        guard app.wait(for: .runningForeground, timeout: 5) else {
            app.terminate()
            throw LaunchError.applicationDidNotReachForeground
        }

        let fixture = FocusFixtureController(app: app)
        guard fixture.textField.waitForExistence(timeout: 5) else {
            app.terminate()
            throw LaunchError.textFieldDidNotAppear
        }

        fixture.textField.click()
        guard fixture.waitUntil({
            fixture.focusedElementIdentifier() != nil
        }) else {
            app.terminate()
            throw LaunchError.textFieldDidNotGainFocus
        }
        return fixture
    }

    func focusedElementIdentifier() -> String? {
        guard app.windows[Self.focusedWindowTitle].exists,
              !didLoseFocus else {
            return nil
        }
        return Self.fieldIdentifier
    }

    var didLoseFocus: Bool {
        app.windows[Self.lostFocusWindowTitle].exists
    }

    func hasVisibleWindow() -> Bool {
        app.windows.element(boundBy: 0).exists
    }

    func triggerSyntheticResultPanel() {
        DistributedNotificationCenter.default().post(
            name: Self.showPanelSignal,
            object: nil,
            userInfo: nil
        )
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        app.terminate()
    }

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

@MainActor
final class DistributedNotificationProbe: NSObject {
    private(set) var receivedCount = 0
    private let name: Notification.Name

    init(name: Notification.Name) {
        self.name = name
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receive),
            name: name,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: name,
            object: nil
        )
    }

    @objc private func receive() {
        receivedCount += 1
    }
}
