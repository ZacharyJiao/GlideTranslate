import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

actor MutableGeneralApplications: GeneralAutomaticApplicationReading {
    private var applications: Set<ApplicationIdentity>
    private var failure = false

    init(_ applications: Set<ApplicationIdentity>) {
        self.applications = applications
    }

    func generalAutomaticApplications() async throws -> Set<ApplicationIdentity> {
        if failure { throw SanitizedFailure.preferencesUnrecoverable }
        return applications
    }

    func replace(_ applications: Set<ApplicationIdentity>) {
        self.applications = applications
    }

    func setFailure(_ value: Bool) {
        failure = value
    }
}

actor BlockingGeneralApplications: GeneralAutomaticApplicationReading {
    private var applications: Set<ApplicationIdentity>
    private var shouldBlock = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ applications: Set<ApplicationIdentity>) {
        self.applications = applications
    }

    func blockNextRead() { shouldBlock = true }
    func hasBlockedRead() -> Bool { blocked }
    func replace(_ applications: Set<ApplicationIdentity>) {
        self.applications = applications
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }

    func generalAutomaticApplications() async throws -> Set<ApplicationIdentity> {
        let captured = applications
        if shouldBlock {
            shouldBlock = false
            blocked = true
            await withCheckedContinuation { continuation = $0 }
            blocked = false
        }
        return captured
    }
}

final class OffDeviceAuthorizationTests: XCTestCase {
    func testLocalConfigurationAlwaysStoresAndReadsEmpty() async throws {
        let general = MutableGeneralApplications([appA])
        let fixture = try await makeAuthorizationVault(general: general)
        let local = try await fixture.vault.ensureDefaultOllamaConfiguration()
        try await fixture.vault.setAutomaticApplications([appA], for: local.id)
        let stored = try await fixture.vault.automaticApplications(for: local.id)
        XCTAssertTrue(stored.isEmpty)
        let persisted = await fixture.metadata.snapshot()
        XCTAssertTrue(persisted.offDeviceAuthorizations[local.id]?.isEmpty == true)
    }

    func testConfirmedNetworkAndCloudAcceptOnlyGeneralSubset() async throws {
        for privacyClass in [DestinationPrivacyClass.localNetwork, .cloud] {
            let general = MutableGeneralApplications([appA, appB])
            let fixture = try await makeAuthorizationVault(general: general)
            let created = try await fixture.vault.create(remoteDraft, credential: nil)
            _ = try await fixture.vault.commitConfirmation(
                id: created.id,
                expectedConfigurationRevision: 1,
                expectedConfirmationRevision: 0,
                proposedClass: privacyClass
            )
            try await fixture.vault.setAutomaticApplications([appA], for: created.id)
            var stored = try await fixture.vault.automaticApplications(for: created.id)
            XCTAssertEqual(stored, [appA])
            do {
                try await fixture.vault.setAutomaticApplications([appA, appC], for: created.id)
                XCTFail("Expected subset rejection")
            } catch {
                XCTAssertEqual(
                    error as? ProviderAuthorizationFailure,
                    .notSubsetOfGeneralAllowlist
                )
            }
            stored = try await fixture.vault.automaticApplications(for: created.id)
            XCTAssertEqual(stored, [appA])
        }
    }

    func testNewUpdateAndDeleteNeverInheritAuthorization() async throws {
        let general = MutableGeneralApplications([appA])
        let fixture = try await makeAuthorizationVault(general: general)
        let created = try await fixture.vault.create(remoteDraft, credential: nil)
        let initial = await fixture.metadata.snapshot()
        XCTAssertTrue(initial.offDeviceAuthorizations[created.id]?.isEmpty == true)
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await fixture.vault.setAutomaticApplications([appA], for: created.id)
        _ = try await fixture.vault.update(
            created.id,
            draft: ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://replacement.invalid/v1")!,
                model: "replacement"
            ),
            credential: .preserve
        )
        do {
            _ = try await fixture.vault.automaticApplications(for: created.id)
            XCTFail("Changed unconfirmed destination must fail closed")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        var persisted = await fixture.metadata.snapshot()
        XCTAssertTrue(persisted.offDeviceAuthorizations[created.id]?.isEmpty == true)
        try await fixture.vault.delete(created.id)
        persisted = await fixture.metadata.snapshot()
        XCTAssertNil(persisted.offDeviceAuthorizations[created.id])
    }

