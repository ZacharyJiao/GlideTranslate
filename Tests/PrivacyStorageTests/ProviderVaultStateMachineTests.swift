import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

actor MemoryProviderMetadata: ProviderMetadataPersisting {
    private var stored: ProviderMetadataEnvelope
    private var failureCalls: Set<Int>
    private var calls = 0
    private var durabilityUncertainCalls: Set<Int>
    private var durabilityUncertainOldCalls: Set<Int>
    private var durabilityUncertainReloadFailureCalls: Set<Int>

    init(
        envelope: ProviderMetadataEnvelope = .empty,
        failureCalls: Set<Int> = [],
        durabilityUncertainCalls: Set<Int> = [],
        durabilityUncertainOldCalls: Set<Int> = [],
        durabilityUncertainReloadFailureCalls: Set<Int> = []
    ) {
        stored = envelope
        self.failureCalls = failureCalls
        self.durabilityUncertainCalls = durabilityUncertainCalls
        self.durabilityUncertainOldCalls = durabilityUncertainOldCalls
        self.durabilityUncertainReloadFailureCalls =
            durabilityUncertainReloadFailureCalls
    }

    func load() async throws -> ProviderMetadataEnvelope { stored }

    func install(_ envelope: ProviderMetadataEnvelope) async throws {
        calls += 1
        if failureCalls.contains(calls) {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        if durabilityUncertainReloadFailureCalls.contains(calls) {
            stored = envelope
            throw ProviderMetadataPersistenceFailure.durabilityUncertainReloadFailed
        }
        if durabilityUncertainOldCalls.contains(calls) {
            throw ProviderMetadataPersistenceFailure.durabilityUncertain(
                authoritative: stored
            )
        }
        stored = envelope
        if durabilityUncertainCalls.contains(calls) {
            throw ProviderMetadataPersistenceFailure.durabilityUncertain(
                authoritative: envelope
            )
        }
    }

    func snapshot() -> ProviderMetadataEnvelope { stored }
    func installCount() -> Int { calls }
    func replaceFailureCalls(_ calls: Set<Int>) { failureCalls = calls }
}

actor MemoryCredentialStore: ProviderCredentialStoring {
    private var accounts: [UUID: Data] = [:]
    private var addFailures: Set<Int>
    private var deleteFailures: Set<Int>
    private var addCount = 0
    private var deleteCount = 0
    private var readCount = 0

    init(
        accounts: Set<UUID> = [],
        addFailures: Set<Int> = [],
        deleteFailures: Set<Int> = []
    ) {
        self.accounts = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0, Data("credential".utf8)) }
        )
        self.addFailures = addFailures
        self.deleteFailures = deleteFailures
    }

    func add(
        _ credential: borrowing SensitiveCredentialInput,
        account: UUID
    ) async throws {
        addCount += 1
        if addFailures.contains(addCount) {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        accounts[account] = Data(credential.value.utf8)
    }

    func delete(account: UUID) async throws {
        deleteCount += 1
        if deleteFailures.contains(deleteCount) {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        accounts.removeValue(forKey: account)
    }

    func read(account: UUID) async throws -> Data {
        readCount += 1
        guard let value = accounts[account] else {
            throw SanitizedFailure.credentialStoreUnavailable
        }
        return value
    }

    func snapshot() -> Set<UUID> { Set(accounts.keys) }
    func deleteAttempts() -> Int { deleteCount }
    func readAttempts() -> Int { readCount }
}

final class ProviderVaultStateMachineTests: XCTestCase {
    func testDescriptorNeverContainsEndpointModelOrCredential() async throws {
        let fixture = try await makeVault()
        let descriptor = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("synthetic-secret")
        )
        let labels = Mirror(reflecting: descriptor).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["id", "protocolKind", "privacyClass", "hasCredential"])
        XCTAssertFalse(String(describing: descriptor).contains("example.invalid"))
        XCTAssertFalse(String(describing: descriptor).contains("synthetic-secret"))
    }

    func testNewSaveSuccessAndDefaultOllamaIdempotence() async throws {
        let fixture = try await makeVault()
        let descriptor = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("credential")
        )
        XCTAssertTrue(descriptor.hasCredential)
        let initialDescriptors = try await fixture.vault.descriptors()
        let initialAccounts = await fixture.credentials.snapshot()
        XCTAssertEqual(initialDescriptors.count, 1)
        XCTAssertEqual(initialAccounts.count, 1)

        let first = try await fixture.vault.ensureDefaultOllamaConfiguration()
        let second = try await fixture.vault.ensureDefaultOllamaConfiguration()
        XCTAssertEqual(first.id, second.id)
        let finalDescriptors = try await fixture.vault.descriptors()
        XCTAssertEqual(finalDescriptors.count, 2)
    }

    func testDefaultOllamaKeepsIdentityAfterModelUpdateAndConcurrentEnsure() async throws {
        let fixture = try await makeVault()
        let first = try await fixture.vault.ensureDefaultOllamaConfiguration()
        _ = try await fixture.vault.update(
            first.id,
            draft: ProviderConfigurationDraft(
                protocolKind: .ollamaNative,
                endpoint: URL(string: "http://127.0.0.1:11434")!,
                model: "selected-model"
            ),
            credential: .preserve
        )
        let ids = try await withThrowingTaskGroup(
            of: ProviderConfigurationID.self
        ) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await fixture.vault.ensureDefaultOllamaConfiguration().id
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(ids), [first.id])
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let afterReopen = try await reopened.ensureDefaultOllamaConfiguration()
        XCTAssertEqual(afterReopen.id, first.id)
    }

    func testDefaultRoleRejectsIdentityMutationAndPromotesExistingExactTuple() async throws {
        let fixture = try await makeVault()
        let existing = try await fixture.vault.create(
            ProviderConfigurationDraft(
                protocolKind: .ollamaNative,
                endpoint: URL(string: "http://127.0.0.1:11434")!,
                model: ""
            ),
            credential: nil
        )
        let promoted = try await fixture.vault.ensureDefaultOllamaConfiguration()
        XCTAssertEqual(promoted.id, existing.id)
        do {
            _ = try await fixture.vault.update(
                promoted.id,
                draft: syntheticDraft,
                credential: .preserve
            )
            XCTFail("Expected fixed default identity rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let count = try await descriptorCount(fixture.vault)
        XCTAssertEqual(count, 1)
    }

    func testConcurrentCreatesDoNotLoseRecordsAcrossReopen() async throws {
        let fixture = try await makeVault()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await fixture.vault.create(
                        ProviderConfigurationDraft(
                            protocolKind: .openAICompatible,
                            endpoint: URL(string: "https://\(index).example.invalid/v1")!,
                            model: "model-\(index)"
                        ),
                        credential: nil
                    )
                }
            }
            try await group.waitForAll()
        }
        let liveCount = try await descriptorCount(fixture.vault)
        XCTAssertEqual(liveCount, 20)
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let reopenedCount = try await descriptorCount(reopened)
        XCTAssertEqual(reopenedCount, 20)
    }

    func testNewCredentialFailureCompensatesToAbsent() async throws {
        let fixture = try await makeVault(
            credentials: MemoryCredentialStore(addFailures: [1])
        )
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected credential failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .credentialStoreUnavailable)
        }
        let descriptors = try await fixture.vault.descriptors()
        let persisted = await fixture.metadata.snapshot()
        let accounts = await fixture.credentials.snapshot()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertTrue(persisted.records.isEmpty)
        XCTAssertTrue(accounts.isEmpty)
    }

    func testActivationFailureNeverExposesPendingRecord() async throws {
        let metadata = MemoryProviderMetadata(failureCalls: [2])
        let fixture = try await makeVault(metadata: metadata)
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected activation failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let descriptors = try await fixture.vault.descriptors()
        let persisted = await fixture.metadata.snapshot()
        let accounts = await fixture.credentials.snapshot()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertTrue(persisted.records.isEmpty)
        XCTAssertTrue(accounts.isEmpty)
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let reopenedCount = try await descriptorCount(reopened)
        XCTAssertEqual(reopenedCount, 0)
    }

    func testActivationAndCredentialCleanupFailurePersistsHiddenRecoveryLedger() async throws {
        let metadata = MemoryProviderMetadata(failureCalls: [2])
        let credentials = MemoryCredentialStore(deleteFailures: [1])
        let fixture = try await makeVault(
            metadata: metadata,
            credentials: credentials
        )
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let descriptors = try await fixture.vault.descriptors()
        let persisted = await metadata.snapshot()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertEqual(persisted.records.only?.state, .recoveryRequired)
        XCTAssertNotNil(persisted.records.only?.pendingCredentialAccount)
        XCTAssertEqual(
            persisted.records.only?.recoveryAction,
            .removeRecordAfterCredentialCleanup
        )
        let id = try XCTUnwrap(persisted.records.only?.id)
        do {
            _ = try await fixture.vault.accessDescriptor(id)
            XCTFail("Recovery record must be unavailable")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let reopened = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials
        )
        let reopenedCount = try await descriptorCount(reopened)
        XCTAssertEqual(reopenedCount, 0)
    }

    func testUpdatePreserveReplaceRemoveAndRevision() async throws {
        let fixture = try await makeVault()
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )
        var persisted = await fixture.metadata.snapshot()
        let oldAccount = try XCTUnwrap(
            persisted.records.only?.activeCredentialAccount
        )

        _ = try await fixture.vault.update(
            created.id,
            draft: ProviderConfigurationDraft(
                protocolKind: .openAICompatible,
                endpoint: URL(string: "https://other.invalid/v1")!,
                model: "model-two"
            ),
            credential: .preserve
        )
        persisted = await fixture.metadata.snapshot()
        var record = try XCTUnwrap(persisted.records.only)
        XCTAssertEqual(record.configurationRevision, 2)
        XCTAssertEqual(record.activeCredentialAccount, oldAccount)

        _ = try await fixture.vault.update(
            created.id,
            draft: syntheticDraft,
            credential: .replace(SensitiveCredentialInput("new"))
        )
        persisted = await fixture.metadata.snapshot()
        record = try XCTUnwrap(persisted.records.only)
        XCTAssertEqual(record.configurationRevision, 3)
        XCTAssertNotEqual(record.activeCredentialAccount, oldAccount)
        var accounts = await fixture.credentials.snapshot()
        XCTAssertFalse(accounts.contains(oldAccount))

        _ = try await fixture.vault.update(
            created.id,
            draft: syntheticDraft,
            credential: .remove
        )
        persisted = await fixture.metadata.snapshot()
        record = try XCTUnwrap(persisted.records.only)
        XCTAssertEqual(record.configurationRevision, 4)
        XCTAssertNil(record.activeCredentialAccount)
        accounts = await fixture.credentials.snapshot()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testUpdateAtMaximumConfigurationRevisionFailsWithoutWriting() async throws {
        let id = ProviderConfigurationID()
        let record = ProviderConfigurationRecord(
            id: id,
            protocolKind: .openAICompatible,
            endpoint: syntheticDraft.endpoint,
            model: syntheticDraft.model,
            confirmedClass: .cloud,
            configurationRevision: UInt64.max,
            confirmationRevision: 1,
            activeCredentialAccount: nil,
            pendingCredentialAccount: nil,
            cleanupCredentialAccounts: [],
            state: .active
        )
        let metadata = MemoryProviderMetadata(envelope: ProviderMetadataEnvelope(
            version: ProviderMetadataEnvelope.currentVersion,
            records: [record],
            offDeviceAuthorizations: [:]
        ))
        let fixture = try await makeVault(metadata: metadata)

        do {
            _ = try await fixture.vault.update(
                id,
                draft: ProviderConfigurationDraft(
                    protocolKind: .openAICompatible,
                    endpoint: URL(string: "https://changed.invalid/v1")!,
                    model: "changed-model"
                ),
                credential: .preserve
            )
            XCTFail("Expected maximum revision rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }

        let installCount = await metadata.installCount()
        let envelope = await metadata.snapshot()
        XCTAssertEqual(installCount, 0)
        let persisted = try XCTUnwrap(envelope.records.only)
        XCTAssertEqual(persisted.configurationRevision, UInt64.max)
        XCTAssertEqual(persisted.endpoint, syntheticDraft.endpoint)
        XCTAssertEqual(persisted.model, syntheticDraft.model)
    }

    func testFailedReplacementCleanupRetainsAccountUntilStartupDeletesIt() async throws {
        let metadata = MemoryProviderMetadata(failureCalls: [4])
        let credentials = MemoryCredentialStore(deleteFailures: [1])
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )
        do {
            _ = try await fixture.vault.update(
                created.id,
                draft: syntheticDraft,
                credential: .replace(SensitiveCredentialInput("new"))
            )
            XCTFail("Expected failed commit compensation")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        var persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.state, .active)
        XCTAssertEqual(persisted.records.only?.cleanupCredentialAccounts.count, 1)
        var accounts = await credentials.snapshot()
        XCTAssertEqual(accounts.count, 2)

        _ = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials
        )
        persisted = await metadata.snapshot()
        XCTAssertTrue(persisted.records.only?.cleanupCredentialAccounts.isEmpty == true)
        accounts = await credentials.snapshot()
        XCTAssertEqual(accounts.count, 1)
    }

    func testExplicitRecoveryActionRestoresRevisionOneCredentiallessUpdate() async throws {
        let pendingAccount = UUID()
        var record = ProviderConfigurationRecord.synthetic(
            id: ProviderConfigurationID(),
            state: .recoveryRequired
        )
        record.pendingUpdate = ProviderPendingUpdate(
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://new.invalid/v1")!,
            model: "new",
            pendingCredentialAccount: pendingAccount,
            removesCredential: false
        )
        record.recoveryAction = .restoreActiveAfterCredentialCleanup
        let metadata = MemoryProviderMetadata(envelope: ProviderMetadataEnvelope(
            version: 1,
            records: [record],
            offDeviceAuthorizations: [record.id: []]
        ))
        let credentials = MemoryCredentialStore()
        let reopened = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials
        )
        let descriptors = try await reopened.descriptors()
        XCTAssertEqual(descriptors.only?.id, record.id)
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.state, .active)
        XCTAssertNil(persisted.records.only?.pendingUpdate)
    }

    func testDurabilityUncertainPublishesAuthoritativeDiskEnvelope() async throws {
        let metadata = MemoryProviderMetadata(durabilityUncertainCalls: [1])
        let fixture = try await makeVault(metadata: metadata)
        do {
            _ = try await fixture.vault.create(syntheticDraft, credential: nil)
            XCTFail("Expected durability-uncertain create")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        _ = try await fixture.vault.ensureDefaultOllamaConfiguration()
        var persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.count, 2)
        XCTAssertEqual(persisted.records.filter { $0.state == .active }.count, 1)
        try await fixture.vault.reconcileStartup()
        persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.count, 1)
    }

    func testActivationDurabilityUncertaintyHidesAuthoritativeActiveOnCleanupFailure() async throws {
        let metadata = MemoryProviderMetadata(durabilityUncertainCalls: [2])
        let credentials = MemoryCredentialStore(deleteFailures: [1])
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected recovery-required result")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let descriptors = try await fixture.vault.descriptors()
        let persisted = await metadata.snapshot()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertEqual(persisted.records.only?.state, .recoveryRequired)
        XCTAssertEqual(
            persisted.records.only?.recoveryAction,
            .removeRecordAfterCredentialCleanup
        )
        XCTAssertNotNil(persisted.records.only?.activeCredentialAccount)
    }

    func testUpdateCommitDurabilityUncertaintyKeepsCommittedCredentialPair() async throws {
        let metadata = MemoryProviderMetadata(durabilityUncertainCalls: [4])
        let credentials = MemoryCredentialStore(deleteFailures: [1])
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )
        do {
            _ = try await fixture.vault.update(
                created.id,
                draft: ProviderConfigurationDraft(
                    protocolKind: .openAICompatible,
                    endpoint: URL(string: "https://new.invalid/v1")!,
                    model: "new"
                ),
                credential: .replace(SensitiveCredentialInput("new"))
            )
            XCTFail("Expected durability uncertainty")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.configurationRevision, 2)
        XCTAssertEqual(persisted.records.only?.model, "new")
        XCTAssertNotNil(persisted.records.only?.activeCredentialAccount)
        XCTAssertEqual(persisted.records.only?.cleanupCredentialAccounts.count, 1)
        let accountCount = await credentialCount(credentials)
        XCTAssertEqual(accountCount, 2)
    }

    func testUpdateRecoveryMarkerFailurePoisonsUntilReopenRepairsPreparedState() async throws {
        let metadata = MemoryProviderMetadata(failureCalls: [4, 5, 6])
        let credentials = MemoryCredentialStore()
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )

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
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        await assertVaultIsPoisoned(fixture.vault, id: created.id)

        let reopened = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials
        )
        let access = try await reopened.accessDescriptor(created.id)
        XCTAssertEqual(access.model, syntheticDraft.model)
        XCTAssertEqual(access.configurationRevision, 1)
        let accountCount = await credentials.snapshot().count
        XCTAssertEqual(accountCount, 1)
    }

    func testDurabilityUncertaintyWithoutAuthoritativeReloadPoisonsVault() async throws {
        let metadata = MemoryProviderMetadata(
            durabilityUncertainReloadFailureCalls: [1]
        )
        let fixture = try await makeVault(metadata: metadata)
        do {
            _ = try await fixture.vault.create(syntheticDraft, credential: nil)
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        await assertVaultIsPoisoned(fixture.vault, id: ProviderConfigurationID())
    }

    func testActivationReloadFailureStopsCurrentOperationWithoutCompensation() async throws {
        let metadata = MemoryProviderMetadata(
            durabilityUncertainReloadFailureCalls: [2]
        )
        let credentials = MemoryCredentialStore()
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let installCount = await metadata.installCount()
        let deleteAttempts = await credentials.deleteAttempts()
        let accounts = await credentials.snapshot()
        let persisted = await metadata.snapshot()
        XCTAssertEqual(installCount, 2)
        XCTAssertEqual(deleteAttempts, 0)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(persisted.records.only?.state, .active)
        await assertVaultIsPoisoned(
            fixture.vault,
            id: try XCTUnwrap(persisted.records.only?.id)
        )
    }

    func testCredentialAddCompensationReloadFailureDoesNotResurrectRecord() async throws {
        let metadata = MemoryProviderMetadata(
            durabilityUncertainReloadFailureCalls: [2]
        )
        let credentials = MemoryCredentialStore(addFailures: [1])
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let installCount = await metadata.installCount()
        let accounts = await credentials.snapshot()
        let persisted = await metadata.snapshot()
        XCTAssertEqual(installCount, 2)
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(persisted.records.isEmpty)
        await assertVaultIsPoisoned(fixture.vault, id: ProviderConfigurationID())
    }

    func testActivationCleanupReloadFailureDoesNotResurrectRecord() async throws {
        let metadata = MemoryProviderMetadata(
            failureCalls: [2],
            durabilityUncertainReloadFailureCalls: [4]
        )
        let credentials = MemoryCredentialStore()
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let installCount = await metadata.installCount()
        let deleteAttempts = await credentials.deleteAttempts()
        let accounts = await credentials.snapshot()
        let persisted = await metadata.snapshot()
        XCTAssertEqual(installCount, 4)
        XCTAssertEqual(deleteAttempts, 1)
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(persisted.records.isEmpty)
        await assertVaultIsPoisoned(fixture.vault, id: ProviderConfigurationID())
    }

    func testUpdateCommitReloadFailureStopsCurrentOperationWithoutCompensation() async throws {
        let metadata = MemoryProviderMetadata(
            durabilityUncertainReloadFailureCalls: [4]
        )
        let credentials = MemoryCredentialStore()
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )
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
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let installCount = await metadata.installCount()
        let deleteAttempts = await credentials.deleteAttempts()
        let accounts = await credentials.snapshot()
        XCTAssertEqual(installCount, 4)
        XCTAssertEqual(deleteAttempts, 0)
        XCTAssertEqual(accounts.count, 2)
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.configurationRevision, 2)
        XCTAssertNil(persisted.records.only?.pendingUpdate)
        await assertVaultIsPoisoned(fixture.vault, id: created.id)
    }

    func testPostCommitRetirementReloadFailureSurfacesRecoveryRequired() async throws {
        let metadata = MemoryProviderMetadata(
            durabilityUncertainCalls: [4],
            durabilityUncertainReloadFailureCalls: [5]
        )
        let credentials = MemoryCredentialStore()
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )
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
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let installCount = await metadata.installCount()
        let deleteAttempts = await credentials.deleteAttempts()
        let accounts = await credentials.snapshot()
        let persisted = await metadata.snapshot()
        XCTAssertEqual(installCount, 5)
        XCTAssertEqual(deleteAttempts, 1)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(persisted.records.only?.configurationRevision, 2)
        XCTAssertTrue(persisted.records.only?.cleanupCredentialAccounts.isEmpty == true)
        await assertVaultIsPoisoned(fixture.vault, id: created.id)
    }

    func testUpdateCredentialAddFailureRestoresOldTupleAndReopens() async throws {
        let credentials = MemoryCredentialStore(addFailures: [2])
        let fixture = try await makeVault(credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )
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
            XCTFail("Expected credential-store failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .credentialStoreUnavailable)
        }
        try await assertOldActiveTuple(
            metadata: fixture.metadata,
            credentials: credentials,
            id: created.id
        )
    }

    func testUpdateCommitFailureWithSuccessfulPendingCleanupRestoresOldTuple() async throws {
        let metadata = MemoryProviderMetadata(failureCalls: [4])
        let credentials = MemoryCredentialStore()
        let fixture = try await makeVault(metadata: metadata, credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("old")
        )
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
            XCTFail("Expected commit failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        try await assertOldActiveTuple(
            metadata: metadata,
            credentials: credentials,
            id: created.id
        )
    }

    func testSuccessfulDeleteRemovesRecordCredentialAndAuthorizationAcrossReopen() async throws {
        let application = ApplicationIdentity(
            bundleIdentifier: "invalid.example.fixture",
            displayName: "Fixture"
        )
        let fixture = try await makeVault(
            generalApplications: MutableGeneralApplications([application])
        )
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("credential")
        )
        _ = try await fixture.vault.commitConfirmation(
            id: created.id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        try await fixture.vault.setAutomaticApplications([application], for: created.id)
        try await fixture.vault.delete(created.id)

        let persisted = await fixture.metadata.snapshot()
        XCTAssertTrue(persisted.records.isEmpty)
        XCTAssertNil(persisted.offDeviceAuthorizations[created.id])
        let accounts = await fixture.credentials.snapshot()
        XCTAssertTrue(accounts.isEmpty)
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let reopenedDescriptors = try await reopened.descriptors()
        XCTAssertTrue(reopenedDescriptors.isEmpty)
        do {
            _ = try await reopened.accessDescriptor(created.id)
            XCTFail("Deleted configuration must remain unavailable")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
    }

    func testNewPendingMetadataFailureLeavesAbsentStateAcrossReopen() async throws {
        let metadata = MemoryProviderMetadata(failureCalls: [1])
        let fixture = try await makeVault(metadata: metadata)
        do {
            _ = try await fixture.vault.create(syntheticDraft, credential: nil)
            XCTFail("Expected pending metadata failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let persisted = await metadata.snapshot()
        XCTAssertTrue(persisted.records.isEmpty)
        let visibleCount = try await descriptorCount(fixture.vault)
        XCTAssertEqual(visibleCount, 0)
        let reopened = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: fixture.credentials
        )
        let reopenedCount = try await descriptorCount(reopened)
        XCTAssertEqual(reopenedCount, 0)
    }

    func testNewCredentialAndMetadataCleanupFailurePersistsHiddenRecovery() async throws {
        let fixture = try await makeVault(
            metadata: MemoryProviderMetadata(failureCalls: [2]),
            credentials: MemoryCredentialStore(addFailures: [1])
        )
        do {
            _ = try await fixture.vault.create(
                syntheticDraft,
                credential: SensitiveCredentialInput("credential")
            )
            XCTFail("Expected recovery")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let persisted = await fixture.metadata.snapshot()
        let visibleCount = try await descriptorCount(fixture.vault)
        XCTAssertEqual(visibleCount, 0)
        XCTAssertEqual(persisted.records.only?.state, .recoveryRequired)
        XCTAssertEqual(
            persisted.records.only?.recoveryAction,
            .removeRecordAfterCredentialCleanup
        )
        let accounts = await fixture.credentials.snapshot()
        XCTAssertTrue(accounts.isEmpty)
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let reopenedCount = try await descriptorCount(reopened)
        XCTAssertEqual(reopenedCount, 0)
    }

    func testUpdatePendingMetadataFailurePreservesOldPairAcrossReopen() async throws {
        let fixture = try await makeVault(
            metadata: MemoryProviderMetadata(failureCalls: [3])
        )
        let created = try await fixture.vault.create(syntheticDraft, credential: nil)
        do {
            _ = try await fixture.vault.update(
                created.id,
                draft: ProviderConfigurationDraft(
                    protocolKind: .openAICompatible,
                    endpoint: URL(string: "https://changed.invalid/v1")!,
                    model: "changed"
                ),
                credential: .preserve
            )
            XCTFail("Expected prepare failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let access = try await fixture.vault.accessDescriptor(created.id)
        XCTAssertEqual(access.model, syntheticDraft.model)
        XCTAssertEqual(access.configurationRevision, 1)
        let persisted = await fixture.metadata.snapshot()
        XCTAssertNil(persisted.records.only?.pendingUpdate)
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let reopenedAccess = try await reopened.accessDescriptor(created.id)
        XCTAssertEqual(reopenedAccess.configurationRevision, 1)
    }

    func testDeleteTombstoneFailureLeavesOldPairVisibleAcrossReopen() async throws {
        let fixture = try await makeVault(
            metadata: MemoryProviderMetadata(failureCalls: [3])
        )
        let id = try await fixture.vault.create(syntheticDraft, credential: nil).id
        do {
            try await fixture.vault.delete(id)
            XCTFail("Expected tombstone failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let access = try await fixture.vault.accessDescriptor(id)
        XCTAssertEqual(access.configurationRevision, 1)
        let persisted = await fixture.metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.state, .active)
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        _ = try await reopened.accessDescriptor(id)
    }

    func testDeleteMetadataRemovalFailureStaysHiddenUntilReopenRepairs() async throws {
        let fixture = try await makeVault(
            metadata: MemoryProviderMetadata(failureCalls: [4])
        )
        let id = try await fixture.vault.create(syntheticDraft, credential: nil).id
        do {
            try await fixture.vault.delete(id)
            XCTFail("Expected metadata removal failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let persisted = await fixture.metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.state, .deletionPending)
        do {
            _ = try await fixture.vault.accessDescriptor(id)
            XCTFail("Tombstone must be inaccessible")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let reopenedCount = try await descriptorCount(reopened)
        XCTAssertEqual(reopenedCount, 0)
        let afterReopen = await fixture.metadata.snapshot()
        XCTAssertTrue(afterReopen.records.isEmpty)
    }

    func testDeleteTombstoneHidesBeforeCredentialCleanup() async throws {
        let credentials = MemoryCredentialStore(deleteFailures: [1])
        let fixture = try await makeVault(credentials: credentials)
        let created = try await fixture.vault.create(
            syntheticDraft,
            credential: SensitiveCredentialInput("credential")
        )
        do {
            try await fixture.vault.delete(created.id)
            XCTFail("Expected partial delete failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .credentialStoreUnavailable)
        }
        let descriptors = try await fixture.vault.descriptors()
        let persisted = await fixture.metadata.snapshot()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertEqual(persisted.records.only?.state, .deletionPending)
        do {
            _ = try await fixture.vault.accessDescriptor(created.id)
            XCTFail("Deletion tombstone must be unavailable")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let reopened = try await DefaultProviderVault.open(
            metadata: fixture.metadata,
            credentials: fixture.credentials
        )
        let reopenedCount = try await descriptorCount(reopened)
        XCTAssertEqual(reopenedCount, 0)
        let afterReopen = await fixture.metadata.snapshot()
        XCTAssertTrue(afterReopen.records.isEmpty)
    }

    func testStartupReconciliationIsIdempotent() async throws {
        let pendingID = ProviderConfigurationID()
        let deletingID = ProviderConfigurationID()
        let pendingAccount = UUID()
        let envelope = ProviderMetadataEnvelope(
            version: 1,
            records: [
                ProviderConfigurationRecord.synthetic(
                    id: pendingID,
                    state: .pendingCredentialWrite,
                    pendingCredentialAccount: pendingAccount
                ),
                ProviderConfigurationRecord.synthetic(
                    id: deletingID,
                    state: .deletionPending
                )
            ],
            offDeviceAuthorizations: [:]
        )
        let metadata = MemoryProviderMetadata(envelope: envelope)
        let credentials = MemoryCredentialStore()
        let vault = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials
        )
        let descriptors = try await vault.descriptors()
        var persisted = await metadata.snapshot()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertTrue(persisted.records.isEmpty)
        try await vault.reconcileStartup()
        persisted = await metadata.snapshot()
        XCTAssertTrue(persisted.records.isEmpty)
    }

    func testStartupDrainsCleanupThenRestoresFromLatestRecord() async throws {
        let cleanup = UUID()
        let pending = UUID()
        var record = ProviderConfigurationRecord.synthetic(
            id: ProviderConfigurationID(),
            state: .active
        )
        record.cleanupCredentialAccounts = [cleanup]
        record.pendingUpdate = ProviderPendingUpdate(
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://pending.invalid/v1")!,
            model: "pending",
            pendingCredentialAccount: pending,
            removesCredential: false
        )
        let metadata = MemoryProviderMetadata(envelope: ProviderMetadataEnvelope(
            version: 1,
            records: [record],
            offDeviceAuthorizations: [record.id: []]
        ))
        let credentials = MemoryCredentialStore(accounts: [cleanup, pending])
        _ = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials
        )
        var persisted = await metadata.snapshot()
        XCTAssertTrue(persisted.records.only?.cleanupCredentialAccounts.isEmpty == true)
        XCTAssertNil(persisted.records.only?.pendingUpdate)
        let accounts = await credentials.snapshot()
        XCTAssertTrue(accounts.isEmpty)
        _ = try await DefaultProviderVault.open(
            metadata: metadata,
            credentials: credentials
        )
        persisted = await metadata.snapshot()
        XCTAssertTrue(persisted.records.only?.cleanupCredentialAccounts.isEmpty == true)
    }

    func testManualRecoveryDoesNotStarveIndependentPendingUpdateRepair() async throws {
        var manual = ProviderConfigurationRecord.synthetic(
            id: ProviderConfigurationID(),
            state: .recoveryRequired
        )
        manual.recoveryAction = .manual
        let pendingAccount = UUID()
        var repairable = ProviderConfigurationRecord.synthetic(
            id: ProviderConfigurationID(),
            state: .active
        )
        repairable.pendingUpdate = ProviderPendingUpdate(
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://pending.invalid/v1")!,
            model: "pending",
            pendingCredentialAccount: pendingAccount,
            removesCredential: false
        )
        let metadata = MemoryProviderMetadata(envelope: ProviderMetadataEnvelope(
            version: 1,
            records: [manual, repairable],
            offDeviceAuthorizations: [manual.id: [], repairable.id: []]
        ))
        let credentials = MemoryCredentialStore(accounts: [pendingAccount])
        do {
            _ = try await DefaultProviderVault.open(
                metadata: metadata,
                credentials: credentials
            )
            XCTFail("Expected remaining manual recovery")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let persisted = await metadata.snapshot()
        let repaired = try XCTUnwrap(
            persisted.records.first(where: { $0.id == repairable.id })
        )
        XCTAssertEqual(repaired.state, .active)
        XCTAssertNil(repaired.pendingUpdate)
        let remainingAccounts = await credentials.snapshot()
        XCTAssertTrue(remainingAccounts.isEmpty)
        do {
            _ = try await DefaultProviderVault.open(
                metadata: metadata,
                credentials: credentials
            )
            XCTFail("Manual recovery must remain reported on second reconciliation")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
    }

    func testReconciliationReloadFailureStopsBeforeNextRecordEffect() async throws {
        let cleanupAccount = UUID()
        let nextPendingAccount = UUID()
        var first = ProviderConfigurationRecord.synthetic(
            id: ProviderConfigurationID(),
            state: .active
        )
        first.cleanupCredentialAccounts = [cleanupAccount]
        let second = ProviderConfigurationRecord.synthetic(
            id: ProviderConfigurationID(),
            state: .pendingCredentialWrite,
            pendingCredentialAccount: nextPendingAccount
        )
        let metadata = MemoryProviderMetadata(
            envelope: ProviderMetadataEnvelope(
                version: 1,
                records: [first, second],
                offDeviceAuthorizations: [first.id: [], second.id: []]
            ),
            durabilityUncertainReloadFailureCalls: [1]
        )
        let credentials = MemoryCredentialStore(
            accounts: [cleanupAccount, nextPendingAccount]
        )
        do {
            _ = try await DefaultProviderVault.open(
                metadata: metadata,
                credentials: credentials
            )
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let persisted = await metadata.snapshot()
        let accounts = await credentials.snapshot()
        let installCount = await metadata.installCount()
        XCTAssertEqual(installCount, 1)
        XCTAssertFalse(accounts.contains(cleanupAccount))
        XCTAssertTrue(accounts.contains(nextPendingAccount))
        XCTAssertEqual(persisted.records.count, 2)
        XCTAssertTrue(
            persisted.records.first(where: { $0.id == first.id })?
                .cleanupCredentialAccounts.isEmpty == true
        )
        XCTAssertEqual(
            persisted.records.first(where: { $0.id == second.id })?.state,
            .pendingCredentialWrite
        )
    }
}

private let syntheticDraft = ProviderConfigurationDraft(
    protocolKind: .openAICompatible,
    endpoint: URL(string: "https://example.invalid/v1")!,
    model: "synthetic-model"
)

private struct VaultFixture {
    let vault: DefaultProviderVault
    let metadata: MemoryProviderMetadata
    let credentials: MemoryCredentialStore
}

private func makeVault(
    metadata: MemoryProviderMetadata = MemoryProviderMetadata(),
    credentials: MemoryCredentialStore = MemoryCredentialStore(),
    generalApplications: any GeneralAutomaticApplicationReading =
        EmptyGeneralAutomaticApplicationReader()
) async throws -> VaultFixture {
    let vault = try await DefaultProviderVault.open(
        metadata: metadata,
        credentials: credentials,
        generalApplications: generalApplications
    )
    return VaultFixture(vault: vault, metadata: metadata, credentials: credentials)
}

private func descriptorCount(_ vault: DefaultProviderVault) async throws -> Int {
    try await vault.descriptors().count
}

private func credentialCount(_ store: MemoryCredentialStore) async -> Int {
    await store.snapshot().count
}

private func assertVaultIsPoisoned(
    _ vault: DefaultProviderVault,
    id: ProviderConfigurationID
) async {
    do {
        _ = try await vault.descriptors()
        XCTFail("Poisoned vault must reject descriptors")
    } catch {
        XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
    }
    do {
        _ = try await vault.accessDescriptor(id)
        XCTFail("Poisoned vault must reject package access")
    } catch {
        XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
    }
}

private func assertOldActiveTuple(
    metadata: MemoryProviderMetadata,
    credentials: MemoryCredentialStore,
    id: ProviderConfigurationID
) async throws {
    let persisted = await metadata.snapshot()
    let record = try XCTUnwrap(persisted.records.only)
    XCTAssertEqual(record.state, .active)
    XCTAssertNil(record.pendingUpdate)
    XCTAssertEqual(record.model, syntheticDraft.model)
    XCTAssertEqual(record.configurationRevision, 1)
    let accountCount = await credentials.snapshot().count
    XCTAssertEqual(accountCount, 1)
    let reopened = try await DefaultProviderVault.open(
        metadata: metadata,
        credentials: credentials
    )
    let access = try await reopened.accessDescriptor(id)
    XCTAssertEqual(access.model, syntheticDraft.model)
    XCTAssertEqual(access.configurationRevision, 1)
}

private func assertCreateFailsHiddenOrAbsent(_ fixture: VaultFixture) async {
    do {
        _ = try await fixture.vault.create(syntheticDraft, credential: nil)
        XCTFail("Expected create failure")
    } catch {}
    do {
        let descriptors = try await fixture.vault.descriptors()
        XCTAssertTrue(descriptors.isEmpty)
    } catch {
        XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private extension ProviderConfigurationRecord {
    static func synthetic(
        id: ProviderConfigurationID,
        state: ProviderRecordState,
        pendingCredentialAccount: UUID? = nil
    ) -> Self {
        Self(
            id: id,
            protocolKind: .ollamaNative,
            endpoint: URL(string: "http://127.0.0.1:11434")!,
            model: "",
            confirmedClass: nil,
            configurationRevision: 1,
            confirmationRevision: 0,
            activeCredentialAccount: nil,
            pendingCredentialAccount: pendingCredentialAccount,
            cleanupCredentialAccounts: [],
            state: state,
            recoveryAction: state == .recoveryRequired ? .manual : nil
        )
    }
}
