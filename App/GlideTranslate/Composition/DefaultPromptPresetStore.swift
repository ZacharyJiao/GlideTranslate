import Foundation
import PrivacyStorage
import SharedSupport
import TranslationCore

actor DefaultPromptPresetStore: PromptPresetStore {
    private let persistence: any CustomPresetPersistence
    private let validation: any PromptPresetValidationService

    init(
        persistence: any CustomPresetPersistence,
        validation: any PromptPresetValidationService
    ) {
        self.persistence = persistence
        self.validation = validation
    }

    func builtIns() -> [PromptPresetDescriptor] {
        validation.builtIns()
    }

    func customPresets() async throws -> [CustomPreset] {
        try await persistence.customPresets()
    }

    func duplicateBuiltIn(_ id: PresetID) throws -> CustomPreset {
        try validation.duplicateBuiltIn(id)
    }

    func validate(_ preset: CustomPreset) throws -> ValidatedPromptPreset {
        try validation.validate(preset)
    }

    func preview(_ id: PresetID) async throws -> PromptPresetPreview {
        if isBuiltIn(id) {
            return try validation.previewBuiltIn(id)
        }
        return try validation.previewCustom(try await uniqueCustomPreset(id))
    }

    func preview(
        _ id: PresetID,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) async throws -> PromptPresetPreview {
        if isBuiltIn(id) {
            return try validation.previewBuiltIn(
                id,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }
        return try validation.previewCustom(
            try await uniqueCustomPreset(id),
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    func validatedPreset(_ id: PresetID) async throws -> ValidatedPromptPreset {
        if isBuiltIn(id) {
            return try validation.validatedBuiltIn(id)
        }
        return try validation.validate(try await uniqueCustomPreset(id))
    }

    func save(_ preset: CustomPreset) async throws {
        let normalized = Self.normalized(preset)
        _ = try validation.validate(normalized)
        try await persistence.save(normalized)
    }

    func delete(_ id: PresetID) async throws {
        guard !isBuiltIn(id) else {
            throw PromptPresetFailure.immutableBuiltIn
        }
        try await persistence.delete(id)
    }

    private func isBuiltIn(_ id: PresetID) -> Bool {
        validation.builtIns().contains { $0.id == id }
    }

    private func uniqueCustomPreset(_ id: PresetID) async throws -> CustomPreset {
        let matches = try await persistence.customPresets().filter { $0.id == id }
        guard matches.count == 1, let preset = matches.first else {
            throw PromptPresetFailure.presetNotFound
        }
        return preset
    }

    private static func normalized(_ preset: CustomPreset) -> CustomPreset {
        CustomPreset(
            id: preset.id,
            name: preset.name.trimmingCharacters(in: .whitespacesAndNewlines),
            explanation: preset.explanation.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            template: preset.template,
            targetLanguage: preset.targetLanguage,
            action: preset.action
        )
    }
}