    func testGeneralShrinkNarrowsEffectiveReadBeforeBestEffortCleanup() async throws {
        let general = MutableGeneralApplications([appA, appB])
        let fixture = try await makeAuthorizationVault(general: general)
        let created = try await fixture.vault.create(remoteDraft, credential: nil)
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await fixture.vault.setAutomaticApplications([appA, appB], for: created.id)
        await general.replace([appA])

        let effective = try await fixture.vault.effectiveAutomaticApplications(
            for: created.id
        )
        XCTAssertEqual(effective, [appA])
        var persistedValue = try await fixture.vault.automaticApplications(for: created.id)
        XCTAssertEqual(persistedValue, [appA, appB])
        try await fixture.vault.reconcileAutomaticApplicationsWithGeneralAllowlist()
        persistedValue = try await fixture.vault.automaticApplications(for: created.id)
        XCTAssertEqual(persistedValue, [appA])
    }

    func testCleanupFailureNeverWidensFreshEffectiveIntersection() async throws {
        let general = MutableGeneralApplications([appA, appB])
        let metadata = MemoryProviderMetadata(failureCalls: [5])
        let fixture = try await makeAuthorizationVault(
            metadata: metadata,
            general: general
        )
        let created = try await fixture.vault.create(remoteDraft, credential: nil)
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await fixture.vault.setAutomaticApplications([appA, appB], for: created.id)
        await general.replace([appA])
        do {
            try await fixture.vault.reconcileAutomaticApplicationsWithGeneralAllowlist()
            XCTFail("Expected maintenance failure")
        } catch {
            XCTAssertEqual(error as? ProviderAuthorizationFailure, .maintenanceFailed)
        }
        let effective = try await fixture.vault.effectiveAutomaticApplications(
            for: created.id
        )
        XCTAssertEqual(effective, [appA])
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.offDeviceAuthorizations[created.id], [appA, appB])
    }

    func testGeneralReaderFailureDoesNotMutatePersistedSet() async throws {
        let general = MutableGeneralApplications([appA])
        let fixture = try await makeAuthorizationVault(general: general)
        let created = try await fixture.vault.create(remoteDraft, credential: nil)
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        await general.setFailure(true)
        do {
            try await fixture.vault.setAutomaticApplications([appA], for: created.id)
            XCTFail("Expected policy read failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderAuthorizationFailure,
                .generalAllowlistUnavailable
            )
        }
        let persisted = await fixture.metadata.snapshot()
        XCTAssertTrue(persisted.offDeviceAuthorizations[created.id]?.isEmpty == true)
    }

    func testClassChangeToLocalClearsPersistedAndReadableAuthorization() async throws {
        let general = MutableGeneralApplications([appA])
        let fixture = try await makeAuthorizationVault(general: general)
        let created = try await fixture.vault.create(remoteDraft, credential: nil)
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await fixture.vault.setAutomaticApplications([appA], for: created.id)
        _ = try await fixture.vault.update(
            created.id,
            draft: ProviderConfigurationDraft(
                protocolKind: .ollamaNative,
                endpoint: URL(string: "http://127.0.0.1:11434")!,
                model: "local-model"
            ),
            credential: .preserve
        )
        let stored = try await fixture.vault.automaticApplications(for: created.id)
        let persisted = await fixture.metadata.snapshot()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertTrue(persisted.offDeviceAuthorizations[created.id]?.isEmpty == true)
        XCTAssertNil(persisted.records.only?.confirmedClass)
        XCTAssertEqual(persisted.records.only?.configurationRevision, 2)
    }

    func testConcurrentGeneralShrinkCannotWidenEffectiveAuthorization() async throws {
        let general = BlockingGeneralApplications([appA, appB])
        let metadata = MemoryProviderMetadata(envelope: authorizationEnvelope())
        let credentials = MemoryCredentialStore()
        let vault = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials,
            generalApplications: general
        )
        await general.blockNextRead()
        let write = Task {
            try await vault.setAutomaticApplications(
                [appA, appB],
                for: authorizationID
            )
        }
        while !(await general.hasBlockedRead()) { await Task.yield() }
        await general.replace([appA])
        await general.release()
        try await write.value

        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.offDeviceAuthorizations[authorizationID], [appA, appB])
        let effective = try await vault.effectiveAutomaticApplications(
            for: authorizationID
        )
        XCTAssertEqual(effective, [appA])
    }

    func testDeletionTombstoneClearsAuthorizationBeforeCredentialCleanup() async throws {
        let general = MutableGeneralApplications([appA])
        let credentials = MemoryCredentialStore(deleteFailures: [1])
        let fixture = try await makeAuthorizationVault(
            credentials: credentials,
            general: general
        )
        let created = try await fixture.vault.create(
            remoteDraft,
            credential: SensitiveCredentialInput("credential")
        )
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await fixture.vault.setAutomaticApplications([appA], for: created.id)
        do {
            try await fixture.vault.delete(created.id)
            XCTFail("Expected credential cleanup failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .credentialStoreUnavailable)
        }
        var persisted = await fixture.metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.state, .deletionPending)
        XCTAssertTrue(persisted.offDeviceAuthorizations[created.id]?.isEmpty == true)
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: credentials,
            generalApplications: general
        )
        let descriptors = try await reopened.descriptors()
        XCTAssertTrue(descriptors.isEmpty)
        persisted = await fixture.metadata.snapshot()
        XCTAssertNil(persisted.offDeviceAuthorizations[created.id])
    }

    func testGeneralShrinkRepairsHiddenUpdateBeforeStartupRestoresIt() async throws {
        let general = MutableGeneralApplications([appA, appB])
        let metadata = MemoryProviderMetadata(failureCalls: [6, 7])
        let credentials = MemoryCredentialStore()
        let fixture = try await makeAuthorizationVault(
            metadata: metadata,
            credentials: credentials,
            general: general
        )
        let created = try await fixture.vault.create(
            remoteDraft,
            credential: SensitiveCredentialInput("old")
        )
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await fixture.vault.setAutomaticApplications([appA, appB], for: created.id)
        do {
            _ = try await fixture.vault.update(
                created.id,
                draft: ProviderConfigurationDraft(
                    protocolKind: .openAICompatible,
                    endpoint: URL(string: "https://changed.invalid/v1")!,
                    model: "changed"
                ),
                credential: .replace(SensitiveCredentialInput("new"))
            )
            XCTFail("Expected hidden recovery state")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        var persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.state, .recoveryRequired)
        XCTAssertEqual(persisted.offDeviceAuthorizations[created.id], [appA, appB])

        await general.replace([appA])
        try await fixture.vault.reconcileAutomaticApplicationsWithGeneralAllowlist()
        persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.offDeviceAuthorizations[created.id], [appA])
        try await fixture.vault.reconcileStartup()
        persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.state, .active)
        XCTAssertEqual(persisted.offDeviceAuthorizations[created.id], [appA])
        let readable = try await fixture.vault.automaticApplications(for: created.id)
        XCTAssertEqual(readable, [appA])
    }
}

