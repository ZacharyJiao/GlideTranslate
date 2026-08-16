import Foundation
import SharedSupport

package actor DefaultProviderVault:
    ProviderManagement,
    ProviderConfigurationReading,
    ProviderAccess,
    ProviderConfirmationCommitting {
    private let metadata: any ProviderMetadataPersisting
    private let credentials: any ProviderCredentialStoring
    private let generalApplications: any GeneralAutomaticApplicationReading
    private let leaseObserver: any ProviderCredentialLeaseObserving
    private var envelope: ProviderMetadataEnvelope
    private var poisoned = false
    private var metadataAuthorityReadable: Bool
    private var operationLocked = false
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var operationWaiters: [OperationWaiter] = []

    private init(
        metadata: any ProviderMetadataPersisting,
        credentials: any ProviderCredentialStoring,
        generalApplications: any GeneralAutomaticApplicationReading,
        leaseObserver: any ProviderCredentialLeaseObserving,
        envelope: ProviderMetadataEnvelope,
        metadataAuthorityReadable: Bool = true,
        poisoned: Bool = false
    ) {
        self.metadata = metadata
        self.credentials = credentials
        self.generalApplications = generalApplications
        self.leaseObserver = leaseObserver
        self.envelope = envelope
        self.metadataAuthorityReadable = metadataAuthorityReadable
        self.poisoned = poisoned
    }

    package static func open(
        metadata: any ProviderMetadataPersisting,
        credentials: any ProviderCredentialStoring,
        generalApplications: any GeneralAutomaticApplicationReading =
            EmptyGeneralAutomaticApplicationReader(),
        leaseObserver: any ProviderCredentialLeaseObserving =
            NoOpProviderCredentialLeaseObserver()
    ) async throws -> DefaultProviderVault {
        let loaded = try await metadata.load().validated()
        let vault = DefaultProviderVault(
            metadata: metadata,
            credentials: credentials,
            generalApplications: generalApplications,
            leaseObserver: leaseObserver,
            envelope: loaded
        )
        try await vault.reconcileStartup()
        return vault
    }

    package static func openResettable(
        metadata: any ProviderMetadataPersisting,
        credentials: any ProviderCredentialStoring,
        generalApplications: any GeneralAutomaticApplicationReading =
            EmptyGeneralAutomaticApplicationReader(),
        leaseObserver: any ProviderCredentialLeaseObserving =
            NoOpProviderCredentialLeaseObserver()
    ) async -> DefaultProviderVault {
        do {
            return try await open(
                metadata: metadata,
                credentials: credentials,
                generalApplications: generalApplications,
                leaseObserver: leaseObserver
            )
        } catch {
            return DefaultProviderVault(
                metadata: metadata,
                credentials: credentials,
                generalApplications: generalApplications,
                leaseObserver: leaseObserver,
                envelope: .empty,
                metadataAuthorityReadable: false,
                poisoned: true
            )
        }
    }

    public func descriptors() async throws -> [SanitizedProviderDescriptor] {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        return envelope.records
            .filter { $0.state == .active }
            .map(Self.descriptor)
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    public func configuration(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationDetails {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        let record = try activeRecord(id)
        return ProviderConfigurationDetails(
            id: record.id,
            protocolKind: record.protocolKind,
            endpoint: record.endpoint,
            model: record.model,
            privacyClass: Self.privacyClass(record),
            hasCredential: record.activeCredentialAccount != nil
        )
    }

    public func create(
        _ draft: ProviderConfigurationDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SanitizedProviderDescriptor {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        return try await createLocked(
            draft,
            credential: consume credential,
            role: .userDefined
        )
    }

    private func createLocked(
        _ draft: ProviderConfigurationDraft,
        credential: consuming SensitiveCredentialInput?,
        role: ProviderConfigurationRole
    ) async throws -> SanitizedProviderDescriptor {
        let id = ProviderConfigurationID()
        let credentialAccount = credential == nil ? nil : UUID()
        let pending = ProviderConfigurationRecord(
            id: id,
            protocolKind: draft.protocolKind,
            endpoint: draft.endpoint,
            model: draft.model,
            confirmedClass: nil,
            configurationRevision: 1,
            confirmationRevision: 0,
            activeCredentialAccount: nil,
            pendingCredentialAccount: credentialAccount,
            cleanupCredentialAccounts: [],
            state: .pendingCredentialWrite,
            role: role
        )
        try await prepareNew(pending)

        if let credential {
            do {
                try await credentials.add(credential, account: credentialAccount!)
            } catch {
                try await compensateFailedNewCredential(id: id)
                throw SanitizedFailure.credentialStoreUnavailable
            }
        }

        do {
            let activated = try await activateNew(id: id)
            return Self.descriptor(activated)
        } catch {
            try ensureUsable()
            guard await hideAuthoritativeNewRecordForRecovery(
                id: id,
                cleanupAccount: credentialAccount
            ) else {
                poisoned = true
                throw SanitizedFailure.providerRecoveryRequired
            }
            let credentialCleanupSucceeded: Bool
            if let credentialAccount {
                do {
                    try await credentials.delete(account: credentialAccount)
                    credentialCleanupSucceeded = true
                } catch {
                    credentialCleanupSucceeded = false
                }
            } else {
                credentialCleanupSucceeded = true
            }
            if !credentialCleanupSucceeded {
                throw SanitizedFailure.providerRecoveryRequired
            }
            let metadataCleanupSucceeded = try await removeOrHideFailedNew(id: id)
            if !metadataCleanupSucceeded {
                throw SanitizedFailure.providerRecoveryRequired
            }
            throw SanitizedFailure.invalidProviderConfiguration
        }
    }

    public func update(
        _ id: ProviderConfigurationID,
        draft: ProviderConfigurationDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SanitizedProviderDescriptor {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        let original = try activeRecord(id)
        if original.role == .defaultOllama {
            guard draft.protocolKind == .ollamaNative,
                  draft.endpoint.absoluteString == "http://127.0.0.1:11434" else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
        }
        guard original.configurationRevision < UInt64.max else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        let pendingAccount: UUID?
        let removesCredential: Bool
        switch credential {
        case .preserve:
            pendingAccount = nil
            removesCredential = false
        case .remove:
            pendingAccount = nil
            removesCredential = true
        case .replace:
            pendingAccount = UUID()
            removesCredential = false
        }

        var prepared = original
        prepared.pendingUpdate = ProviderPendingUpdate(
            protocolKind: draft.protocolKind,
            endpoint: draft.endpoint,
            model: draft.model,
            pendingCredentialAccount: pendingAccount,
            removesCredential: removesCredential
        )
        try await replaceRecord(prepared)

        do {
            if case .replace(let input) = consume credential {
                try await credentials.add(input, account: pendingAccount!)
            }
            var committed = prepared
            committed.protocolKind = draft.protocolKind
            committed.endpoint = draft.endpoint
            committed.model = draft.model
            committed.confirmedClass = nil
            committed.configurationRevision += 1
            committed.pendingUpdate = nil
            if removesCredential {
                committed.activeCredentialAccount = nil
            } else if let pendingAccount {
                committed.activeCredentialAccount = pendingAccount
            }
            if original.activeCredentialAccount != committed.activeCredentialAccount,
               let oldAccount = original.activeCredentialAccount,
               !committed.cleanupCredentialAccounts.contains(oldAccount) {
                committed.cleanupCredentialAccounts.append(oldAccount)
            }
            try await replaceRecord(committed, clearAuthorizations: true)

            if original.activeCredentialAccount != committed.activeCredentialAccount,
               let oldAccount = original.activeCredentialAccount {
                await retireCredential(oldAccount, recordID: id)
                try ensureUsable()
            }
            return Self.descriptor(try activeRecord(id))
        } catch {
            try ensureUsable()
            if let authoritative = envelope.records.first(where: { $0.id == id }),
               authoritative.state == .active,
               authoritative.pendingUpdate == nil,
               authoritative.configurationRevision == original.configurationRevision + 1 {
                if let oldAccount = original.activeCredentialAccount,
                   oldAccount != authoritative.activeCredentialAccount {
                    await retireCredential(oldAccount, recordID: id)
                    try ensureUsable()
                }
                throw SanitizedFailure.invalidProviderConfiguration
            }
            var rollback = original
            var pendingCleanupFailed = false
            if let pendingAccount {
                do {
                    try await credentials.delete(account: pendingAccount)
                } catch {
                    pendingCleanupFailed = true
                    rollback.cleanupCredentialAccounts.append(pendingAccount)
                }
            }
            do {
                try await replaceRecord(rollback)
            } catch {
                try ensureUsable()
                let hidden = await markUpdateRecovery(
                    id: id,
                    pendingAccount: pendingCleanupFailed ? pendingAccount : nil
                )
                if !hidden { poisoned = true }
                throw SanitizedFailure.providerRecoveryRequired
            }
            if pendingCleanupFailed {
                throw SanitizedFailure.providerRecoveryRequired
            }
            if let failure = error as? SanitizedFailure { throw failure }
            throw SanitizedFailure.invalidProviderConfiguration
        }
    }

    public func ensureDefaultOllamaConfiguration() async throws
        -> SanitizedProviderDescriptor {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        if let existing = envelope.records.first(where: {
            $0.state == .active
                && $0.role == .defaultOllama
        }) {
            return Self.descriptor(existing)
        }
        if var promotable = envelope.records.first(where: {
            $0.state == .active
                && $0.role == .userDefined
                && $0.protocolKind == .ollamaNative
                && $0.endpoint.absoluteString == "http://127.0.0.1:11434"
                && $0.model.isEmpty
        }) {
            promotable.role = .defaultOllama
            try await replaceRecord(promotable)
            return Self.descriptor(promotable)
        }
        return try await createLocked(
            ProviderConfigurationDraft(
                protocolKind: .ollamaNative,
                endpoint: URL(string: "http://127.0.0.1:11434")!,
                model: ""
            ),
            credential: nil,
            role: .defaultOllama
        )
    }

    public func automaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity> {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        let record = try activeRecord(id)
        return try OffDeviceAuthorizationStore.valueForRead(
            persisted: envelope.offDeviceAuthorizations[id] ?? [],
            privacyClass: Self.privacyClass(record)
        )
    }

    public func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        let record = try activeRecord(id)
        let general: Set<ApplicationIdentity>
        do {
            general = try await generalApplications.generalAutomaticApplications()
        } catch {
            throw ProviderAuthorizationFailure.generalAllowlistUnavailable
        }
        let accepted = try OffDeviceAuthorizationStore.valueForWrite(
            requested: applications,
            generalAllowlist: general,
            privacyClass: Self.privacyClass(record)
        )
        var candidate = envelope
        candidate.offDeviceAuthorizations[id] = accepted
        try await install(candidate)
    }

    package func effectiveAutomaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity> {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        let record = try activeRecord(id)
        let general: Set<ApplicationIdentity>
        do {
            general = try await generalApplications.generalAutomaticApplications()
        } catch {
            throw ProviderAuthorizationFailure.generalAllowlistUnavailable
        }
        return try OffDeviceAuthorizationStore.effectiveValue(
            persisted: envelope.offDeviceAuthorizations[id] ?? [],
            generalAllowlist: general,
            privacyClass: Self.privacyClass(record)
        )
    }

    package func reconcileAutomaticApplicationsWithGeneralAllowlist() async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        let general: Set<ApplicationIdentity>
        do {
            general = try await generalApplications.generalAutomaticApplications()
        } catch {
            throw ProviderAuthorizationFailure.generalAllowlistUnavailable
        }
        try await reconcileAutomaticApplicationsLocked(
            withGeneralAllowlistCeiling: general
        )
    }

    package func reconcileAutomaticApplications(
        withGeneralAllowlistCeiling general: Set<ApplicationIdentity>
    ) async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        try await reconcileAutomaticApplicationsLocked(
            withGeneralAllowlistCeiling: general
        )
    }

    private func reconcileAutomaticApplicationsLocked(
        withGeneralAllowlistCeiling general: Set<ApplicationIdentity>
    ) async throws {
        var candidate = envelope
        for record in candidate.records {
            let persisted = candidate.offDeviceAuthorizations[record.id] ?? []
            let canBecomeOrRemainActive = record.state == .active
                || (record.state == .recoveryRequired
                    && record.recoveryAction == .restoreActiveAfterCredentialCleanup)
            guard canBecomeOrRemainActive else {
                candidate.offDeviceAuthorizations[record.id] = []
                continue
            }
            switch Self.privacyClass(record) {
            case .localNetwork, .cloud:
                candidate.offDeviceAuthorizations[record.id] =
                    persisted.intersection(general)
            case .localOnDevice, .unresolvedOrChanged:
                candidate.offDeviceAuthorizations[record.id] = []
            }
        }
        guard candidate.offDeviceAuthorizations != envelope.offDeviceAuthorizations else {
            return
        }
        do {
            try await install(candidate)
        } catch let failure as SanitizedFailure
            where failure == .providerRecoveryRequired {
            throw failure
        } catch {
            throw ProviderAuthorizationFailure.maintenanceFailed
        }
    }

    package func commitConfirmation(
        id: ProviderConfigurationID,
        expectedConfigurationRevision: UInt64,
        expectedConfirmationRevision: UInt64,
        proposedClass: DestinationPrivacyClass
    ) async throws -> ProviderConfirmationCommit {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        guard proposedClass == .localNetwork || proposedClass == .cloud,
              var record = envelope.records.first(where: { $0.id == id }),
              record.state == .active,
              record.configurationRevision == expectedConfigurationRevision,
              record.confirmationRevision == expectedConfirmationRevision,
              record.confirmationRevision < UInt64.max else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        record.confirmedClass = proposedClass
        record.confirmationRevision += 1
        var candidate = envelope
        guard let index = candidate.records.firstIndex(where: { $0.id == id }) else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        candidate.records[index] = record
        candidate.offDeviceAuthorizations[id] = []
        try await install(candidate)
        return ProviderConfirmationCommit(
            configurationRevision: record.configurationRevision,
            confirmationRevision: record.confirmationRevision
        )
    }

    public func delete(_ id: ProviderConfigurationID) async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        var record = try activeRecord(id)
        record.state = .deletionPending
        try await replaceRecord(record, clearAuthorizations: true)

        let accounts = Set(
            [record.activeCredentialAccount, record.pendingCredentialAccount]
                .compactMap { $0 } + record.cleanupCredentialAccounts
        )
        do {
            for account in accounts { try await credentials.delete(account: account) }
        } catch {
            throw SanitizedFailure.credentialStoreUnavailable
        }

        var candidate = envelope
        candidate.records.removeAll { $0.id == id }
        candidate.offDeviceAuthorizations.removeValue(forKey: id)
        try await install(candidate)
    }

    package func deleteAllDataForReset() async throws {
        try await acquireOperation()
        defer { releaseOperation() }

        if !metadataAuthorityReadable {
            do {
                try await credentials.deleteAll()
                try await metadata.delete()
                envelope = .empty
                poisoned = false
                metadataAuthorityReadable = true
                return
            } catch {
                throw SanitizedFailure.providerRecoveryRequired
            }
        }

        let accounts = Set(envelope.records.flatMap { record in
            [
                record.activeCredentialAccount,
                record.pendingCredentialAccount,
                record.pendingUpdate?.pendingCredentialAccount
            ].compactMap { $0 } + record.cleanupCredentialAccounts
        })
        if !envelope.records.isEmpty {
            var tombstone = envelope
            tombstone.records = tombstone.records.map { record in
                var record = record
                let ownedAccounts = Set([
                    record.activeCredentialAccount,
                    record.pendingCredentialAccount,
                    record.pendingUpdate?.pendingCredentialAccount
                ].compactMap { $0 } + record.cleanupCredentialAccounts)
                record.activeCredentialAccount = nil
                record.pendingCredentialAccount = nil
                record.pendingUpdate = nil
                record.cleanupCredentialAccounts = ownedAccounts.sorted {
                    $0.uuidString < $1.uuidString
                }
                record.state = .deletionPending
                record.recoveryAction = nil
                return record
            }
            do {
                try await install(tombstone)
            } catch {
                throw SanitizedFailure.providerRecoveryRequired
            }
        }

        var credentialDeletionFailed = false
        for account in accounts.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try await credentials.delete(account: account)
            } catch {
                credentialDeletionFailed = true
            }
        }
        do {
            try await credentials.deleteAll()
            credentialDeletionFailed = false
        } catch {
            credentialDeletionFailed = true
        }
        guard !credentialDeletionFailed else {
            throw SanitizedFailure.providerRecoveryRequired
        }

        do {
            try await metadata.delete()
            envelope = .empty
            poisoned = false
            metadataAuthorityReadable = true
        } catch {
            throw SanitizedFailure.providerRecoveryRequired
        }
    }

    package func accessDescriptor(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationReadDescriptor {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        let record = try activeRecord(id)
        return ProviderConfigurationReadDescriptor(
            id: record.id,
            protocolKind: record.protocolKind,
            endpoint: record.endpoint,
            model: record.model,
            hasCredential: record.activeCredentialAccount != nil,
            confirmedClass: record.confirmedClass,
            configurationRevision: record.configurationRevision,
            confirmationRevision: record.confirmationRevision
        )
    }

    package func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result {
        do {
            try await acquireOperation()
        } catch is CancellationError {
            throw SanitizedFailure.cancelled
        }
        defer { releaseOperation() }
        guard !Task.isCancelled else { throw SanitizedFailure.cancelled }
        try ensureUsable()
        let record = try validatedRecord(expected)
        guard let account = record.activeCredentialAccount else {
            throw SanitizedFailure.invalidCredential
        }
        guard !Task.isCancelled else { throw SanitizedFailure.cancelled }
        leaseObserver.destinationRevalidated()
        let data: Data
        do {
            data = try await credentials.read(account: account)
        } catch let failure as SanitizedFailure where failure == .cancelled {
            throw failure
        } catch {
            guard !Task.isCancelled else { throw SanitizedFailure.cancelled }
            throw SanitizedFailure.credentialStoreUnavailable
        }
        guard !Task.isCancelled else { throw SanitizedFailure.cancelled }
        let value = CredentialHeaderValue(storage: consume data)
        let lease = ProviderCredentialLease(
            credential: value,
            observer: leaseObserver
        )
        guard !Task.isCancelled else { throw SanitizedFailure.cancelled }
        return try await operation(lease)
    }

    package func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        do {
            try await acquireOperation()
        } catch is CancellationError {
            throw SanitizedFailure.cancelled
        }
        defer { releaseOperation() }
        guard !Task.isCancelled else { throw SanitizedFailure.cancelled }
        try ensureUsable()
        _ = try validatedRecord(expected)
        guard !Task.isCancelled else { throw SanitizedFailure.cancelled }
        return try await operation()
    }

    package func reconcileStartup() async throws {
        try await acquireOperation()
        defer { releaseOperation() }
        try ensureUsable()
        try await reconcileStartupLocked()
    }

    private func reconcileStartupLocked() async throws {
        var sawRecoveryRequired = false
        let ids = envelope.records.map(\.id)
        for id in ids {
            try ensureUsable()
            guard let record = envelope.records.first(where: { $0.id == id }) else {
                continue
            }
            switch record.state {
            case .active:
                var recordRecoveryRequired = false
                for account in record.cleanupCredentialAccounts {
                    do {
                        try await credentials.delete(account: account)
                        guard var current = envelope.records.first(where: { $0.id == id }) else {
                            continue
                        }
                        current.cleanupCredentialAccounts.removeAll { $0 == account }
                        try await replaceRecord(current)
                    } catch {
                        try ensureUsable()
                        sawRecoveryRequired = true
                        recordRecoveryRequired = true
                        break
                    }
                }
                guard !recordRecoveryRequired else { continue }
                guard let latest = envelope.records.first(where: { $0.id == id }) else {
                    continue
                }
                if let pending = latest.pendingUpdate?.pendingCredentialAccount {
                    do {
                        try await credentials.delete(account: pending)
                    } catch {
                        try ensureUsable()
                        sawRecoveryRequired = true
                        continue
                    }
                }
                if latest.pendingUpdate != nil {
                    var restored = latest
                    restored.pendingUpdate = nil
                    try await replaceRecord(restored)
                }
            case .pendingCredentialWrite:
                if let account = record.pendingCredentialAccount {
                    do {
                        try await credentials.delete(account: account)
                    } catch {
                        try ensureUsable()
                        sawRecoveryRequired = true
                        continue
                    }
                }
                try await removeRecord(id)
            case .deletionPending:
                let accounts = Set(
                    [record.activeCredentialAccount, record.pendingCredentialAccount]
                        .compactMap { $0 } + record.cleanupCredentialAccounts
                )
                do {
                    for account in accounts {
                        try await credentials.delete(account: account)
                    }
                    try await removeRecord(id)
                } catch {
                    try ensureUsable()
                    sawRecoveryRequired = true
                }
            case .recoveryRequired:
                switch record.recoveryAction {
                case .removeRecordAfterCredentialCleanup:
                    let accounts = Set(
                        [record.activeCredentialAccount, record.pendingCredentialAccount]
                            .compactMap { $0 }
                            + record.cleanupCredentialAccounts
                    )
                    do {
                        for account in accounts {
                            try await credentials.delete(account: account)
                        }
                        try await removeRecord(id)
                    } catch {
                        try ensureUsable()
                        sawRecoveryRequired = true
                    }
                case .restoreActiveAfterCredentialCleanup:
                    let accounts = Set(
                        [record.pendingUpdate?.pendingCredentialAccount].compactMap { $0 }
                            + record.cleanupCredentialAccounts
                    )
                    do {
                        for account in accounts {
                            try await credentials.delete(account: account)
                        }
                        var restored = record
                        restored.state = .active
                        restored.pendingUpdate = nil
                        restored.cleanupCredentialAccounts = []
                        restored.recoveryAction = nil
                        try await replaceRecord(restored)
                    } catch {
                        try ensureUsable()
                        sawRecoveryRequired = true
                    }
                case .manual, .none:
                    sawRecoveryRequired = true
                }
            }
        }
        if !sawRecoveryRequired,
           envelope.records.isEmpty,
           envelope.offDeviceAuthorizations.isEmpty {
            do {
                try await metadata.delete()
            } catch {
                sawRecoveryRequired = true
            }
        }
        if sawRecoveryRequired {
            throw SanitizedFailure.providerRecoveryRequired
        }
    }
}

