import Darwin
import Foundation
import SharedSupport

package struct PreferencesEnvelope: Codable, Sendable {
    package let version: UInt16
    package var snapshot: PreferencesSnapshot

    package static let currentVersion: UInt16 = 1

    package func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw SanitizedFailure.preferencesUnrecoverable
        }
        _ = try snapshot.validated()
        return self
    }
}

package actor ProviderAuthorizationReconciliationBridge:
    OffDeviceAuthorizationReconciling {
    private weak var vault: DefaultProviderVault?
    private var didBind = false

    package init() {}

    package func bind(_ vault: DefaultProviderVault) throws {
        guard !didBind else {
            throw ProviderAuthorizationFailure.maintenanceFailed
        }
        didBind = true
        self.vault = vault
    }

    package func reconcileOffDeviceAuthorizations(
        withGeneralAllowlistCeiling ceiling: Set<ApplicationIdentity>
    ) async throws {
        guard let vault else {
            throw ProviderAuthorizationFailure.maintenanceFailed
        }
        try await vault.reconcileAutomaticApplications(
            withGeneralAllowlistCeiling: ceiling
        )
    }
}

package actor AtomicPreferencesStore:
    PreferencesStore,
    GeneralAutomaticApplicationReading {
    private let fileURL: URL
    private let installer: any AtomicDataInstalling
    private let directoryIdentity: SecureStoreDirectoryIdentity?
    private let offDeviceAuthorizationReconciler:
        any OffDeviceAuthorizationReconciling
    private var currentSnapshot: PreferencesSnapshot
    private var usable = true

    private init(
        fileURL: URL,
        installer: any AtomicDataInstalling,
        directoryIdentity: SecureStoreDirectoryIdentity?,
        offDeviceAuthorizationReconciler: any OffDeviceAuthorizationReconciling,
        snapshot: PreferencesSnapshot,
        usable: Bool = true
    ) {
        self.fileURL = fileURL
        self.installer = installer
        self.directoryIdentity = directoryIdentity
        self.offDeviceAuthorizationReconciler = offDeviceAuthorizationReconciler
        currentSnapshot = snapshot
        self.usable = usable
    }

    package static func open(
        fileURL: URL,
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        directoryIdentity: SecureStoreDirectoryIdentity? = nil,
        offDeviceAuthorizationReconciler: any OffDeviceAuthorizationReconciling
    ) throws -> AtomicPreferencesStore {
        let fileURL = SecureStorePath.canonicalFileURL(fileURL)
        do {
            if let directoryIdentity {
                try directoryIdentity.validateCurrentDirectory(
                    at: fileURL.deletingLastPathComponent()
                )
            } else {
                try SecureStoreDirectoryPreparer.prepare(
                    fileURL.deletingLastPathComponent()
                )
            }
        } catch {
            throw SanitizedFailure.preferencesUnrecoverable
        }
        let snapshot = try loadSnapshot(
            at: fileURL,
            directoryIdentity: directoryIdentity
        )
        return AtomicPreferencesStore(
            fileURL: fileURL,
            installer: installer,
            directoryIdentity: directoryIdentity,
            offDeviceAuthorizationReconciler: offDeviceAuthorizationReconciler,
            snapshot: snapshot
        )
    }

    package static func openResettable(
        fileURL: URL,
        installer: any AtomicDataInstalling = SameDirectoryAtomicInstaller(),
        directoryIdentity: SecureStoreDirectoryIdentity? = nil,
        offDeviceAuthorizationReconciler: any OffDeviceAuthorizationReconciling
    ) -> AtomicPreferencesStore {
        let fileURL = SecureStorePath.canonicalFileURL(fileURL)
        do {
            return try open(
                fileURL: fileURL,
                installer: installer,
                directoryIdentity: directoryIdentity,
                offDeviceAuthorizationReconciler: offDeviceAuthorizationReconciler
            )
        } catch {
            return AtomicPreferencesStore(
                fileURL: fileURL,
                installer: installer,
                directoryIdentity: directoryIdentity,
                offDeviceAuthorizationReconciler: offDeviceAuthorizationReconciler,
                snapshot: .defaultValue,
                usable: false
            )
        }
    }

    public func snapshot() async throws -> PreferencesSnapshot {
        try ensureUsable()
        try validateDirectoryAuthority()
        return currentSnapshot
    }

    public func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {
        try ensureUsable()
        try validateDirectoryAuthority()
        let previous = currentSnapshot
        var candidate = previous
        try transform(&candidate)
        candidate = try candidate.validated()
        let removedApplications = previous.generalAutomaticApplications
            .subtracting(candidate.generalAutomaticApplications)

        let envelope = PreferencesEnvelope(
            version: PreferencesEnvelope.currentVersion,
            snapshot: candidate
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(envelope)
            guard data.count <= PrivacyStorageResourceLimits
                .preferencesEncodedBytes else {
                throw SanitizedFailure.preferencesUnrecoverable
            }
        } catch {
            throw SanitizedFailure.preferencesUnrecoverable
        }

        do {
            try installer.install(
                data,
                at: fileURL,
                expectedDirectoryIdentity: directoryIdentity
            )
        } catch AtomicInstallFailure.durabilityUncertain {
            do {
                let authoritative = try Self.loadSnapshot(
                    at: fileURL,
                    directoryIdentity: directoryIdentity
                )
                currentSnapshot = authoritative
                let authoritativeRemovals = previous.generalAutomaticApplications
                    .subtracting(authoritative.generalAutomaticApplications)
                if !authoritativeRemovals.isEmpty {
                    try? await offDeviceAuthorizationReconciler
                        .reconcileOffDeviceAuthorizations(
                            withGeneralAllowlistCeiling:
                                authoritative.generalAutomaticApplications
                    )
                }
            } catch {
                usable = false
            }
            throw SanitizedFailure.preferencesUnrecoverable
        } catch {
            throw SanitizedFailure.preferencesUnrecoverable
        }

        currentSnapshot = candidate
        guard !removedApplications.isEmpty else { return }
        do {
            try await offDeviceAuthorizationReconciler
                .reconcileOffDeviceAuthorizations(
                    withGeneralAllowlistCeiling:
                        candidate.generalAutomaticApplications
            )
        } catch {
            throw ProviderAuthorizationFailure.maintenanceFailed
        }
    }

    package func generalAutomaticApplications() async throws
        -> Set<ApplicationIdentity> {
        try ensureUsable()
        try validateDirectoryAuthority()
        return currentSnapshot.generalAutomaticApplications
    }

    package func resetForPrivacy() async throws {
        let wasUsable = usable
        usable = true
        do {
            try await update { snapshot in
                snapshot = .defaultValue
            }
        } catch {
            if !wasUsable { usable = false }
            throw error
        }
    }

    private func ensureUsable() throws {
        guard usable else { throw SanitizedFailure.preferencesUnrecoverable }
    }

    private func validateDirectoryAuthority() throws {
        do {
            try directoryIdentity?.validateCurrentDirectory(
                at: fileURL.deletingLastPathComponent()
            )
        } catch {
            throw SanitizedFailure.preferencesUnrecoverable
        }
    }

    private static func loadSnapshot(
        at fileURL: URL,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> PreferencesSnapshot {
        do {
            guard let data = try readRegularFileWithoutFollowingLinks(
                fileURL,
                directoryIdentity: directoryIdentity
            ) else {
                return .defaultValue
            }
            let envelope = try PropertyListDecoder().decode(
                PreferencesEnvelope.self,
                from: data
            )
            return try envelope.validated().snapshot
        } catch let failure as SanitizedFailure {
            throw failure
        } catch {
            throw SanitizedFailure.preferencesUnrecoverable
        }
    }

    private static func readRegularFileWithoutFollowingLinks(
        _ url: URL,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> Data? {
        do {
            return try SecureStoreFileReader.readRegularFileIfPresent(
                at: url,
                expectedDirectoryIdentity: directoryIdentity,
                maximumByteCount: PrivacyStorageResourceLimits
                    .preferencesEncodedBytes
            )
        } catch {
            throw SanitizedFailure.preferencesUnrecoverable
        }
    }
}
