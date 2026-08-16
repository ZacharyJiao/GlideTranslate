import SharedSupport

public struct DefaultPromptPresetValidationService:
    PromptPresetValidationService,
    Sendable
{
    private let compiler: any PromptCompiling
    private let parser = PromptTemplateParser()
    private let validator = PresetValidator()

    public init() {
        compiler = PromptCompiler()
    }

    package init(compiler: any PromptCompiling) {
        self.compiler = compiler
    }

    public func builtIns() -> [PromptPresetDescriptor] {
        PresetCatalog.descriptors
    }

    public func duplicateBuiltIn(_ id: PresetID) throws -> CustomPreset {
        guard let definition = PresetCatalog.definition(for: id) else {
            throw PromptPresetFailure.presetNotFound
        }
        return CustomPreset(
            id: .custom(),
            name: definition.duplicateName,
            explanation: definition.duplicateExplanation,
            template: definition.template,
            targetLanguage: definition.descriptor.targetLanguage,
            action: definition.descriptor.action
        )
    }

    public func validate(_ preset: CustomPreset) throws -> ValidatedPromptPreset {
        try validator.validate(preset)
    }

    public func validatedBuiltIn(_ id: PresetID) throws -> ValidatedPromptPreset {
        let definition = try builtInDefinition(id)
        do {
            _ = try parser.parse(definition.template)
        } catch is PromptTemplateError {
            throw PromptPresetFailure.invalidTemplate
        }
        return .mintAfterPromptValidation(
            id: definition.descriptor.id,
            action: definition.descriptor.action,
            template: definition.template
        )
    }

    public func previewBuiltIn(_ id: PresetID) throws -> PromptPresetPreview {
        let definition = try builtInDefinition(id)
        return try previewBuiltIn(
            id,
            sourceLanguage: .automatic,
            targetLanguage: definition.descriptor.targetLanguage
        )
    }

    public func previewBuiltIn(
        _ id: PresetID,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) throws -> PromptPresetPreview {
        let definition = try builtInDefinition(id)
        let syntax: PromptSyntaxTree
        do {
            syntax = try parser.parse(definition.template)
        } catch is PromptTemplateError {
            throw PromptPresetFailure.invalidTemplate
        }
        return makePreview(
            syntax: syntax,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    public func previewCustom(_ preset: CustomPreset) throws -> PromptPresetPreview {
        try previewCustom(
            preset,
            sourceLanguage: .automatic,
            targetLanguage: preset.targetLanguage
        )
    }

    public func previewCustom(
        _ preset: CustomPreset,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) throws -> PromptPresetPreview {
        let validated = try validator.validate(preset)
        let syntax: PromptSyntaxTree
        do {
            syntax = try parser.parse(validated.template)
        } catch is PromptTemplateError {
            throw PromptPresetFailure.invalidTemplate
        }
        return makePreview(
            syntax: syntax,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private func builtInDefinition(_ id: PresetID) throws -> PresetCatalog.Definition {
        guard let definition = PresetCatalog.definition(for: id) else {
            throw PromptPresetFailure.presetNotFound
        }
        return definition
    }

    private func makePreview(
        syntax: PromptSyntaxTree,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice
    ) -> PromptPresetPreview {
        let compiled = compiler.compile(
            syntax,
            selectedText: PresetPreview.bundledSample,
            source: sourceLanguage,
            target: targetLanguage
        )
        return PromptPresetPreview(
            instruction: compiled.instruction,
            sampleUserContent: compiled.userContent
        )
    }
}
