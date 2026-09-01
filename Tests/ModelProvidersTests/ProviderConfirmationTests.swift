import Foundation
import PrivacyStorage
import SharedSupport
import XCTest

@testable import ModelProviders

actor StubConfirmationCommitter: ProviderConfirmationCommitting {
    private let expectedConfigurationRevision: UInt64
    private let expectedConfirmationRevision: UInt64
    private(set) var commitCount = 0

    init(
        expectedConfigurationRevision: UInt64 = 7,
        expectedConfirmationRevision: UInt64 = 3
    ) {
        self.expectedConfigurationRevision = expectedConfigurationRevision
        self.expectedConfirmationRevision = expectedConfirmationRevision
    }

    func recordedCommitCount() -> Int {
        commitCount
    }

    func commitConfirmation(
        id: ProviderConfigurationID,
        expectedConfigurationRevision: UInt64,
        expectedConfirmationRevision: UInt64,
        proposedClass: DestinationPrivacyClass
    ) async throws -> ProviderConfirmationCommit {
        guard expectedConfigurationRevision == self.expectedConfigurationRevision,
              expectedConfirmationRevision == self.expectedConfirmationRevision else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        commitCount += 1
        return ProviderConfirmationCommit(
            configurationRevision: expectedConfigurationRevision,
            confirmationRevision: expectedConfirmationRevision + 1
        )
    }
}

final class ProviderConfirmationTests: XCTestCase {
    private enum Drift: CaseIterable {
        case configurationRevision
        case confirmationRevision
        case origin
        case resolutionFingerprint
        case privacyClass
    }

    func testPrepareAndConfirmExactEvidenceCommitsOnce() async throws {
        let descriptor = providerDescriptor(confirmedClass: nil)
        let repository = StubProviderRepository(descriptor: descriptor)
        let resolver = try StubAddressResolver(addresses: ["93.184.216.34"])
        let committer = StubConfirmationCommitter()
        let service = DefaultProviderConfirmationService(
            repository: repository,
            resolver: resolver,
            committer: committer
        )

        let challenge = try await service.prepareConfirmation(for: descriptor.id)
        XCTAssertEqual(challenge.configurationID, descriptor.id)
        XCTAssertEqual(challenge.proposedClass, .cloud)
        XCTAssertEqual(challenge.configurationRevision, 7)
        XCTAssertEqual(challenge.confirmationRevision, 3)
        XCTAssertEqual(challenge.origin.host, "example.invalid")
        XCTAssertEqual(
            challenge.resolutionFingerprint,
            [try IPAddress("93.184.216.34").fingerprint]
        )
        let countBeforeConfirmation = await committer.recordedCommitCount()
        XCTAssertEqual(countBeforeConfirmation, 0)

        let snapshot = try await service.confirm(challenge)
        XCTAssertEqual(snapshot.configurationRevision, 7)
        XCTAssertEqual(snapshot.confirmationRevision, 4)
        XCTAssertEqual(snapshot.privacyClass, .cloud)
        let countAfterConfirmation = await committer.recordedCommitCount()
        XCTAssertEqual(countAfterConfirmation, 1)
    }

    func testEveryChallengeDriftMakesZeroCommitCalls() async throws {
        for drift in Drift.allCases {
            let descriptor = providerDescriptor(confirmedClass: nil)
            let repository = StubProviderRepository(descriptor: descriptor)
            let resolver = try StubAddressResolver(addresses: ["93.184.216.34"])
            let committer = StubConfirmationCommitter()
            let service = DefaultProviderConfirmationService(
                repository: repository,
                resolver: resolver,
                committer: committer
            )
            let challenge = try await service.prepareConfirmation(for: descriptor.id)

            switch drift {
            case .configurationRevision:
                await repository.replace(providerDescriptor(
                    confirmedClass: nil,
                    configurationRevision: 8
                ))
            case .confirmationRevision:
                await repository.replace(providerDescriptor(
                    confirmedClass: nil,
                    confirmationRevision: 4
                ))
            case .origin:
                await repository.replace(providerDescriptor(
                    endpoint: "https://other.invalid/v1",
                    confirmedClass: nil
                ))
            case .resolutionFingerprint:
                try await resolver.replace(addresses: ["1.1.1.1"])
            case .privacyClass:
                try await resolver.replace(addresses: [
                    [10, 0, 0, 8].map(String.init).joined(separator: ".")
                ])
            }

            do {
                _ = try await service.confirm(challenge)
                XCTFail("Expected drift rejection for \(drift)")
            } catch {
                XCTAssertEqual(
                    error as? SanitizedFailure,
                    .destinationReconfirmationRequired,
                    String(describing: drift)
                )
            }
            let commitCount = await committer.recordedCommitCount()
            XCTAssertEqual(commitCount, 0)
        }
    }

    func testHTTPSHostnameAcceptsProxyFakeIPAddressAsCloud() async throws {
        let descriptor = providerDescriptor(
            endpoint: "https://api.kimi.com/coding/v1",
            confirmedClass: nil
        )
        let service = DefaultProviderConfirmationService(
            repository: StubProviderRepository(descriptor: descriptor),
            resolver: try StubAddressResolver(addresses: ["198.18.0.20"]),
            committer: StubConfirmationCommitter()
        )

        let challenge = try await service.prepareConfirmation(for: descriptor.id)

        XCTAssertEqual(challenge.proposedClass, .cloud)
        XCTAssertEqual(challenge.origin.host, "api.kimi.com")
    }

    func testLiteralProxyFakeIPAddressRemainsUnresolved() async throws {
        let descriptor = providerDescriptor(
            endpoint: "https://198.18.0.20/coding/v1",
            confirmedClass: nil
        )
        let service = DefaultProviderConfirmationService(
            repository: StubProviderRepository(descriptor: descriptor),
            resolver: try StubAddressResolver(addresses: ["198.18.0.20"]),
            committer: StubConfirmationCommitter()
        )

        do {
            _ = try await service.prepareConfirmation(for: descriptor.id)
            XCTFail("A literal benchmark address must not be treated as a cloud host")
        } catch {
            XCTAssertEqual(
                error as? SanitizedFailure,
                .destinationReconfirmationRequired
            )
        }
    }

    func testPrepareNeverOffersConfirmationForLoopbackOrUnresolved() async throws {
        let loopback = providerDescriptor(
            endpoint: "http://127.0.0.1:11434",
            confirmedClass: nil,
            protocolKind: .ollamaNative
        )
        let loopbackService = DefaultProviderConfirmationService(
            repository: StubProviderRepository(descriptor: loopback),
            resolver: try StubAddressResolver(addresses: ["127.0.0.1"]),
            committer: StubConfirmationCommitter()
        )
        do {
            _ = try await loopbackService.prepareConfirmation(for: loopback.id)
            XCTFail("Loopback must not produce a confirmation challenge")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }

        let unresolved = providerDescriptor(confirmedClass: nil)
        let unresolvedService = DefaultProviderConfirmationService(
            repository: StubProviderRepository(descriptor: unresolved),
            resolver: try StubAddressResolver(addresses: ["192.0.2.1"]),
            committer: StubConfirmationCommitter()
        )
        do {
            _ = try await unresolvedService.prepareConfirmation(for: unresolved.id)
            XCTFail("Unresolved destination must not produce a challenge")
        } catch {
            XCTAssertEqual(
                error as? SanitizedFailure,
                .destinationReconfirmationRequired
            )
        }
    }
}
