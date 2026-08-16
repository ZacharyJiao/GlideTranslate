import SharedSupport

public protocol PromptPresetStore: Sendable {
    func builtIns() async -> [PromptPresetDescriptor]
    func customPresets() async throws -> [CustomPreset]
    func duplicateBuiltIn(_ id: PresetID) async throws -> CustomPreset
    func validate(_ preset: CustomPreset) async throws -> ValidatedPromptPreset
    func preview(_ id: PresetID) async throws -> PromptPresetPreview
    func validatedPreset(_ id: PresetID) async throws -> ValidatedPromptPreset
    func save(_ preset: CustomPreset) async throws
    func delete(_ id: PresetID) async throws
}
