@testable import TranslationCore
import XCTest

final class PromptTemplateParserTests: XCTestCase {
    private struct ParseCase {
        let template: String
        let expected: Result<[PromptNode], PromptTemplateError>
    }

    private let cases: [ParseCase] = [
        .init(template: "Translate {text}.", expected: .success([
            .literal("Translate "), .selectedTextReference, .literal(".")
        ])),
        .init(template: "{source_language}: {text} -> {target_language}",
              expected: .success([
                  .sourceLanguageReference, .literal(": "), .selectedTextReference,
                  .literal(" -> "), .targetLanguageReference
              ])),
        .init(template: "{{literal}} {text}", expected: .success([
            .literal("{literal} "), .selectedTextReference
        ])),
        .init(template: "{text} {{ }}", expected: .success([
            .selectedTextReference, .literal(" { }")
        ])),
        .init(template: "missing marker", expected: .failure(.missingSelectedText)),
        .init(template: "{text} and {text}", expected: .failure(.repeatedSelectedText)),
        .init(template: "{unknown} {text}", expected: .failure(.unknownPlaceholder)),
        .init(template: "{text", expected: .failure(.unterminatedPlaceholder)),
        .init(template: "text} {text}", expected: .failure(.unescapedClosingBrace)),
        .init(template: "{} {text}", expected: .failure(.unknownPlaceholder))
    ]

    func testGrammarMatrix() {
        for testCase in cases {
            let actual: Result<[PromptNode], PromptTemplateError>
            do {
                actual = .success(
                    try PromptTemplateParser().parse(testCase.template).nodes
                )
            } catch let error as PromptTemplateError {
                actual = .failure(error)
            } catch {
                XCTFail("unexpected parser error type")
                continue
            }
            XCTAssertEqual(actual, testCase.expected, testCase.template)
        }
    }
}
