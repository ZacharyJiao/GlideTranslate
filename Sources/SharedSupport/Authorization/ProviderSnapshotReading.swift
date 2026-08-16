public protocol ProviderSnapshotReading: Sendable {
    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure>
}
