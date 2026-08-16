import PrivacyStorage
import SharedSupport
import TranslationCore
import XCTest

@testable import GlideTranslate

final class PromptPresetCompositionTests: XCTestCase {
    func testBuiltInsCustomsDuplicateAndValidateForwardThroughFacade() async throws {
        let persistence = MemoryCustomPresetPersistence([CustomPreset.appFixture])
        let validation = DefaultPromptPresetValidationService()
        let store = DefaultPromptPresetStore(
            persistence: persistence,
            validation: validation
        )

        let builtIns = await store.builtIns()
        let customPresets = try await store.customPresets()
        XCTAssertEqual(builtIns, validation.builtIns())
        XCTAssertEqual(customPresets, [CustomPreset.appFixture])
        let duplicate = try await store.duplicateBuiltIn(
            PresetID(rawValue: "accurate-translation")
        )
        XCTAssertTrue(duplicate.id.rawValue.hasPrefix("custom-"))
        let validated = try await store.validate(CustomPreset.appFixture)
        XCTAssertEqual(validated.id, CustomPreset.appFixture.id)
        XCTAssertEqual(validated.action, PresetAction.translate)
        let saveCalls = await persistence.saveCalls()
        XCTAssertEqual(saveCalls, 0)
    }

    func testPreviewAndValidatedLookupSelectBuiltInOrExactlyOneCustom() async throws {
        let persistence = MemoryCustomPresetPersistence([CustomPreset.appFixture])
        let validation = DefaultPromptPresetValidationService()
        let store = DefaultPromptPresetStore(
            persistence: persistence,
            validation: validation
        )

        let builtInID = PresetID(rawValue: "accurate-translation")
        let builtInPreview = try await store.preview(builtInID)
        let customPreview = try await store.preview(CustomPreset.appFixture.id)
        let builtInValidated = try await store.validatedPreset(builtInID)
        let customValidated = try await store.validatedPreset(CustomPreset.appFixture.id)
        let readsAfterValidLookups = await persistence.readCalls()
        XCTAssertEqual(builtInPreview, try validation.previewBuiltIn(builtInID))
        XCTAssertEqual(customPreview, try validation.previewCustom(CustomPreset.appFixture))
        XCTAssertEqual(builtInValidated.id, builtInID)
        XCTAssertEqual(customValidated.id, CustomPreset.appFixture.id)
        XCTAssertEqual(readsAfterValidLookups, 2)

        await persistence.replace([CustomPreset.appFixture, CustomPreset.appFixture])
        await assertAppPromptFailure(.presetNotFound) {
            _ = try await store.preview(CustomPreset.appFixture.id)
        }
        await assertAppPromptFailure(.presetNotFound) {
            _ = try await store.validatedPreset(CustomPreset.appFixture.id)
        }
        let readsAfterDuplicateLookups = await persistence.readCalls()
        XCTAssertEqual(readsAfterDuplicateLookups, 4)

        await persistence.replace([])
        let missingID = PresetID(
            rawValue: "custom-55555555-5555-5555-5555-555555555555"
        )
        await assertAppPromptFailure(.presetNotFound) {
            _ = try await store.preview(missingID)
        }
        await assertAppPromptFailure(.presetNotFound) {
            _ = try await store.validatedPreset(missingID)
        }
        let readsAfterMissingLookups = await persistence.readCalls()
        XCTAssertEqual(readsAfterMissingLookups, 6)
    }

