import XCTest

@testable import GlideTranslate

final class SettingsInventoryTests: XCTestCase {
    private let requiredControlIDs: Set<String> = [
        "general.uiLanguage", "general.targetLanguage", "general.shortcut",
        "general.launchAtLogin", "general.defaultPreset", "general.defaultProvider",
        "general.automaticCapture",
        "selection.accessibility", "selection.applications", "selection.mouse",
        "selection.keyboard", "selection.debounce", "selection.limit",
        "selection.clipboardFallback",
        "models.ollama", "models.openAICompatible", "models.model",
        "models.connect", "models.activateModel", "models.timeouts",
        "models.automaticApplications",
        "prompts.builtIns", "prompts.custom", "prompts.preview", "prompts.default",
        "privacyHistory.enabled", "privacyHistory.retention",
        "privacyHistory.maximumCount",
        "privacyHistory.search", "privacyHistory.exclusions",
        "privacyHistory.delete", "privacyHistory.clear",
        "privacyHistory.reset", "privacyHistory.diagnostics",
        "about.version", "about.licenses", "about.privacy",
        "about.source", "about.releases",
    ]

    func testSettingsInventoryIsExact() {
        XCTAssertEqual(SettingsInventory.allSectionIDs, [
            "general", "selection", "models", "prompts", "privacyHistory", "about",
        ])
        XCTAssertEqual(Set(SettingsInventory.allControlIDs), requiredControlIDs)
    }
}
