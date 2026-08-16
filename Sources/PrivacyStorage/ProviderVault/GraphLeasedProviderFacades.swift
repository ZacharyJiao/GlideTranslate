import SharedSupport

package struct GraphLeasedProviderManagement: ProviderManagement {
    let base: any ProviderManagement
    let lease: PrivacyStorageGraphLease

    public func descriptors() async throws -> [SanitizedProviderDescriptor] {
        try await providerOperation { try await base.descriptors() }
    }

    public func configuration(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationDetails {
        try await providerOperation { try await base.configuration(id) }
    }

    public func create(
        _ draft: ProviderConfigurationDraft,
        credential: consuming SensitiveCredentialInput?
    ) async throws -> SanitizedProviderDescriptor {
        do { try await lease.begin() }
        catch { throw SanitizedFailure.providerRecoveryRequired }
        do {
            let result = try await base.create(
                draft,
                credential: consume credential
            )
            await lease.end()
            return result
        } catch {
            await lease.end()
            throw error
        }
    }

    public func update(
        _ id: ProviderConfigurationID,
        draft: ProviderConfigurationDraft,
        credential: consuming ProviderCredentialChange
    ) async throws -> SanitizedProviderDescriptor {
        do { try await lease.begin() }
        catch { throw SanitizedFailure.providerRecoveryRequired }
        do {
            let result = try await base.update(
                id,
                draft: draft,
                credential: consume credential
            )
            await lease.end()
            return result
        } catch {
            await lease.end()
            throw error
        }
    }

    public func ensureDefaultOllamaConfiguration() async throws
        -> SanitizedProviderDescriptor {
        try await providerOperation {
            try await base.ensureDefaultOllamaConfiguration()
        }
    }

    public func automaticApplications(
        for id: ProviderConfigurationID
    ) async throws -> Set<ApplicationIdentity> {
        try await providerOperation {
            try await base.automaticApplications(for: id)
        }
    }

    public func setAutomaticApplications(
        _ applications: Set<ApplicationIdentity>,
        for id: ProviderConfigurationID
    ) async throws {
        try await providerOperation {
            try await base.setAutomaticApplications(applications, for: id)
        }
    }

    public func delete(_ id: ProviderConfigurationID) async throws {
        try await providerOperation { try await base.delete(id) }
    }

    private func providerOperation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        do { return try await lease.withOperation(operation) }
        catch is PrivacyStorageGraphLeaseFailure {
            throw SanitizedFailure.providerRecoveryRequired
        }
    }
}

package struct GraphLeasedProviderAccess: ProviderAccess {
    let base: any ProviderAccess
    let lease: PrivacyStorageGraphLease

    package func accessDescriptor(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationReadDescriptor {
        try await providerOperation { try await base.accessDescriptor(id) }
    }

    package func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await providerOperation {
            try await base.withValidatedDestination(expected, operation: operation)
        }
    }

    package func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result {
        try await providerOperation {
            try await base.withCredentialLease(expected, operation: operation)
        }
    }

    private func providerOperation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        do { return try await lease.withOperation(operation) }
        catch is PrivacyStorageGraphLeaseFailure {
            throw SanitizedFailure.providerRecoveryRequired
        }
    }
}

package struct GraphLeasedProviderConfirmation: ProviderConfirmationCommitting {
    let base: any ProviderConfirmationCommitting
    let lease: PrivacyStorageGraphLease

    package func commitConfirmation(
        id: ProviderConfigurationID,
        expectedConfigurationRevision: UInt64,
        expectedConfirmationRevision: UInt64,
        proposedClass: DestinationPrivacyClass
    ) async throws -> ProviderConfirmationCommit {
        do {
            return try await lease.withOperation {
                try await base.commitConfirmation(
                    id: id,
                    expectedConfigurationRevision: expectedConfigurationRevision,
                    expectedConfirmationRevision: expectedConfirmationRevision,
                    proposedClass: proposedClass
                )
            }
        } catch is PrivacyStorageGraphLeaseFailure {
            throw SanitizedFailure.providerRecoveryRequired
        }
    }
}