private extension DefaultProviderVault {
    func validatedRecord(
        _ expected: ProviderDestinationSnapshot
    ) throws -> ProviderConfigurationRecord {
        guard let record = envelope.records.first(where: {
            $0.id == expected.configurationID
        }), record.state == .active,
              record.configurationRevision == expected.configurationRevision,
              record.confirmationRevision == expected.confirmationRevision,
              record.protocolKind == expected.protocolKind,
              record.model == expected.model,
              Self.matchesPrivacy(record: record, expected: expected.privacyClass),
              Self.matchesOrigin(record.endpoint, expected: expected.origin) else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        return record
    }

    func activeRecord(_ id: ProviderConfigurationID) throws
        -> ProviderConfigurationRecord {
        try ensureUsable()
        guard let record = envelope.records.first(where: { $0.id == id }),
              record.state == .active else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        return record
    }

    func install(_ candidate: ProviderMetadataEnvelope) async throws {
        let candidate = try candidate.validated()
        do {
            try await metadata.install(candidate)
            envelope = candidate
        } catch ProviderMetadataPersistenceFailure.durabilityUncertain(
            let authoritative
        ) {
            envelope = try authoritative.validated()
            throw SanitizedFailure.invalidProviderConfiguration
        } catch ProviderMetadataPersistenceFailure.durabilityUncertainReloadFailed {
            poisoned = true
            throw SanitizedFailure.providerRecoveryRequired
        }
    }

