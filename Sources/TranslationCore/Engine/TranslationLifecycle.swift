import SharedSupport

package enum TranslationPhase: Equatable, Sendable {
    case preparing
    case connecting
    case waitingForFirstToken
    case streaming
    case terminal
}

package struct TranslationLifecycle: Sendable {
    package private(set) var phase: TranslationPhase = .connecting
    private var output = ""
    private let requestID: TranslationRequestID
    private let sourceText: String
    private let presetID: PresetID
    private let sourceLanguage: LanguageChoice
    private let targetLanguage: LanguageChoice
    private let providerClass: DestinationPrivacyClass

    package init(
        requestID: TranslationRequestID,
        sourceText: String,
        presetID: PresetID,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        providerClass: DestinationPrivacyClass
    ) {
        self.requestID = requestID
        self.sourceText = sourceText
        self.presetID = presetID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.providerClass = providerClass
    }

    package mutating func accept(
        _ chunk: TranslationChunk
    ) throws -> TranslationUpdate? {
        switch (phase, chunk) {
        case (.connecting, .connected):
            phase = .waitingForFirstToken
            return .waitingForFirstToken
        case (.waitingForFirstToken, .content(let value)) where value.isEmpty:
            return nil
        case (.waitingForFirstToken, .content(let value)):
            phase = .streaming
            output += value
            return .streaming(delta: value)
        case (.streaming, .content(let value)) where value.isEmpty:
            return nil
        case (.streaming, .content(let value)):
            output += value
            return .streaming(delta: value)
        case (.streaming, .done):
            phase = .terminal
            return .completed(
                CompletedTranslation(
                    requestID: requestID,
                    sourceText: sourceText,
                    resultText: output,
                    presetID: presetID,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    providerClass: providerClass
                )
            )
        default:
            throw SanitizedFailure.providerProtocolFailure
        }
    }
}
