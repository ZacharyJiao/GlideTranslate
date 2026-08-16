import SharedSupport

package struct RetrySnapshot: Sendable {
    package let intent: AuthorizedTranslationIntent
    package let resolvedSource: LanguageChoice
    package let target: LanguageChoice
    package let providerConfigurationID: ProviderConfigurationID
    package let model: String
}
