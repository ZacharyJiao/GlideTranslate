public enum ProviderOutcomeCategory: String, Equatable, Sendable {
    case succeeded
    case unavailable
    case timedOut
    case cancelled
    case protocolFailure
}

public struct ProviderDiagnosticEvent: Equatable, Sendable {
    public let providerClass: DestinationPrivacyClass
    public let outcomeCategory: ProviderOutcomeCategory
    public let durationMilliseconds: UInt64

    package init(
        providerClass: DestinationPrivacyClass,
        outcomeCategory: ProviderOutcomeCategory,
        durationMilliseconds: UInt64
    ) {
        self.providerClass = providerClass
        self.outcomeCategory = outcomeCategory
        self.durationMilliseconds = durationMilliseconds
    }
}
