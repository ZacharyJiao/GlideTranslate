import Foundation
@testable import TranslationCore
import XCTest

final class LanguageFrameworkSmokeTests: XCTestCase {
    func testNaturalLanguageAdapterReturnsOnlyWellFormedHypothesis() {
        let result = NaturalLanguageHypothesisProvider().leadingHypothesis(
            for: "This fixed sentence is only a framework smoke fixture."
        )

        guard let result else { return }
        XCTAssertFalse(result.languageCode.isEmpty)
        XCTAssertNotNil(
            result.languageCode.range(
                of: #"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$"#,
                options: .regularExpression
            )
        )
        XCTAssertTrue((0 ... 1).contains(result.confidence))
    }
}
