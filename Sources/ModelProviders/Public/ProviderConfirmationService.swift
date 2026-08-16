import SharedSupport

public protocol ProviderConfirmationService: Sendable {
    func prepareConfirmation(
        for id: ProviderConfigurationID
    ) async throws -> ProviderConfirmationChallenge
    func confirm(
        _ challenge: ProviderConfirmationChallenge
    ) async throws -> ProviderDestinationSnapshot
}
