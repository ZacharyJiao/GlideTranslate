import Foundation
import ModelProviders
import SharedSupport
import XCTest

@testable import GlideTranslate

@MainActor
final class LocalizationCompletenessTests: XCTestCase {
    func testEnglishAndSimplifiedChineseAreComplete() throws {
        let catalog = try ProductStringCatalog.load()
        XCTAssertEqual(
            catalog.keySet(locale: "en"),
            catalog.keySet(locale: "zh-Hans"),
            "English and Simplified Chinese must ship the same key set"
        )
        XCTAssertTrue(
            Set(LocalizationInventory.dynamicKeys).isSubset(of: Set(catalog.keys)),
            "Every reviewed dynamic localization key must ship in the runtime catalog"
        )
        let unfinishedMarkers = [["T", "ODO"].joined(), ["T", "BD"].joined()]

        for key in catalog.keys {
            for locale in ["en", "zh-Hans"] {
                let value = try XCTUnwrap(catalog.translation(key, locale: locale), key)
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                for marker in unfinishedMarkers {
                    XCTAssertFalse(value.contains(marker), key)
                }
            }
            XCTAssertEqual(
                catalog.formatSpecifiers(key, locale: "en"),
                catalog.formatSpecifiers(key, locale: "zh-Hans"),
                key
            )
        }
    }

    func testAccessibilityKeyboardAndMotionAuditIsExact() {
        XCTAssertEqual(AccessibilityAudit.rows, [
            .iconOnlyButtonsHaveLabels,
            .stateControlsExposeValues,
            .destructiveAndPermissionActionsHaveHints,
            .streamingResult(stableHeading: true, readsEveryDelta: false),
            .focusOrderFollowsVisualHierarchy,
            .keyboard(close: .escape, copy: .commandC,
                      translate: .commandReturn, settings: .commandComma),
            .motion(reducedUsesAnimation: false,
                    standardMaximumDurationMilliseconds: 160),
        ])
        XCTAssertNil(PanelMotionPolicy.animation(reduceMotion: true))
        XCTAssertNotNil(PanelMotionPolicy.animation(reduceMotion: false))
        XCTAssertEqual(PanelMotionPolicy.standardDuration, 0.16)
    }

    func testEverySafeFailureHasCatalogedMessageAndNextAction() throws {
        let catalog = try ProductStringCatalog.load()
        let presentations = SettingsSafeError.allCases.map(\.localization)
            + OnboardingSafeError.allCases.map(\.localization)
            + SanitizedFailure.allCases.map(\.localization)

        XCTAssertEqual(Set(presentations.map(\.messageKey)).count, presentations.count)
        XCTAssertEqual(Set(presentations.map(\.nextActionKey)).count, presentations.count)
        for presentation in presentations {
            for key in [presentation.messageKey, presentation.nextActionKey] {
                XCTAssertNotNil(catalog.translation(key, locale: "en"), key)
                XCTAssertNotNil(catalog.translation(key, locale: "zh-Hans"), key)
            }
        }
    }

    func testInternalDisplayValuesMapToReviewedLocalizationKeys() {
        XCTAssertEqual(ProviderProtocolKind.ollamaNative.localizationKey, "models.ollama")
        XCTAssertEqual(ProviderProtocolKind.openAICompatible.localizationKey,
                       "models.openAICompatible")
        XCTAssertEqual(DestinationPrivacyClass.localOnDevice.localizationKey, "locality.local")
        XCTAssertEqual(DestinationPrivacyClass.cloud.localizationKey, "locality.cloud")
        XCTAssertEqual(PresetID(rawValue: "accurate-translation").safeDisplayLocalizationKey,
                       "preset.accurate.name")
        XCTAssertEqual(PresetID(rawValue: "custom-private-id").safeDisplayLocalizationKey,
                       "preset.custom.name")
    }

    func testFeatureFlagsRequireBaseUITestingMode() {
        XCTAssertFalse(UITestingMode.includes(
            "--ui-testing-standard-motion",
            arguments: ["app", "--ui-testing-standard-motion"]
        ))
        XCTAssertTrue(UITestingMode.includes(
            "--ui-testing-standard-motion",
            arguments: ["app", "--ui-testing", "--ui-testing-standard-motion"]
        ))
    }

    func testSystemOwnedDynamicLabelsUseLocalizationKeys() {
        XCTAssertEqual(
            AppSceneState.development().menuModel.presetNameLocalizationKey,
            "preset.accurate.name"
        )
        XCTAssertEqual(
            ManualInputViewModel.development().providerOptions.first?.labelKey,
            "manual.provider.default"
        )
    }

    func testFeedbackAlertOKButtonUsesSelectedAppLocale() {
        XCTAssertEqual(
            ProductionCoordinatorFeedbackPresenter.okButtonTitle(
                locale: Locale(identifier: "en")
            ),
            "OK"
        )
        XCTAssertEqual(
            ProductionCoordinatorFeedbackPresenter.okButtonTitle(
                locale: Locale(identifier: "zh-Hans")
            ),
            "好"
        )
    }

    func testChangingUILocaleDoesNotChangeModelLanguages() async {
        let fixture = U8Fixture()
        await fixture.model.setTargetLanguage(.identified("zh-Hans"))
        let presentation = TranslationPresentation(
            sourceText: "synthetic",
            resultText: "",
            presetID: PresetID(rawValue: "accurate-translation"),
            presetDisplayName: "My Private Preset",
            sourceLanguage: .identified("ja"),
            targetLanguage: .identified("zh-Hans"),
            providerClass: .localOnDevice,
            displayRect: nil,
            phase: .preparing
        )

        await fixture.model.setUILanguage(.simplifiedChinese)

        XCTAssertEqual(presentation.sourceLanguage, .identified("ja"))
        XCTAssertEqual(presentation.targetLanguage, .identified("zh-Hans"))
        XCTAssertEqual(presentation.presetDisplayName, "My Private Preset")
        XCTAssertEqual(fixture.model.snapshot.defaultTargetLanguage, .identified("zh-Hans"))
        XCTAssertEqual(fixture.model.uiLocale.identifier, "zh-Hans")
        XCTAssertEqual(AppUILocaleState.shared.current.identifier, "zh-Hans")
        await fixture.model.setUILanguage(.english)
    }

}

private struct ProductStringCatalog {
    let translations: [String: [String: String]]
    var keys: [String] { translations["en", default: [:]].keys.sorted() }

    static func load() throws -> Self {
        var translations: [String: [String: String]] = [:]
        for locale in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(
                Bundle.main.path(
                    forResource: "Localizable",
                    ofType: "strings",
                    inDirectory: nil,
                    forLocalization: locale
                ),
                locale
            )
            let dictionary = try XCTUnwrap(
                NSDictionary(contentsOfFile: path) as? [String: String],
                locale
            )
            translations[locale] = dictionary
        }
        return Self(translations: translations)
    }

    func translation(_ key: String, locale: String) -> String? {
        translations[locale]?[key]
    }

    func keySet(locale: String) -> Set<String> {
        Set(translations[locale, default: [:]].keys)
    }

    func formatSpecifiers(_ key: String, locale: String) -> [String] {
        guard let value = translation(key, locale: locale) else { return [] }
        let expression = try! NSRegularExpression(
            pattern: #"%(?:[0-9]+\$)?[-+#0 ']*[0-9]*(?:\.[0-9]+)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF]"#
        )
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

}
