import SharedSupport

public protocol CustomPresetPersistence: Sendable {
    func customPresets() async throws -> [CustomPreset]
    func save(_ preset: CustomPreset) async throws
    func delete(_ id: PresetID) async throws
}
