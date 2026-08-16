import Foundation
import SharedSupport
@testable import TranslationCore
import XCTest

final class PresetValidationTests: XCTestCase {
    private struct CatalogRow: Equatable {
        let id: String
        let nameLocalizationKey: String
        let explanationLocalizationKey: String
        let targetLanguage: LanguageChoice
        let action: PresetAction
        let isReadOnly: Bool
    }

    private struct DuplicateRow {
        let id: String
        let name: String
        let explanation: String
        let template: String
        let targetLanguage: LanguageChoice
        let action: PresetAction
    }

    private enum PresetValidationResult: Equatable {
        case valid
        case invalid(PromptPresetFailure)
    }

    func testBuiltInCatalogIsExactAndReadOnly() {
        XCTAssertEqual(PresetCatalog.descriptors.map {
            CatalogRow(
                id: $0.id.rawValue,
                nameLocalizationKey: $0.nameLocalizationKey,
                explanationLocalizationKey: $0.explanationLocalizationKey,
                targetLanguage: $0.targetLanguage,
                action: $0.action,
                isReadOnly: $0.isReadOnly
            )
        }, [
            CatalogRow(id: "accurate-translation", nameLocalizationKey: "preset.accurate.name", explanationLocalizationKey: "preset.accurate.explanation", targetLanguage: .automatic, action: .translate, isReadOnly: true),
            CatalogRow(id: "natural-translation", nameLocalizationKey: "preset.natural.name", explanationLocalizationKey: "preset.natural.explanation", targetLanguage: .automatic, action: .translate, isReadOnly: true),
            CatalogRow(id: "explain-word", nameLocalizationKey: "preset.explainWord.name", explanationLocalizationKey: "preset.explainWord.explanation", targetLanguage: .automatic, action: .explainWord, isReadOnly: true),
            CatalogRow(id: "explain-sentence", nameLocalizationKey: "preset.explainSentence.name", explanationLocalizationKey: "preset.explainSentence.explanation", targetLanguage: .automatic, action: .explainSentence, isReadOnly: true),
            CatalogRow(id: "polish-expression", nameLocalizationKey: "preset.polish.name", explanationLocalizationKey: "preset.polish.explanation", targetLanguage: .automatic, action: .polish, isReadOnly: true)
        ])
    }

    func testCustomValidationMatrix() {
        let validationRows: [(CustomPreset, PresetValidationResult)] = [
            (.fixture(name: "", template: "Translate {text}"), .invalid(.emptyName)),
            (.fixture(name: "   ", template: "Translate {text}"), .invalid(.emptyName)),
            (.fixture(name: "A", template: ""), .invalid(.invalidTemplate)),
            (.fixture(name: "A", template: "No marker"), .invalid(.invalidTemplate)),
            (.fixture(name: "A", template: "{text}"), .valid),
            (.fixture(name: String(repeating: "a", count: 80), template: "{text}"), .valid),
            (.fixture(name: "A", explanation: String(repeating: "e", count: 8_000)), .valid),
            (.fixture(name: "A", template: String(repeating: "a", count: 7_994) + "{text}"), .valid),
            (.fixture(name: String(repeating: "a", count: 81), template: "{text}"),
             .invalid(.nameTooLong)),
            (.fixture(name: "A", template: String(repeating: "a", count: 8_001)),
             .invalid(.templateTooLong)),
            (.fixture(name: "A", explanation: String(repeating: "e", count: 8_001)),
             .invalid(.explanationTooLong)),
            (.fixture(id: PresetID(rawValue: "not-custom")),
             .invalid(.invalidCustomIdentifier)),
            (.fixture(id: PresetID(rawValue: "accurate-translation")),
             .invalid(.immutableBuiltIn))
        ]
        let service = DefaultPromptPresetValidationService()

        for (preset, expected) in validationRows {
            let actual: PresetValidationResult
            do {
                _ = try service.validate(preset)
                actual = .valid
            } catch let failure as PromptPresetFailure {
                actual = .invalid(failure)
            } catch {
                XCTFail("unexpected validation error type")
                continue
            }
            XCTAssertEqual(actual, expected, preset.id.rawValue)
        }
    }