    func prepareNew(_ record: ProviderConfigurationRecord) async throws {
        var candidate = envelope
        candidate.records.append(record)
        candidate.offDeviceAuthorizations[record.id] = []
        try await install(candidate)
    }

    func activateNew(id: ProviderConfigurationID) async throws
        -> ProviderConfigurationRecord {
        guard var record = envelope.records.first(where: { $0.id == id }),
              record.state == .pendingCredentialWrite else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        record.activeCredentialAccount = record.pendingCredentialAccount
        record.pendingCredentialAccount = nil
        record.state = .active
        try await replaceRecord(record)
        return record
    }

    func compensateFailedNewCredential(id: ProviderConfigurationID) async throws {
        do {
            try await removeRecord(id)
        } catch {
            try ensureUsable()
            await markNewRecovery(id: id, cleanupAccount: nil)
            throw SanitizedFailure.providerRecoveryRequired
        }
    }

    func removeOrHideFailedNew(id: ProviderConfigurationID) async throws -> Bool {
        do {
            try await removeRecord(id)
            return true
        } catch {
            try ensureUsable()
            await markNewRecovery(id: id, cleanupAccount: nil)
            return false
        }
    }

    func replaceRecord(
        _ record: ProviderConfigurationRecord,
        clearAuthorizations: Bool = false
    ) async throws {
        var candidate = envelope
        guard let index = candidate.records.firstIndex(where: { $0.id == record.id }) else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        candidate.records[index] = record
        if clearAuthorizations {
            candidate.offDeviceAuthorizations[record.id] = []
        }
        try await install(candidate)
    }

