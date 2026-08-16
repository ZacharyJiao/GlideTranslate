import SharedSupport

package protocol ProviderAccess: ProviderConfigurationReading, Sendable {
    func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result

    func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result
}
