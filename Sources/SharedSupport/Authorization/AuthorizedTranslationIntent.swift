import CoreGraphics

public struct AuthorizedTranslationPayload: Sendable {
    package let text: String
    package let sourceApplication: ApplicationIdentity?
    package let options: TranslationOptionsSnapshot
    package let provider: ProviderDestinationSnapshot
    package let displayRect: CGRect?

    package init(
        text: String,
        sourceApplication: ApplicationIdentity?,
        options: TranslationOptionsSnapshot,
        provider: ProviderDestinationSnapshot,
        displayRect: CGRect?
    ) {
        self.text = text
        self.sourceApplication = sourceApplication
        self.options = options
        self.provider = provider
        self.displayRect = displayRect
    }
}

public struct AuthorizedTranslationPresentationContext: Sendable {
    public let sourceText: String
    public let sourceApplication: ApplicationIdentity?
    public let sourceLanguage: LanguageChoice
    public let targetLanguage: LanguageChoice
    public let presetID: PresetID
    public let providerClass: DestinationPrivacyClass
    public let displayRect: CGRect?

    package init(payload: AuthorizedTranslationPayload) {
        sourceText = payload.text
        sourceApplication = payload.sourceApplication
        sourceLanguage = payload.options.sourceLanguage
        targetLanguage = payload.options.targetLanguage
        presetID = payload.options.preset.id
        providerClass = payload.provider.privacyClass
        displayRect = payload.displayRect
    }
}

public struct AuthorizedTranslationIntent: Sendable {
    public let requestID: TranslationRequestID
    package let payload: AuthorizedTranslationPayload

    private init(
        requestID: TranslationRequestID,
        payload: AuthorizedTranslationPayload
    ) {
        self.requestID = requestID
        self.payload = payload
    }

    package static func mintAfterAuthorization(
        requestID: TranslationRequestID,
        payload: AuthorizedTranslationPayload
    ) -> Self {
        Self(requestID: requestID, payload: payload)
    }
}
