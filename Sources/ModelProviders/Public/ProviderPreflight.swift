import SharedSupport

public protocol ProviderPreflight: ProviderSnapshotReading, Sendable {
    func resolveDestination(
        for configurationID: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure>
}