private let appA = ApplicationIdentity(
    bundleIdentifier: "invalid.example.app-a",
    displayName: "App A"
)
private let appB = ApplicationIdentity(
    bundleIdentifier: "invalid.example.app-b",
    displayName: "App B"
)
private let appC = ApplicationIdentity(
    bundleIdentifier: "invalid.example.app-c",
    displayName: "App C"
)
private let remoteDraft = ProviderConfigurationDraft(
    protocolKind: .openAICompatible,
    endpoint: URL(string: "https://example.invalid/v1")!,
    model: "model"
)
private let authorizationID = ProviderConfigurationID()

private func authorizationEnvelope() -> ProviderMetadataEnvelope {
    ProviderMetadataEnvelope(
        version: 1,
        records: [ProviderConfigurationRecord(
            id: authorizationID,
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://example.invalid/v1")!,
            model: "model",
            confirmedClass: .cloud,
            configurationRevision: 1,
            confirmationRevision: 1,
            activeCredentialAccount: nil,
            pendingCredentialAccount: nil,
            cleanupCredentialAccounts: [],
            state: .active
        )],
        offDeviceAuthorizations: [authorizationID: []]
    )
}

private struct AuthorizationVaultFixture {
    let vault: DefaultProviderVault
    let metadata: MemoryProviderMetadata
    let credentials: MemoryCredentialStore
}

private func makeAuthorizationVault(
    metadata: MemoryProviderMetadata = MemoryProviderMetadata(),
    credentials: MemoryCredentialStore = MemoryCredentialStore(),
    general: MutableGeneralApplications
) async throws -> AuthorizationVaultFixture {
    let vault = try await DefaultProviderVault.open(
        metadata: metadata,
        credentials: credentials,
        generalApplications: general
    )
    return AuthorizationVaultFixture(
        vault: vault,
        metadata: metadata,
        credentials: credentials
    )
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