    func removeRecord(_ id: ProviderConfigurationID) async throws {
        var candidate = envelope
        candidate.records.removeAll { $0.id == id }
        candidate.offDeviceAuthorizations.removeValue(forKey: id)
        try await install(candidate)
    }

    func markUpdateRecovery(
        id: ProviderConfigurationID,
        pendingAccount: UUID?
    ) async -> Bool {
        guard var record = envelope.records.first(where: { $0.id == id }) else {
            return false
        }
        record.state = .recoveryRequired
        record.recoveryAction = .restoreActiveAfterCredentialCleanup
        if let pendingAccount,
           record.pendingUpdate?.pendingCredentialAccount != pendingAccount,
           !record.cleanupCredentialAccounts.contains(pendingAccount) {
            record.cleanupCredentialAccounts.append(pendingAccount)
        }
        do {
            try await replaceRecord(record)
            return true
        } catch {
            return false
        }
    }

    func markNewRecovery(id: ProviderConfigurationID, cleanupAccount: UUID?) async {
        guard var record = envelope.records.first(where: { $0.id == id }) else {
            return
        }
        record.state = .recoveryRequired
        record.recoveryAction = .removeRecordAfterCredentialCleanup
        if let cleanupAccount,
           record.activeCredentialAccount != cleanupAccount,
           record.pendingCredentialAccount != cleanupAccount,
           !record.cleanupCredentialAccounts.contains(cleanupAccount) {
            record.cleanupCredentialAccounts.append(cleanupAccount)
        }
        try? await replaceRecord(record)
    }