    func testEveryBuiltInValidatesAndPreviewsWithTheBundledSample() throws {
        let service = DefaultPromptPresetValidationService()

        for descriptor in PresetCatalog.descriptors {
            XCTAssertEqual(try service.validatedBuiltIn(descriptor.id).id, descriptor.id)
            XCTAssertEqual(
                try service.previewBuiltIn(descriptor.id).sampleUserContent,
                PresetPreview.bundledSample
            )
        }
    }

    func testDuplicateBuiltInCopiesEveryEditableFieldAndUsesCanonicalCustomID() throws {
        let service = DefaultPromptPresetValidationService()
        let rows: [DuplicateRow] = [
            DuplicateRow(id: "accurate-translation", name: "Accurate Translation", explanation: "Translate faithfully while preserving meaning and detail.", template: "Translate {text} from {source_language} to {target_language} accurately.", targetLanguage: .automatic, action: .translate),
            DuplicateRow(id: "natural-translation", name: "Natural Translation", explanation: "Translate for natural, fluent expression.", template: "Translate {text} from {source_language} to {target_language} naturally.", targetLanguage: .automatic, action: .translate),
            DuplicateRow(id: "explain-word", name: "Explain Word", explanation: "Explain the selected word clearly.", template: "Explain the word {text} in {target_language}.", targetLanguage: .automatic, action: .explainWord),
            DuplicateRow(id: "explain-sentence", name: "Explain Sentence", explanation: "Explain the selected sentence clearly.", template: "Explain the sentence {text} in {target_language}.", targetLanguage: .automatic, action: .explainSentence),
            DuplicateRow(id: "polish-expression", name: "Polish Expression", explanation: "Polish the text for natural expression.", template: "Polish {text} for natural expression in {target_language}.", targetLanguage: .automatic, action: .polish)
        ]

        for row in rows {
            let duplicate = try service.duplicateBuiltIn(PresetID(rawValue: row.id))
            let suffix = String(duplicate.id.rawValue.dropFirst("custom-".count))

            XCTAssertTrue(duplicate.id.rawValue.hasPrefix("custom-"))
            XCTAssertEqual(suffix, suffix.lowercased())
            XCTAssertNotNil(UUID(uuidString: suffix))
            XCTAssertEqual(duplicate.name, row.name)
            XCTAssertEqual(duplicate.explanation, row.explanation)
            XCTAssertEqual(duplicate.template, row.template)
            XCTAssertEqual(duplicate.targetLanguage, row.targetLanguage)
            XCTAssertEqual(duplicate.action, row.action)
            XCTAssertEqual(try service.validate(duplicate).id, duplicate.id)
        }
        XCTAssertThrowsError(
            try service.duplicateBuiltIn(PresetID(rawValue: "missing-built-in"))
        ) { error in
            XCTAssertEqual(error as? PromptPresetFailure, .presetNotFound)
        }
    }

    func testPreviewUsesOnlyBundledSample() throws {
        let compiler = PromptCompilerSpy()
        let service = DefaultPromptPresetValidationService(compiler: compiler)
        let preview = try service.previewCustom(.fixture())

        XCTAssertEqual(compiler.selectedTexts, [PresetPreview.bundledSample])
        XCTAssertEqual(preview.sampleUserContent, PresetPreview.bundledSample)
    }

    func testBuiltInLookupValidationAndPreviewRejectUnknownID() throws {
        let service = DefaultPromptPresetValidationService()
        XCTAssertThrowsError(
            try service.validatedBuiltIn(PresetID(rawValue: "missing-built-in"))
        ) { error in
            XCTAssertEqual(error as? PromptPresetFailure, .presetNotFound)
        }
    }
}

private final class PromptCompilerSpy: PromptCompiling, @unchecked Sendable {
    private(set) var selectedTexts: [String] = []

    func compile(
        _ syntax: PromptSyntaxTree,
        selectedText: String,
        source: LanguageChoice,
        target: LanguageChoice
    ) -> CompiledPrompt {
        selectedTexts.append(selectedText)
        return PromptCompiler().compile(
            syntax,
            selectedText: selectedText,
            source: source,
            target: target
        )
    }
}

private extension CustomPreset {
    static func fixture(
        id: PresetID = .custom(),
        name: String = "Fixture",
        explanation: String = "Synthetic explanation",
        template: String = "Translate {text}",
        targetLanguage: LanguageChoice = .automatic,
        action: PresetAction = .translate
    ) -> Self {
        Self(
            id: id,
            name: name,
            explanation: explanation,
            template: template,
            targetLanguage: targetLanguage,
            action: action
        )
    }
}
