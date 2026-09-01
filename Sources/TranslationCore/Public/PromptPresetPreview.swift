import SharedSupport

public struct PromptPresetPreview: Equatable, Sendable {
    public let instruction: String
    public let userContentTemplate: String
    public let sampleUserContent: String

    package init(
        instruction: String,
        userContentTemplate: String,
        sampleUserContent: String
    ) {
        self.instruction = instruction
        self.userContentTemplate = userContentTemplate
        self.sampleUserContent = sampleUserContent
    }
}