    func testSaveValidatesBeforePersistenceAndDeleteRejectsBuiltIn() async throws {
        let persistence = MemoryCustomPresetPersistence([])
        let store = DefaultPromptPresetStore(
            persistence: persistence,
            validation: DefaultPromptPresetValidationService()
        )
        let invalid = CustomPreset.appFixture.replacingTemplate("missing placeholder")

        await assertAppPromptFailure(.invalidTemplate) {
            try await store.save(invalid)
        }
        let saveCallsAfterInvalid = await persistence.saveCalls()
        XCTAssertEqual(saveCallsAfterInvalid, 0)
        let padded = CustomPreset.appFixture.replacingDisplayText(
            name: "  \(CustomPreset.appFixture.name)\n",
            explanation: "\t\(CustomPreset.appFixture.explanation)  "
        )
        try await store.save(padded)
        let saveCallsAfterValid = await persistence.saveCalls()
        let valuesAfterSave = try await persistence.customPresets()
        XCTAssertEqual(saveCallsAfterValid, 1)
        XCTAssertEqual(valuesAfterSave, [CustomPreset.appFixture])

        await assertAppPromptFailure(.immutableBuiltIn) {
            try await store.delete(PresetID(rawValue: "polish-expression"))
        }
        let deleteCallsAfterBuiltIn = await persistence.deleteCalls()
        XCTAssertEqual(deleteCallsAfterBuiltIn, 0)
        try await store.delete(CustomPreset.appFixture.id)
        let deleteCallsAfterCustom = await persistence.deleteCalls()
        let valuesAfterDelete = try await persistence.customPresets()
        XCTAssertEqual(deleteCallsAfterCustom, 1)
        XCTAssertEqual(valuesAfterDelete, [])
    }

    func testEditedPresetCreatesNewValidatedSnapshotWithoutMutatingPriorOptions() async throws {
        let persistence = MemoryCustomPresetPersistence([CustomPreset.appFixture])
        let store = DefaultPromptPresetStore(
            persistence: persistence,
            validation: DefaultPromptPresetValidationService()
        )
        let oldValidated = try await store.validatedPreset(CustomPreset.appFixture.id)
        let oldTimeouts = TranslationTimeoutPolicy(
            connection: .seconds(5),
            firstToken: .seconds(120),
            streamIdle: .seconds(30)
        )
        let oldOptions = TranslationOptionsSnapshot(
            sourceLanguage: .automatic,
            targetLanguage: .identified("zh-Hans"),
            preset: oldValidated,
            timeouts: oldTimeouts
        )
        let oldPreview = try await store.preview(CustomPreset.appFixture.id)
        let edited = CustomPreset.appFixture.replacingTemplate(
            "Edited instruction only: {text}"
        )

        try await store.save(edited)
        let newValidated = try await store.validatedPreset(CustomPreset.appFixture.id)
        let newPreview = try await store.preview(CustomPreset.appFixture.id)

        XCTAssertNotEqual(oldPreview, newPreview)
        XCTAssertEqual(oldOptions.preset.id, CustomPreset.appFixture.id)
        XCTAssertEqual(oldOptions.preset.action, PresetAction.translate)
        XCTAssertEqual(oldOptions.timeouts, oldTimeouts)
        XCTAssertEqual(newValidated.id, CustomPreset.appFixture.id)
        XCTAssertEqual(newValidated.action, PresetAction.translate)
    }
}

private actor MemoryCustomPresetPersistence: CustomPresetPersistence {
    private var values: [CustomPreset]
    private var saves = 0
    private var deletes = 0
    private var reads = 0

    init(_ values: [CustomPreset]) { self.values = values }

    func customPresets() async throws -> [CustomPreset] {
        reads += 1
        return values
    }

    func save(_ preset: CustomPreset) async throws {
        saves += 1
        if let index = values.firstIndex(where: { $0.id == preset.id }) {
            values[index] = preset
        } else {
            values.append(preset)
        }
    }

    func delete(_ id: PresetID) async throws {
        deletes += 1
        values.removeAll { $0.id == id }
    }

    func replace(_ values: [CustomPreset]) { self.values = values }
    func saveCalls() -> Int { saves }
    func deleteCalls() -> Int { deletes }
    func readCalls() -> Int { reads }
}

private func assertAppPromptFailure(
    _ expected: PromptPresetFailure,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected prompt preset failure")
    } catch {
        XCTAssertEqual(error as? PromptPresetFailure, expected)
    }
}

private extension CustomPreset {
    static let appFixture = CustomPreset(
        id: PresetID(rawValue: "custom-33333333-3333-3333-3333-333333333333"),
        name: "Custom",
        explanation: "Custom explanation",
        template: "Translate carefully: {text}",
        targetLanguage: .identified("zh-Hans"),
        action: .translate
    )

    func replacingTemplate(_ template: String) -> Self {
        Self(
            id: id,
            name: name,
            explanation: explanation,
            template: template,
            targetLanguage: targetLanguage,
            action: action
        )
    }

    func replacingDisplayText(name: String, explanation: String) -> Self {
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
