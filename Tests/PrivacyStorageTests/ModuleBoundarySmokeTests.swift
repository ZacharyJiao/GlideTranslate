import XCTest
@testable import PrivacyStorage
import SharedSupport

final class ModuleBoundarySmokeTests: XCTestCase {
    func testModuleImports() {
        XCTAssertNotNil(PreferencesStore.self)
    }

    func testPrivacyStorageOwnsCredentialConsumption() {
        let credential = SensitiveCredentialInput("synthetic-credential")
        let consumedValue = consume(credential)
        XCTAssertEqual(consumedValue, "synthetic-credential")
    }

    private func consume(
        _ credential: consuming SensitiveCredentialInput
    ) -> String {
        credential.value
    }
}