    func hideAuthoritativeNewRecordForRecovery(
        id: ProviderConfigurationID,
        cleanupAccount: UUID?
    ) async -> Bool {
        guard var record = envelope.records.first(where: { $0.id == id }) else {
            return true
        }
        if record.state == .recoveryRequired,
           record.recoveryAction == .removeRecordAfterCredentialCleanup {
            return true
        }
        record.state = .recoveryRequired
        record.recoveryAction = .removeRecordAfterCredentialCleanup
        record.pendingUpdate = nil
        if let cleanupAccount,
           record.activeCredentialAccount != cleanupAccount,
           record.pendingCredentialAccount != cleanupAccount,
           !record.cleanupCredentialAccounts.contains(cleanupAccount) {
            record.cleanupCredentialAccounts.append(cleanupAccount)
        }
        do {
            try await replaceRecord(record)
            return true
        } catch {
            return false
        }
    }

    func retireCredential(_ account: UUID, recordID: ProviderConfigurationID) async {
        do {
            try await credentials.delete(account: account)
            guard var record = envelope.records.first(where: { $0.id == recordID }) else {
                return
            }
            record.cleanupCredentialAccounts.removeAll { $0 == account }
            try? await replaceRecord(record)
        } catch {
            // The account was placed in the committed cleanup ledger before
            // deletion, so retaining the current record is the safe retry state.
        }
    }

