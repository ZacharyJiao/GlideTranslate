import SharedSupport

public protocol SelectionAuthorizationGate: Sendable {
    func authorizeSystemSelection(
        trigger: CaptureTrigger,
        context: ForegroundApplicationContext,
        options: TranslationOptionsSnapshot,
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome

    func authorizeManualSubmission(
        _ submission: ManualTranslationSubmission,
        policy: SendPolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome
}

public enum SelectionAuthorizationOutcome: Sendable {
    case authorized(
        AuthorizedTranslationIntent,
        AuthorizedTranslationPresentationContext
    )
    case manualInputRequired
    case rejected(SelectionAuthorizationFailure)
}
