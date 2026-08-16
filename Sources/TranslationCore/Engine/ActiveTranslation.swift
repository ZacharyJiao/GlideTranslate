import SharedSupport

package struct ActiveTranslation: Sendable {
    package let requestID: TranslationRequestID
    package let generation: UInt64
    package let continuation: AsyncStream<TranslationUpdate>.Continuation
    package let task: Task<Void, Never>
    package var retrySnapshot: RetrySnapshot?
    package var timeoutPhase: TranslationPhase?
    package var timeoutToken: UInt64?
}
