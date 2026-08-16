import Foundation

public struct PresetID: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func custom() -> Self {
        Self(rawValue: "custom-\(UUID().uuidString.lowercased())")
    }
}

public enum PresetAction: String, Codable, Sendable {
    case translate
    case explainWord
    case explainSentence
    case polish
}

public struct CustomPreset: Identifiable, Equatable, Codable, Sendable {
    public let id: PresetID
    public var name: String
    public var explanation: String
    public var template: String
    public var targetLanguage: LanguageChoice
    public var action: PresetAction

    public init(
        id: PresetID,
        name: String,
        explanation: String,
        template: String,
        targetLanguage: LanguageChoice,
        action: PresetAction
    ) {
        self.id = id
        self.name = name
        self.explanation = explanation
        self.template = template
        self.targetLanguage = targetLanguage
        self.action = action
    }
}

public struct PromptPresetDescriptor: Identifiable, Equatable, Sendable {
    public let id: PresetID
    public let nameLocalizationKey: String
    public let explanationLocalizationKey: String
    public let targetLanguage: LanguageChoice
    public let action: PresetAction
    public let isReadOnly: Bool

    package init(
        id: PresetID,
        nameLocalizationKey: String,
        explanationLocalizationKey: String,
        targetLanguage: LanguageChoice,
        action: PresetAction,
        isReadOnly: Bool
    ) {
        self.id = id
        self.nameLocalizationKey = nameLocalizationKey
        self.explanationLocalizationKey = explanationLocalizationKey
        self.targetLanguage = targetLanguage
        self.action = action
        self.isReadOnly = isReadOnly
    }
}

public enum PromptPresetFailure: String, Error, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case explanationTooLong
    case invalidTemplate
    case templateTooLong
    case invalidCustomIdentifier
    case immutableBuiltIn
    case presetNotFound
}

public struct ValidatedPromptPreset: Sendable {
    public let id: PresetID
    public let action: PresetAction
    package let template: String

    private init(id: PresetID, action: PresetAction, template: String) {
        self.id = id
        self.action = action
        self.template = template
    }

    package static func mintAfterPromptValidation(
        id: PresetID,
        action: PresetAction,
        template: String
    ) -> Self {
        Self(id: id, action: action, template: template)
    }
}
