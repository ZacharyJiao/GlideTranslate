import SelectionCapture
import XCTest

final class ModuleBoundarySmokeTests: XCTestCase {
    func testModuleImports() {
        XCTAssertNotNil(SelectionAuthorizationOutcome.self)
    }
}
