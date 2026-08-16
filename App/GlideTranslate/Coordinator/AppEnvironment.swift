import ModelProviders
import PrivacyStorage
import SelectionCapture
import SharedSupport
import TranslationCore

struct AppEnvironment: Sendable {
    let systemSelectionProcessor: any SystemSelectionProcessing
    let authorizationGate: any SelectionAuthorizationGate
    let translationEngine: any TranslationEngine
    let preferences: any PreferencesStore
    let providerManagement: any ProviderManagement
    let providerPreflight: any ProviderPreflight
    let providerInspection: any ProviderInspection
    let providerConfirmation: any ProviderConfirmationService
    let promptPresets: any PromptPresetStore
    let history: any TranslationHistory
    let logger: SafeLogger
}

struct SystemAuthorizationInputs: Sendable {
    let preferences: PreferencesSnapshot
    let providerID: ProviderConfigurationID
    let provider: ProviderDestinationSnapshot
    let policy: CapturePolicySnapshot
}

struct ManualAuthorizationInputs: Sendable {
    let preferences: PreferencesSnapshot
    let providerID: ProviderConfigurationID
    let provider: ProviderDestinationSnapshot
}

struct AuthorizationContextLoader: Sendable {
    private let preferences: any PreferencesStore
    private let providerManagement: any ProviderManagement
    private let providerPreflight: any ProviderPreflight

    init(
        preferences: any PreferencesStore,
        providerManagement: any ProviderManagement,
        providerPreflight: any ProviderPreflight
    ) {
        self.preferences = preferences
        self.providerManagement = providerManagement
        self.providerPreflight = providerPreflight
    }

    func systemInputs(
        for trigger: CaptureTrigger
    ) async throws -> SystemAuthorizationInputs {
        let snapshot = try await preferences.snapshot()
        guard let providerID = snapshot.defaultProviderID else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        let provider = try await resolvedProvider(providerID)
        let isAutomatic = trigger == .mouse || trigger == .keyboardSelection
        let storedProviderApplications: Set<ApplicationIdentity>
        switch (isAutomatic, provider.privacyClass) {
        case (true, .localNetwork), (true, .cloud):
            storedProviderApplications = try await providerManagement
                .automaticApplications(for: providerID)
        case (false, _), (true, .localOnDevice), (true, .unresolvedOrChanged):
            storedProviderApplications = []
        }
        let policy = CapturePolicySnapshot(
            automaticCaptureEnabled: snapshot.automaticCaptureEnabled,
            mouseSelectionEnabled: snapshot.mouseSelectionEnabled,
            keyboardSelectionEnabled: snapshot.keyboardSelectionEnabled,
            generalAllowlist: snapshot.generalAutomaticApplications,
            offDeviceAllowlist: storedProviderApplications.intersection(
                snapshot.generalAutomaticApplications
            ),
            clipboardFallbackEnabled: snapshot.clipboardFallbackEnabled,
            selectionDebounceMilliseconds: snapshot.selectionDebounceMilliseconds,
            selectionCharacterLimit: snapshot.selectionCharacterLimit
        )
        return SystemAuthorizationInputs(
            preferences: snapshot,
            providerID: providerID,
            provider: provider,
            policy: policy
        )
    }

    func manualInputs(
        selectedProviderID: ProviderConfigurationID?
    ) async throws -> ManualAuthorizationInputs {
        let snapshot = try await preferences.snapshot()
        guard let providerID = selectedProviderID ?? snapshot.defaultProviderID else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        return ManualAuthorizationInputs(
            preferences: snapshot,
            providerID: providerID,
            provider: try await resolvedProvider(providerID)
        )
    }

    private func resolvedProvider(
        _ providerID: ProviderConfigurationID
    ) async throws -> ProviderDestinationSnapshot {
        switch await providerPreflight.resolveDestination(for: providerID) {
        case let .success(provider): return provider
        case let .failure(failure): throw failure
        }
    }
}
