import SharedSupport

public protocol ProviderService: Sendable {
    func generate(
        _ request: TranslationRequest,
        authorizedDestination: ProviderDestinationSnapshot
    ) async -> AsyncThrowingStream<TranslationChunk, Error>
}
