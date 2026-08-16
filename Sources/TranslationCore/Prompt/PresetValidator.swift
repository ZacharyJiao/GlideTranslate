import Foundation
import SharedSupport

struct PresetValidator: Sendable {
    private let parser = PromptTemplateParser()

    func validate(_ preset: CustomPreset) throws -> ValidatedPromptPreset {
        if PresetCatalog.contains(preset.id) {
            throw PromptPresetFailure.immutableBuiltIn
        }
        guard Self.isValidCustomIdentifier(preset.id) else {
            throw PromptPresetFailure.invalidCustomIdentifier
        }

        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = preset.explanation.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            throw PromptPresetFailure.emptyName
        }
        guard name.count <= 80 else {
            throw PromptPresetFailure.nameTooLong
        }
        guard explanation.count <= 8_000 else {
            throw PromptPresetFailure.explanationTooLong
        }
        guard !preset.template.isEmpty else {
            throw PromptPresetFailure.invalidTemplate
        }
        guard preset.template.count <= 8_000 else {
            throw PromptPresetFailure.templateTooLong
        }

        do {
            _ = try parser.parse(preset.template)
        } catch is PromptTemplateError {
            throw PromptPresetFailure.invalidTemplate
        }

        return .mintAfterPromptValidation(
            id: preset.id,
            action: preset.action,
            template: preset.template
        )
    }

    private static func isValidCustomIdentifier(_ id: PresetID) -> Bool {
        let prefix = "custom-"
        guard id.rawValue.hasPrefix(prefix) else { return false }
        let suffix = String(id.rawValue.dropFirst(prefix.count))
        return suffix == suffix.lowercased() && UUID(uuidString: suffix) != nil
    }
}
