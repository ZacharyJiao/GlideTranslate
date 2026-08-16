import SharedSupport

public protocol PrivacyDataResetting: Sendable {
    func closeStores() async throws
    func deleteHistoryStoreAndKey() async throws
    func deleteCustomPresetStoreAndKey() async throws
    func deleteProviderVaultAndCredentials() async throws
    func resetPreferences() async throws
}
