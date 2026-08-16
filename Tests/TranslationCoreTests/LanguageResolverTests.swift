import SharedSupport
@testable import TranslationCore
import XCTest

final class LanguageResolverTests: XCTestCase {
    private struct SourceRow {
        let hypothesis: (languageCode: String, confidence: Double)?
        let explicit: LanguageChoice?
        let expected: LanguageChoice
    }

    private struct TargetRow {
        let explicitRequest: LanguageChoice?
        let presetOverride: LanguageChoice?
        let globalDefault: LanguageChoice
        let expected: LanguageChoice
    }

    func testSourceResolutionUsesExplicitChoiceThenConfidenceThreshold() {
        let rows: [SourceRow] = [
            SourceRow(hypothesis: nil, explicit: nil, expected: .automatic),
            SourceRow(hypothesis: ("en", 0.59), explicit: nil, expected: .automatic),
            SourceRow(hypothesis: ("en", 0.60), explicit: nil, expected: .identified("en")),
            SourceRow(hypothesis: ("zh-Hans", 0.99), explicit: nil, expected: .identified("zh-Hans")),
            SourceRow(hypothesis: ("en", 0.99), explicit: .identified("ja"), expected: .identified("ja"))
        ]

        for row in rows {
            let provider = StubLanguageHypothesisProvider(result: row.hypothesis)
            let resolver = LocalLanguageResolver(provider: provider)

            XCTAssertEqual(
                resolver.resolve("Synthetic text", override: row.explicit),
                row.expected
            )
            XCTAssertEqual(provider.callCount, row.explicit == nil ? 1 : 0)
        }
    }

    func testTargetResolutionUsesExplicitThenPresetThenGlobalPrecedence() {
        let rows: [TargetRow] = [
            TargetRow(explicitRequest: nil, presetOverride: nil, globalDefault: .identified("en"), expected: .identified("en")),
            TargetRow(explicitRequest: nil, presetOverride: .identified("ja"), globalDefault: .identified("en"), expected: .identified("ja")),
            TargetRow(explicitRequest: .identified("zh-Hans"), presetOverride: .identified("ja"), globalDefault: .identified("en"), expected: .identified("zh-Hans")),
            TargetRow(explicitRequest: .automatic, presetOverride: .identified("ja"), globalDefault: .identified("en"), expected: .automatic)
        ]
        let resolver = LocalLanguageResolver(provider: StubLanguageHypothesisProvider(result: nil))

        for row in rows {
            XCTAssertEqual(
                resolver.resolveTarget(
                    explicitRequest: row.explicitRequest,
                    presetOverride: row.presetOverride,
                    globalDefault: row.globalDefault
                ),
                row.expected
            )
        }
    }
}

private final class StubLanguageHypothesisProvider:
    LanguageHypothesisProviding,
    @unchecked Sendable
{
    private let result: (languageCode: String, confidence: Double)?
    private(set) var callCount = 0

    init(result: (languageCode: String, confidence: Double)?) {
        self.result = result
    }

    func leadingHypothesis(for text: String) -> (languageCode: String, confidence: Double)? {
        callCount += 1
        return result
    }
}
