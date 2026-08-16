import SharedSupport

public protocol SystemSelectionProcessing: Sendable {
    func process(
        trigger: CaptureTrigger,
        options: TranslationOptionsSnapshot,
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome
}
