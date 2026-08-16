import SharedSupport

enum PresetCatalog {
    struct Definition: Sendable {
        let descriptor: PromptPresetDescriptor
        let duplicateName: String
        let duplicateExplanation: String
        let template: String
    }

    static let definitions: [Definition] = [
        definition(
            id: "accurate-translation",
            nameKey: "preset.accurate.name",
            explanationKey: "preset.accurate.explanation",
            duplicateName: "Accurate Translation",
            duplicateExplanation: "Translate faithfully while preserving meaning and detail.",
            action: .translate,
            template: "Translate {text} from {source_language} to {target_language} accurately."
        ),
        definition(
            id: "natural-translation",
            nameKey: "preset.natural.name",
            explanationKey: "preset.natural.explanation",
            duplicateName: "Natural Translation",
            duplicateExplanation: "Translate for natural, fluent expression.",
            action: .translate,
            template: "Translate {text} from {source_language} to {target_language} naturally."
        ),
        definition(
            id: "explain-word",
            nameKey: "preset.explainWord.name",
            explanationKey: "preset.explainWord.explanation",
            duplicateName: "Explain Word",
            duplicateExplanation: "Explain the selected word clearly.",
            action: .explainWord,
            template: "Explain the word {text} in {target_language}."
        ),
        definition(
            id: "explain-sentence",
            nameKey: "preset.explainSentence.name",
            explanationKey: "preset.explainSentence.explanation",
            duplicateName: "Explain Sentence",
            duplicateExplanation: "Explain the selected sentence clearly.",
            action: .explainSentence,
            template: "Explain the sentence {text} in {target_language}."
        ),
        definition(
            id: "polish-expression",
            nameKey: "preset.polish.name",
            explanationKey: "preset.polish.explanation",
            duplicateName: "Polish Expression",
            duplicateExplanation: "Polish the text for natural expression.",
            action: .polish,
            template: "Polish {text} for natural expression in {target_language}."
        )
    ]

    static let descriptors = definitions.map(\.descriptor)

    static func definition(for id: PresetID) -> Definition? {
        definitions.first { $0.descriptor.id == id }
    }

    static func contains(_ id: PresetID) -> Bool {
        definition(for: id) != nil
    }

    private static func definition(
        id: String,
        nameKey: String,
        explanationKey: String,
        duplicateName: String,
        duplicateExplanation: String,
        action: PresetAction,
        template: String
    ) -> Definition {
        Definition(
            descriptor: PromptPresetDescriptor(
                id: PresetID(rawValue: id),
                nameLocalizationKey: nameKey,
                explanationLocalizationKey: explanationKey,
                targetLanguage: .automatic,
                action: action,
                isReadOnly: true
            ),
            duplicateName: duplicateName,
            duplicateExplanation: duplicateExplanation,
            template: template
        )
    }
}
