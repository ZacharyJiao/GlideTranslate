import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class ProviderConfirmationCommitTests: XCTestCase {
    func testExactConfirmationCommitIncrementsRevisionAndClearsAuthorization() async throws {
        let fixture = try await makeConfirmedVault()
        let commit = try await fixture.vault.commitConfirmation(
            id: fixture.id,
            expectedConfigurationRevision: 7,
            expectedConfirmationRevision: 3,
            proposedClass: .localNetwork
        )
        XCTAssertEqual(commit.configurationRevision, 7)
        XCTAssertEqual(commit.confirmationRevision, 4)
        let persisted = await fixture.metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.confirmedClass, .localNetwork)
        XCTAssertEqual(persisted.records.only?.confirmationRevision, 4)
        XCTAssertTrue(persisted.offDeviceAuthorizations[fixture.id]?.isEmpty == true)
    }

    func testRevisionDriftMakesNoMetadataWrite() async throws {
        for (configuration, confirmation) in [(8, 3), (7, 4)] {
            let fixture = try await makeConfirmedVault()
            let beforeCalls = await fixture.metadata.installCount()
            do {
                _ = try await fixture.vault.commitConfirmation(
                    id: fixture.id,
                    expectedConfigurationRevision: UInt64(configuration),
                    expectedConfirmationRevision: UInt64(confirmation),
                    proposedClass: .cloud
                )
                XCTFail("Expected revision rejection")
            } catch {
                XCTAssertEqual(
                    error as? SanitizedFailure,
                    .destinationReconfirmationRequired
                )
            }
            let afterCalls = await fixture.metadata.installCount()
            XCTAssertEqual(afterCalls, beforeCalls)
        }
    }

    func testAtomicCommitFailurePreservesPriorClassRevisionAndAuthorization() async throws {
        let metadata = MemoryProviderMetadata(
            envelope: confirmedEnvelope(),
            failureCalls: [1]
        )
        let fixture = try await makeConfirmedVault(metadata: metadata)
        do {
            _ = try await fixture.vault.commitConfirmation(
                id: fixture.id,
                expectedConfigurationRevision: 7,
                expectedConfirmationRevision: 3,
                proposedClass: .localNetwork
            )
            XCTFail("Expected metadata failure")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.confirmedClass, .cloud)
        XCTAssertEqual(persisted.records.only?.confirmationRevision, 3)
        XCTAssertEqual(persisted.offDeviceAuthorizations[fixture.id], [confirmationApp])
    }

    func testInvalidProposedClassMakesNoWrite() async throws {
        for proposed in [DestinationPrivacyClass.localOnDevice, .unresolvedOrChanged] {
            let fixture = try await makeConfirmedVault()
            let before = await fixture.metadata.installCount()
            do {
                _ = try await fixture.vault.commitConfirmation(
                    id: fixture.id,
                    expectedConfigurationRevision: 7,
                    expectedConfirmationRevision: 3,
                    proposedClass: proposed
                )
                XCTFail("Expected proposed-class rejection")
            } catch {
                XCTAssertEqual(
                    error as? SanitizedFailure,
                    .destinationReconfirmationRequired
                )
            }
            let after = await fixture.metadata.installCount()
            XCTAssertEqual(after, before)
        }
    }

    func testMaximumConfirmationRevisionMakesNoWrite() async throws {
        let metadata = MemoryProviderMetadata(
            envelope: confirmedEnvelope(confirmationRevision: UInt64.max)
        )
        let fixture = try await makeConfirmedVault(metadata: metadata)
        do {
            _ = try await fixture.vault.commitConfirmation(
                id: fixture.id,
                expectedConfigurationRevision: 7,
                expectedConfirmationRevision: UInt64.max,
                proposedClass: .cloud
            )
            XCTFail("Expected overflow rejection")
        } catch {
            XCTAssertEqual(
                error as? SanitizedFailure,
                .destinationReconfirmationRequired
            )
        }
        let installCount = await metadata.installCount()
        XCTAssertEqual(installCount, 0)
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.confirmationRevision, UInt64.max)
        XCTAssertEqual(persisted.offDeviceAuthorizations[fixture.id], [confirmationApp])
    }

    func testDurabilityUncertainAuthoritativeOldKeepsOldTuple() async throws {
        let metadata = MemoryProviderMetadata(
            envelope: confirmedEnvelope(),
            durabilityUncertainOldCalls: [1]
        )
        let fixture = try await makeConfirmedVault(metadata: metadata)
        do {
            _ = try await fixture.vault.commitConfirmation(
                id: fixture.id,
                expectedConfigurationRevision: 7,
                expectedConfirmationRevision: 3,
                proposedClass: .localNetwork
            )
            XCTFail("Expected durability result")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        assertOldConfirmationTuple(await metadata.snapshot(), id: fixture.id)
    }

    func testDurabilityUncertainAuthoritativeNewKeepsNewTuple() async throws {
        let metadata = MemoryProviderMetadata(
            envelope: confirmedEnvelope(),
            durabilityUncertainCalls: [1]
        )
        let fixture = try await makeConfirmedVault(metadata: metadata)
        do {
            _ = try await fixture.vault.commitConfirmation(
                id: fixture.id,
                expectedConfigurationRevision: 7,
                expectedConfirmationRevision: 3,
                proposedClass: .localNetwork
            )
            XCTFail("Expected durability result")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.confirmedClass, .localNetwork)
        XCTAssertEqual(persisted.records.only?.confirmationRevision, 4)
        XCTAssertTrue(persisted.offDeviceAuthorizations[fixture.id]?.isEmpty == true)
    }

    func testDurabilityUncertainReloadFailurePoisonsWithUnmixedNewTuple() async throws {
        let metadata = MemoryProviderMetadata(
            envelope: confirmedEnvelope(),
            durabilityUncertainReloadFailureCalls: [1]
        )
        let fixture = try await makeConfirmedVault(metadata: metadata)
        do {
            _ = try await fixture.vault.commitConfirmation(
                id: fixture.id,
                expectedConfigurationRevision: 7,
                expectedConfirmationRevision: 3,
                proposedClass: .localNetwork
            )
            XCTFail("Expected recovery-required result")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
        let persisted = await metadata.snapshot()
        XCTAssertEqual(persisted.records.only?.confirmedClass, .localNetwork)
        XCTAssertEqual(persisted.records.only?.confirmationRevision, 4)
        XCTAssertTrue(persisted.offDeviceAuthorizations[fixture.id]?.isEmpty == true)
        do {
            _ = try await fixture.vault.descriptors()
            XCTFail("Poisoned vault must fail closed")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerRecoveryRequired)
        }
    }
}

