import SharedSupport

public protocol TranslationEngine: Sendable {
    func translate(
        _ intent: AuthorizedTranslationIntent
    ) async -> AsyncStream<TranslationUpdate>
    func retry(
        _ requestID: TranslationRequestID
    ) async -> AsyncStream<TranslationUpdate>
    func cancel(_ requestID: TranslationRequestID) async
}
