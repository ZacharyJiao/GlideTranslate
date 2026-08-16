import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

private struct HandleFacetSpy: ProviderAccess, ProviderConfirmationCommitting {
    func accessDescriptor(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationReadDescriptor {
        ProviderConfigurationReadDescriptor(
            id: id,
            protocolKind: .ollamaNative,
            endpoint: URL(string: "http://127.0.0.1:11434")!,
            model: "model",
            hasCredential: true,
            confirmedClass: nil,
            configurationRevision: 1,
            confirmationRevision: 0
        )
    }

    func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result {
        throw SanitizedFailure.invalidCredential
    }

    func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await operation()
    }

    func commitConfirmation(
        id: ProviderConfigurationID,
        expectedConfigurationRevision: UInt64,
        expectedConfirmationRevision: UInt64,
        proposedClass: DestinationPrivacyClass
    ) async throws -> ProviderConfirmationCommit {
        ProviderConfirmationCommit(
            configurationRevision: expectedConfigurationRevision,
            confirmationRevision: expectedConfirmationRevision + 1
        )
    }
}

final class ProviderVaultHandleTests: XCTestCase {
    func testHandleCarriesBothTypedFacetsWithoutCasting() async throws {
        let spy = HandleFacetSpy()
        let handle = ProviderVaultHandle(access: spy, confirmation: spy)
        let id = ProviderConfigurationID()
        let descriptor = try await handle.access.accessDescriptor(id)
        XCTAssertEqual(descriptor.id, id)
        let commit = try await handle.confirmation.commitConfirmation(
            id: id,
            expectedConfigurationRevision: 4,
            expectedConfirmationRevision: 8,
            proposedClass: .cloud
        )
        XCTAssertEqual(commit.configurationRevision, 4)
        XCTAssertEqual(commit.confirmationRevision, 9)
    }
}