private let confirmationID = ProviderConfigurationID()
private let confirmationApp = ApplicationIdentity(
    bundleIdentifier: "invalid.example.confirmation",
    displayName: "Confirmation"
)

private func confirmedEnvelope(
    confirmationRevision: UInt64 = 3
) -> ProviderMetadataEnvelope {
    ProviderMetadataEnvelope(
        version: 1,
        records: [ProviderConfigurationRecord(
            id: confirmationID,
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://example.invalid/v1")!,
            model: "model",
            confirmedClass: .cloud,
            configurationRevision: 7,
            confirmationRevision: confirmationRevision,
            activeCredentialAccount: nil,
            pendingCredentialAccount: nil,
            cleanupCredentialAccounts: [],
            state: .active
        )],
        offDeviceAuthorizations: [confirmationID: [confirmationApp]]
    )
}

private func assertOldConfirmationTuple(
    _ envelope: ProviderMetadataEnvelope,
    id: ProviderConfigurationID,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(envelope.records.only?.confirmedClass, .cloud, file: file, line: line)
    XCTAssertEqual(envelope.records.only?.confirmationRevision, 3, file: file, line: line)
    XCTAssertEqual(
        envelope.offDeviceAuthorizations[id],
        [confirmationApp],
        file: file,
        line: line
    )
}

private struct ConfirmedVaultFixture {
    let vault: DefaultProviderVault
    let metadata: MemoryProviderMetadata
    let id: ProviderConfigurationID
}

private func makeConfirmedVault(
    metadata: MemoryProviderMetadata = MemoryProviderMetadata(
        envelope: confirmedEnvelope()
    )
) async throws -> ConfirmedVaultFixture {
    let vault = try await DefaultProviderVault.open(
        metadata: metadata,
        credentials: MemoryCredentialStore(),
        generalApplications: MutableGeneralApplications([confirmationApp])
    )
    return ConfirmedVaultFixture(
        vault: vault,
        metadata: metadata,
        id: confirmationID
    )
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
