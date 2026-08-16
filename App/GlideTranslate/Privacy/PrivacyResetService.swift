import PrivacyStorage

@MainActor
protocol ResetEffects: AnyObject {
    func pauseCapture() async throws
    func cancelRequests() async throws
    func unregisterShortcut() async throws
    func unregisterLaunchAtLogin() async throws
    func clearCaches() async throws
}

@MainActor
final class PrivacyResetService {
    private let effects: any ResetEffects
    private let storageReset: any PrivacyDataResetting

    init(
        effects: any ResetEffects,
        storageReset: any PrivacyDataResetting
    ) {
        self.effects = effects
        self.storageReset = storageReset
    }

    func resetAll() async -> ResetReport {
        var failures = Set<ResetStage>()

        await attempt(.pauseCapture, failures: &failures) {
            try await effects.pauseCapture()
        }
        await attempt(.cancelRequests, failures: &failures) {
            try await effects.cancelRequests()
        }
        await attempt(.unregisterShortcut, failures: &failures) {
            try await effects.unregisterShortcut()
        }

        let storesClosed = await attempt(.closeStores, failures: &failures) {
            try await storageReset.closeStores()
        }
        await attempt(.unregisterLaunchAtLogin, failures: &failures) {
            try await effects.unregisterLaunchAtLogin()
        }

        if storesClosed {
            await attempt(.deleteHistoryStoreAndKey, failures: &failures) {
                try await storageReset.deleteHistoryStoreAndKey()
            }
        } else {
            failures.insert(.deleteHistoryStoreAndKey)
        }
        await attempt(.deletePrivatePresetStoreAndKey, failures: &failures) {
            try await storageReset.deleteCustomPresetStoreAndKey()
        }
        await attempt(.deleteProviderVault, failures: &failures) {
            try await storageReset.deleteProviderVaultAndCredentials()
        }
        await attempt(.resetPreferences, failures: &failures) {
            try await storageReset.resetPreferences()
        }
        await attempt(.clearCaches, failures: &failures) {
            try await effects.clearCaches()
        }

        return failures.isEmpty ? .completed : .partialFailure(failures)
    }

    @discardableResult
    private func attempt(
        _ stage: ResetStage,
        failures: inout Set<ResetStage>,
        operation: () async throws -> Void
    ) async -> Bool {
        do {
            try await operation()
            return true
        } catch {
            failures.insert(stage)
            return false
        }
    }
}
