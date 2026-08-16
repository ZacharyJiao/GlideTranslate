import SharedSupport

public struct PromptPresetPreview: Equatable, Sendable {
    public let instruction: String
    public let sampleUserContent: String

    package init(instruction: String, sampleUserContent: String) {
        self.instruction = instruction
        self.sampleUserContent = sampleUserContent
    }
}
