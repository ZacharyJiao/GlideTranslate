import SharedSupport

public protocol PromptPresetValidationService: Sendable {
    func builtIns() -> [PromptPresetDescriptor]
    func duplicateBuiltIn(_ id: PresetID) throws -> CustomPreset
    func validate(_ preset: CustomPreset) throws -> ValidatedPromptPreset
    func validatedBuiltIn(_ id: PresetID) throws -> ValidatedPromptPreset
    func previewBuiltIn(_ id: PresetID) throws -> PromptPresetPreview
    func previewCustom(_ preset: CustomPreset) throws -> PromptPresetPreview
    func previewBuiltIn(
        _ id: PresetID,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) throws -> PromptPresetPreview
    func previewCustom(
        _ preset: CustomPreset,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) throws -> PromptPresetPreview
}

public extension PromptPresetValidationService {
    func previewBuiltIn(
        _ id: PresetID,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) throws -> PromptPresetPreview {
        try previewBuiltIn(id)
    }

    func previewCustom(
        _ preset: CustomPreset,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) throws -> PromptPresetPreview {
        try previewCustom(preset)
    }
}
