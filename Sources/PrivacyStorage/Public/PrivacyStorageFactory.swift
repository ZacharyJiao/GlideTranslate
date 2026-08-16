import Foundation
import SharedSupport

public struct PrivacyStorageConfiguration: Sendable {
    public let applicationSupportDirectory: URL
    public let keychainServicePrefix: String

    public init(
        applicationSupportDirectory: URL,
        keychainServicePrefix: String
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.keychainServicePrefix = keychainServicePrefix
    }
}

public struct PrivacyStorageServices: Sendable {
    public let preferences: any PreferencesStore
    public let providerManagement: any ProviderManagement
    public let customPresets: any CustomPresetPersistence
    public let history: any TranslationHistory
    public let reset: any PrivacyDataResetting
    public let providerVault: ProviderVaultHandle

    public init(
        preferences: any PreferencesStore,
        providerManagement: any ProviderManagement,
        customPresets: any CustomPresetPersistence,
        history: any TranslationHistory,
        reset: any PrivacyDataResetting,
        providerVault: ProviderVaultHandle
    ) {
        self.preferences = preferences
        self.providerManagement = providerManagement
        self.customPresets = customPresets
        self.history = history
        self.reset = reset
        self.providerVault = providerVault
    }
}

package struct PrivacyStorageFactoryDependencies: Sendable {
    package let symmetricKeys: any SymmetricKeyStoring
    package let providerCredentials: any ProviderCredentialStoring
    package let installer: any AtomicDataInstalling

    package init(
        symmetricKeys: any SymmetricKeyStoring,
        providerCredentials: any ProviderCredentialStoring,
        installer: any AtomicDataInstalling
    ) {
        self.symmetricKeys = symmetricKeys
        self.providerCredentials = providerCredentials
        self.installer = installer
    }
}

public enum PrivacyStorageFactory {
    private static let serviceRegistry = PrivacyStorageServiceRegistry()

    public static func make(
        configuration: PrivacyStorageConfiguration,
        clock: any AppClock
    ) async throws -> PrivacyStorageServices {
        let prefix = configuration.keychainServicePrefix
        return try await make(
            configuration: configuration,
            clock: clock,
            dependencies: PrivacyStorageFactoryDependencies(
                symmetricKeys: SymmetricKeyStore(),
                providerCredentials: KeychainCredentialStore(
                    service: "\(prefix).provider-credential"
                ),
                installer: SameDirectoryAtomicInstaller()
            )
        )
    }

    package static func make(
        configuration: PrivacyStorageConfiguration,
        clock: any AppClock,
        dependencies: PrivacyStorageFactoryDependencies
    ) async throws -> PrivacyStorageServices {
        let directory = configuration.applicationSupportDirectory
        let prefix = configuration.keychainServicePrefix
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path != "/",
              !prefix.isEmpty,
              prefix.count <= 255,
              prefix.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || $0 == "." || $0 == "-"
              }) else {
            throw SanitizedFailure.preferencesUnrecoverable
        }
        let directoryIdentity: SecureStoreDirectoryIdentity
        do {
            directoryIdentity = try SecureStoreDirectoryIdentity
                .capturePrepared(at: directory)
        } catch {
            throw SanitizedFailure.preferencesUnrecoverable
        }

        let authority = PrivacyStorageAuthority(
            path: SecureStorePath.canonicalFileURL(directory).path,
            directoryIdentity: directoryIdentity,
            keychainServicePrefix: prefix
        )
        return try await serviceRegistry.services(for: authority) {
            let lease = PrivacyStorageGraphLease()
            let reconciliation = ProviderAuthorizationReconciliationBridge()
            let preferences = AtomicPreferencesStore.openResettable(
                fileURL: directory.appendingPathComponent("preferences.plist"),
                installer: dependencies.installer,
                directoryIdentity: directoryIdentity,
                offDeviceAuthorizationReconciler: reconciliation
            )
            let metadata = ProviderMetadataRepository(
                fileURL: directory.appendingPathComponent("providers.plist"),
                installer: dependencies.installer,
                directoryIdentity: directoryIdentity
            )
            let vault = await DefaultProviderVault.openResettable(
                metadata: metadata,
                credentials: dependencies.providerCredentials,
                generalApplications: preferences
            )
            try await reconciliation.bind(vault)

            let customPresets = EncryptedCustomPresetPersistence.openResettable(
                fileURL: directory.appendingPathComponent("private-presets.plist"),
                keyStore: dependencies.symmetricKeys,
                installer: dependencies.installer,
                directoryIdentity: directoryIdentity,
                service: "\(prefix).private-presets-key"
            )
            let history = DefaultTranslationHistory(
                preferences: preferences,
                clock: clock,
                fileURL: directory.appendingPathComponent("history.sqlite"),
                keyStore: HistoryKeyStore(
                    keyStore: dependencies.symmetricKeys,
                    service: "\(prefix).history-key"
                ),
                directoryIdentity: directoryIdentity
            )
            let resetCore = DefaultPrivacyDataResetter(
                history: history,
                customPresets: customPresets,
                providerVault: vault,
                preferences: preferences
            )
            let reset = RegistryRetiringPrivacyDataResetter(
                base: resetCore,
                registry: serviceRegistry,
                authority: authority,
                lease: lease
            )
            let handle = ProviderVaultHandle(
                access: GraphLeasedProviderAccess(base: vault, lease: lease),
                confirmation: GraphLeasedProviderConfirmation(
                    base: vault,
                    lease: lease
                )
            )
            return PrivacyStorageServices(
                preferences: GraphLeasedPreferencesStore(
                    base: preferences,
                    lease: lease
                ),
                providerManagement: GraphLeasedProviderManagement(
                    base: vault,
                    lease: lease
                ),
                customPresets: GraphLeasedCustomPresetPersistence(
                    base: customPresets,
                    lease: lease
                ),
                history: GraphLeasedTranslationHistory(
                    base: history,
                    lease: lease
                ),
                reset: reset,
                providerVault: handle
            )
        }
    }
}

