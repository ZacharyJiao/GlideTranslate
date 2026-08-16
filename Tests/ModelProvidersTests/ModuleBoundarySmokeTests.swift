import ModelProviders
import XCTest

final class ModuleBoundarySmokeTests: XCTestCase {
    func testModuleImports() {
        XCTAssertNotNil(ProviderService.self)
    }
}
