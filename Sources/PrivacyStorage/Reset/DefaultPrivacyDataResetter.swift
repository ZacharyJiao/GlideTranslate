package protocol HistoryPrivacyResetting: Sendable {
    func closeForReset() async throws
    func deleteStoreAndKeyForReset() async throws
}

package protocol CustomPresetPrivacyResetting: Sendable {
    func deleteStoreAndKeyForReset() async throws
}

package protocol ProviderVaultPrivacyResetting: Sendable {
    func deleteAllDataForReset() async throws
}

package protocol PreferencesPrivacyResetting: Sendable {
    func resetForPrivacy() async throws
}

extension DefaultTranslationHistory: HistoryPrivacyResetting {}
extension EncryptedCustomPresetPersistence: CustomPresetPrivacyResetting {}
extension DefaultProviderVault: ProviderVaultPrivacyResetting {}
extension AtomicPreferencesStore: PreferencesPrivacyResetting {}

package actor DefaultPrivacyDataResetter: PrivacyDataResetting {
    private let history: any HistoryPrivacyResetting
    private let customPresets: any CustomPresetPrivacyResetting
    private let providerVault: any ProviderVaultPrivacyResetting
    private let preferences: any PreferencesPrivacyResetting

    package init(
        history: any HistoryPrivacyResetting,
        customPresets: any CustomPresetPrivacyResetting,
        providerVault: any ProviderVaultPrivacyResetting,
        preferences: any PreferencesPrivacyResetting
    ) {
        self.history = history
        self.customPresets = customPresets
        self.providerVault = providerVault
        self.preferences = preferences
    }

    public func closeStores() async throws {
        try await history.closeForReset()
    }

    public func deleteHistoryStoreAndKey() async throws {
        try await history.deleteStoreAndKeyForReset()
    }

    public func deleteCustomPresetStoreAndKey() async throws {
        try await customPresets.deleteStoreAndKeyForReset()
    }

    public func deleteProviderVaultAndCredentials() async throws {
        try await providerVault.deleteAllDataForReset()
    }

    public func resetPreferences() async throws {
        try await preferences.resetForPrivacy()
    }
}