    func acquireOperation() async throws {
        try Task.checkCancellation()
        guard operationLocked else {
            operationLocked = true
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operationWaiters.append(OperationWaiter(
                    id: id,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelOperationWaiter(id) }
        }
        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            releaseOperation()
            throw CancellationError()
        }
    }

    func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    func ensureUsable() throws {
        guard !poisoned else {
            throw SanitizedFailure.providerRecoveryRequired
        }
    }

    func releaseOperation() {
        if operationWaiters.isEmpty {
            operationLocked = false
        } else {
            operationWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    nonisolated static func descriptor(
        _ record: ProviderConfigurationRecord
    ) -> SanitizedProviderDescriptor {
        SanitizedProviderDescriptor(
            id: record.id,
            protocolKind: record.protocolKind,
            privacyClass: privacyClass(record),
            hasCredential: record.activeCredentialAccount != nil
        )
    }

    nonisolated static func privacyClass(
        _ record: ProviderConfigurationRecord
    ) -> DestinationPrivacyClass {
        if let confirmedClass = record.confirmedClass { return confirmedClass }
        let components = URLComponents(
            url: record.endpoint,
            resolvingAgainstBaseURL: false
        )
        let host: String? = if let rawHost = components?.host,
                               let percentEncodedHost = components?.percentEncodedHost {
            ProviderHostCanonicalizer.normalize(
                rawHost: rawHost,
                percentEncodedHost: percentEncodedHost
            )
        } else {
            nil
        }
        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            return .localOnDevice
        }
        return .unresolvedOrChanged
    }

    nonisolated static func matchesPrivacy(
        record: ProviderConfigurationRecord,
        expected: DestinationPrivacyClass
    ) -> Bool {
        switch expected {
        case .localOnDevice:
            return record.confirmedClass == nil
                && privacyClass(record) == .localOnDevice
        case .localNetwork, .cloud:
            return record.confirmedClass == expected
        case .unresolvedOrChanged:
            return false
        }
    }

    nonisolated static func matchesOrigin(
        _ endpoint: URL,
        expected: ProviderOrigin
    ) -> Bool {
        guard let components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
           let rawHost = components.host,
           let percentEncodedHost = components.percentEncodedHost,
           let host = ProviderHostCanonicalizer.normalize(
               rawHost: rawHost,
               percentEncodedHost: percentEncodedHost
           ) else {
            return false
        }
        let defaultPort: UInt16
        switch scheme {
        case "http": defaultPort = 80
        case "https": defaultPort = 443
        default: return false
        }
        let port: UInt16
        if let explicit = components.port,
           let value = UInt16(exactly: explicit) {
            port = value
        } else {
            port = defaultPort
        }
        return scheme == expected.scheme
            && host == expected.host
            && port == expected.effectivePort
    }
}