private struct PrivacyStorageAuthority: Hashable, Sendable {
    let path: String
    let directoryIdentity: SecureStoreDirectoryIdentity
    let keychainServicePrefix: String
}

private actor PrivacyStorageServiceRegistry {
    private struct Entry {
        let token: UUID
        let task: Task<PrivacyStorageServices, Error>
    }

    private var entries: [PrivacyStorageAuthority: Entry] = [:]

    func services(
        for authority: PrivacyStorageAuthority,
        build: @Sendable @escaping () async throws -> PrivacyStorageServices
    ) async throws -> PrivacyStorageServices {
        if let existing = entries[authority] {
            return try await existing.task.value
        }

        let token = UUID()
        let task = Task { try await build() }
        entries[authority] = Entry(token: token, task: task)
        do {
            return try await task.value
        } catch {
            if entries[authority]?.token == token {
                entries[authority] = nil
            }
            throw error
        }
    }

    func retire(_ authority: PrivacyStorageAuthority) {
        entries[authority] = nil
    }
}

private actor RegistryRetiringPrivacyDataResetter: PrivacyDataResetting {
    private let base: any PrivacyDataResetting
    private let registry: PrivacyStorageServiceRegistry
    private let authority: PrivacyStorageAuthority
    private let lease: PrivacyStorageGraphLease
    private var storesClosed = false
    private var registryRetired = false
    private var retired = false
    private var graphRetirementTask: Task<Void, Never>?

    init(
        base: any PrivacyDataResetting,
        registry: PrivacyStorageServiceRegistry,
        authority: PrivacyStorageAuthority,
        lease: PrivacyStorageGraphLease
    ) {
        self.base = base
        self.registry = registry
        self.authority = authority
        self.lease = lease
    }

    func closeStores() async throws {
        try ensureUsable()
        await retireGraphBeforeReset()
        do {
            try await base.closeStores()
            storesClosed = true
            await retireRegistryEntry()
        } catch {
            await retireRegistryEntry()
            throw error
        }
    }

    func deleteHistoryStoreAndKey() async throws {
        try ensureUsable()
        await waitForStartedGraphRetirement()
        try await base.deleteHistoryStoreAndKey()
    }

    func deleteCustomPresetStoreAndKey() async throws {
        try ensureUsable()
        await waitForStartedGraphRetirement()
        try await base.deleteCustomPresetStoreAndKey()
    }

    func deleteProviderVaultAndCredentials() async throws {
        try ensureUsable()
        await waitForStartedGraphRetirement()
        try await base.deleteProviderVaultAndCredentials()
    }

    func resetPreferences() async throws {
        try ensureUsable()
        guard storesClosed else {
            try await base.resetPreferences()
            return
        }
        await waitForStartedGraphRetirement()
        do {
            try await base.resetPreferences()
            retired = true
        } catch {
            throw error
        }
    }

    private func retireGraphBeforeReset() async {
        let task: Task<Void, Never>
        if let graphRetirementTask {
            task = graphRetirementTask
        } else {
            let created = Task { await lease.retire() }
            graphRetirementTask = created
            task = created
        }
        await task.value
    }

    private func waitForStartedGraphRetirement() async {
        if let graphRetirementTask {
            await graphRetirementTask.value
        }
    }

    private func retireRegistryEntry() async {
        guard !registryRetired else { return }
        await registry.retire(authority)
        registryRetired = true
    }

    private func ensureUsable() throws {
        guard !retired else {
            throw SanitizedFailure.preferencesUnrecoverable
        }
    }
}
