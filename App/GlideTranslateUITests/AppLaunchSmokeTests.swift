import XCTest

final class AppLaunchSmokeTests: XCTestCase {
    @MainActor
    func testAppLaunchesAsAccessoryProcess() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertEqual(app.state, .runningBackground)
        app.terminate()
    }

}
