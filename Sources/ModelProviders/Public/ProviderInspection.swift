import SharedSupport

public protocol ProviderInspection: Sendable {
    func discoverModels(
        for configurationID: ProviderConfigurationID
    ) async throws -> [String]
    func testConnection(
        for configurationID: ProviderConfigurationID
    ) async throws
}
