import Foundation
import PrivacyStorage
import SharedSupport
import XCTest

@testable import ModelProviders

final class CredentialApplicationTests: XCTestCase {
    func testLeaseAppliesBearerHeaderWithoutPrivacyStorageReverseDependency() throws {
        let value = CredentialHeaderValue(storage: Data("synthetic-token".utf8))
        let lease = ProviderCredentialLease(credential: value)
        var request = try credentialRequest()
        lease.apply(to: &request)
        let encoded = String(decoding: try request.encodedBytes(), as: UTF8.self)
        XCTAssertTrue(encoded.contains("authorization: Bearer synthetic-token\r\n"))
    }

    func testInvalidCredentialBytesFailBeforeTransportOpen() throws {
        let value = CredentialHeaderValue(storage: Data("bad\r\nvalue".utf8))
        let lease = ProviderCredentialLease(credential: value)
        var request = try credentialRequest()
        lease.apply(to: &request)
        XCTAssertThrowsError(try request.encodedBytes()) { error in
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
    }

    func testModelProvidersConsumesVaultHandleFacetsWithoutCasting() async throws {
        let spy = ModelProviderFacetSpy()
        let handle = ProviderVaultHandle(access: spy, confirmation: spy)
        let access: any ProviderAccess = handle.access
        let confirmation: any ProviderConfirmationCommitting = handle.confirmation
        let id = ProviderConfigurationID()
        let descriptor = try await access.accessDescriptor(id)
        XCTAssertEqual(descriptor.id, id)
        let commit = try await confirmation.commitConfirmation(
            id: id,
            expectedConfigurationRevision: 1,
            expectedConfirmationRevision: 0,
            proposedClass: .cloud
        )
        XCTAssertEqual(commit.confirmationRevision, 1)
    }
}

private struct ModelProviderFacetSpy:
    ProviderAccess,
    ProviderConfirmationCommitting {
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

private func credentialRequest() throws -> ProviderTransportRequest {
    ProviderTransportRequest(
        method: "POST",
        endpoint: try ProviderOriginParser.parse(
            XCTUnwrap(URL(string: "https://example.invalid/v1"))
        ),
        numericAddress: try IPAddress("93.184.216.34"),
        headers: [:],
        body: SensitiveBodyBytes(copying: Data("{}".utf8))
    )
}
