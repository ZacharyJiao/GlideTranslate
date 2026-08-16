import Foundation

public struct TranslationRequestID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TranslationRecordID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TranslationTimeoutPolicy: Equatable, Sendable {
    public let connection: Duration
    public let firstToken: Duration
    public let streamIdle: Duration

    public init(connection: Duration, firstToken: Duration, streamIdle: Duration) {
        self.connection = connection
        self.firstToken = firstToken
        self.streamIdle = streamIdle
    }
}

public struct TranslationOptionsSnapshot: Sendable {
    public let sourceLanguage: LanguageChoice
    public let targetLanguage: LanguageChoice
    public let preset: ValidatedPromptPreset
    public let timeouts: TranslationTimeoutPolicy

    public init(
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        preset: ValidatedPromptPreset,
        timeouts: TranslationTimeoutPolicy
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.preset = preset
        self.timeouts = timeouts
    }
}

public struct ManualTranslationSubmission: Sendable {
    public let text: String
    public let options: TranslationOptionsSnapshot
    public let providerConfigurationID: ProviderConfigurationID

    public init(
        text: String,
        options: TranslationOptionsSnapshot,
        providerConfigurationID: ProviderConfigurationID
    ) {
        self.text = text
        self.options = options
        self.providerConfigurationID = providerConfigurationID
    }
}

public enum TranslationUpdate: Equatable, Sendable {
    case preparing
    case connecting
    case waitingForFirstToken
    case streaming(delta: String)
    case completed(CompletedTranslation)
    case cancelled
    case failed(SanitizedFailure)
}

public struct TranslationRequest: Sendable {
    package let instruction: String
    package let userContent: String
    package let model: String
    package let timeouts: TranslationTimeoutPolicy
    package let requestID: TranslationRequestID

    package init(
        instruction: String,
        userContent: String,
        model: String,
        timeouts: TranslationTimeoutPolicy,
        requestID: TranslationRequestID
    ) {
        self.instruction = instruction
        self.userContent = userContent
        self.model = model
        self.timeouts = timeouts
        self.requestID = requestID
    }
}

public enum TranslationChunk: Equatable, Sendable {
    case connected
    case content(String)
    case done
}

public struct CompletedTranslation: Equatable, Sendable {
    public let requestID: TranslationRequestID
    public let sourceText: String
    public let resultText: String
    public let presetID: PresetID
    public let sourceLanguage: LanguageChoice
    public let targetLanguage: LanguageChoice
    public let providerClass: DestinationPrivacyClass

    package init(
        requestID: TranslationRequestID,
        sourceText: String,
        resultText: String,
        presetID: PresetID,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        providerClass: DestinationPrivacyClass
    ) {
        self.requestID = requestID
        self.sourceText = sourceText
        self.resultText = resultText
        self.presetID = presetID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.providerClass = providerClass
    }
}
