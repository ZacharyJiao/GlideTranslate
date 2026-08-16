import TranslationCore
import XCTest

final class ModuleBoundarySmokeTests: XCTestCase {
    func testModuleImports() {
        XCTAssertNotNil(TranslationEngine.self)
    }
}
