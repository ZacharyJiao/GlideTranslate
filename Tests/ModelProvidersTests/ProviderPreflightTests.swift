import Foundation
import PrivacyStorage
import SharedSupport
import XCTest

@testable import ModelProviders

actor StubProviderRepository: ProviderConfigurationReading {
    nonisolated let id: ProviderConfigurationID
    private var descriptor: ProviderConfigurationReadDescriptor
    private(set) var readCount = 0

    init(descriptor: ProviderConfigurationReadDescriptor) {
        id = descriptor.id
        self.descriptor = descriptor
    }

    func accessDescriptor(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationReadDescriptor {
        readCount += 1
        guard id == self.id else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        return descriptor
    }

    func replace(_ descriptor: ProviderConfigurationReadDescriptor) {
        self.descriptor = descriptor
    }
}

actor StubAddressResolver: AddressResolving {
    private var result: Result<Set<IPAddress>, AddressFailure>
    private(set) var readCount = 0

    init(addresses: [String]) throws {
        result = .success(Set(try addresses.map { try IPAddress($0) }))
    }

    func resolve(_ host: String) async throws -> Set<IPAddress> {
        readCount += 1
        return try result.get()
    }

    func replace(addresses: [String]) throws {
        result = .success(Set(try addresses.map { try IPAddress($0) }))
    }
}

final class DestinationMintSpy: DestinationSnapshotMintObserving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.withLock { storage }
    }

    func didMintDestinationSnapshot() {
        lock.withLock { storage += 1 }
    }
}

func providerDescriptor(
    id: ProviderConfigurationID = ProviderConfigurationID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    ),
    endpoint: String = "https://example.invalid/v1",
    confirmedClass: DestinationPrivacyClass? = .cloud,
    configurationRevision: UInt64 = 7,
    confirmationRevision: UInt64 = 3,
    protocolKind: ProviderProtocolKind = .openAICompatible,
    model: String = ["synthetic", "model"].joined(separator: "-")
) -> ProviderConfigurationReadDescriptor {
    ProviderConfigurationReadDescriptor(
        id: id,
        protocolKind: protocolKind,
        endpoint: URL(string: endpoint)!,
        model: model,
        hasCredential: false,
        confirmedClass: confirmedClass,
        configurationRevision: configurationRevision,
        confirmationRevision: confirmationRevision
    )
}

final class ProviderPreflightTests: XCTestCase {
    func testChangedClassRequiresReconfirmationAndDoesNotMint() async throws {
        let descriptor = providerDescriptor(
            confirmedClass: .localNetwork
        )
        let repository = StubProviderRepository(descriptor: descriptor)
        let resolver = try StubAddressResolver(addresses: ["93.184.216.34"])
        let mintSpy = DestinationMintSpy()
        let preflight = DefaultProviderPreflight(
            repository: repository,
            resolver: resolver,
            mintObserver: mintSpy
        )

        let result = await preflight.resolveDestination(for: descriptor.id)

        XCTAssertEqual(result.failure, .destinationReconfirmationRequired)
        XCTAssertEqual(mintSpy.count, 0)
    }

    func testUnchangedConfirmedClassMintsAllEvidence() async throws {
        let descriptor = providerDescriptor()
        let repository = StubProviderRepository(descriptor: descriptor)
        let resolver = try StubAddressResolver(addresses: ["93.184.216.34"])
        let mintSpy = DestinationMintSpy()
        let preflight = DefaultProviderPreflight(
            repository: repository,
            resolver: resolver,
            mintObserver: mintSpy
        )

        let snapshot = try await preflight.resolveDestination(
            for: descriptor.id
        ).get()

        XCTAssertEqual(snapshot.configurationID, descriptor.id)
        XCTAssertEqual(snapshot.configurationRevision, 7)
        XCTAssertEqual(snapshot.confirmationRevision, 3)
        XCTAssertEqual(snapshot.privacyClass, .cloud)
        XCTAssertEqual(snapshot.origin.scheme, "https")
        XCTAssertEqual(snapshot.origin.host, "example.invalid")
        XCTAssertEqual(snapshot.origin.effectivePort, 443)
        XCTAssertEqual(
            snapshot.resolutionFingerprint,
            [try IPAddress("93.184.216.34").fingerprint]
        )
        XCTAssertEqual(snapshot.protocolKind, .openAICompatible)
        XCTAssertEqual(snapshot.model, ["synthetic", "model"].joined(separator: "-"))
        XCTAssertEqual(mintSpy.count, 1)

        let current = try await preflight.currentSnapshot(
            for: descriptor.id
        ).get()
        XCTAssertEqual(current, snapshot)
        XCTAssertEqual(mintSpy.count, 2)
    }

    func testUnconfirmedLoopbackIsAcceptedButUnresolvedSetIsRejected() async throws {
        let loopback = providerDescriptor(
            endpoint: "http://127.0.0.1:11434",
            confirmedClass: nil,
            protocolKind: .ollamaNative
        )
        let loopbackPreflight = DefaultProviderPreflight(
            repository: StubProviderRepository(descriptor: loopback),
            resolver: try StubAddressResolver(addresses: ["127.0.0.1"])
        )
        let loopbackSnapshot = try await loopbackPreflight.resolveDestination(
            for: loopback.id
        ).get()
        XCTAssertEqual(loopbackSnapshot.privacyClass, .localOnDevice)

        let unresolved = providerDescriptor()
        let unresolvedPreflight = DefaultProviderPreflight(
            repository: StubProviderRepository(descriptor: unresolved),
            resolver: try StubAddressResolver(addresses: ["192.0.2.1"])
        )
        let result = await unresolvedPreflight.resolveDestination(
            for: unresolved.id
        )
        XCTAssertEqual(result.failure, .destinationReconfirmationRequired)
    }

    func testCloudHTTPFailsAsInvalidConfiguration() async throws {
        let descriptor = providerDescriptor(endpoint: "http://example.invalid/v1")
        let preflight = DefaultProviderPreflight(
            repository: StubProviderRepository(descriptor: descriptor),
            resolver: try StubAddressResolver(addresses: ["93.184.216.34"])
        )
        let result = await preflight.resolveDestination(for: descriptor.id)
        XCTAssertEqual(result.failure, .invalidProviderConfiguration)
    }

    func testSystemResolverCanonicalizesNumericAddressWithoutProviderTraffic() async throws {
        let addresses = try await SystemAddressResolver().resolve("127.0.0.1")
        XCTAssertEqual(addresses, [.v4([127, 0, 0, 1])])
    }

    func testResolverRecordReductionBoundsAndDeduplicates() throws {
        let thirtyTwo = (0..<32).map { value in
            ResolvedAddressRecord.ipv4([93, 184, 0, UInt8(value)])
        }
        XCTAssertEqual(
            try SystemAddressResolver.canonicalize(thirtyTwo).count,
            32
        )
        XCTAssertEqual(
            try SystemAddressResolver.canonicalize(thirtyTwo + [thirtyTwo[0]]).count,
            32
        )
        XCTAssertThrowsError(
            try SystemAddressResolver.canonicalize(
                thirtyTwo + [.ipv4([93, 184, 1, 1])]
            )
        ) { error in
            XCTAssertEqual(error as? AddressFailure, .tooManyAddresses)
        }
    }

    func testResolverRecordReductionRejectsLateInvalidMembers() throws {
        let valid = ResolvedAddressRecord.ipv4([127, 0, 0, 1])
        for invalid in [ResolvedAddressRecord.unsupported, .malformed] {
            XCTAssertThrowsError(
                try SystemAddressResolver.canonicalize([valid, invalid])
            ) { error in
                XCTAssertEqual(error as? AddressFailure, .invalid)
            }
        }
    }

    func testResolverRecordReductionEnforcesMappedAndScopeInvariants() throws {
        let loopbackIndex = if_nametoindex("lo0")
        XCTAssertNotEqual(loopbackIndex, 0)
        let mappedLoopback: [UInt8] = [
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0xff, 0xff, 127, 0, 0, 1
        ]
        XCTAssertEqual(
            try SystemAddressResolver.canonicalize([
                .ipv6(mappedLoopback, scopeID: 0)
            ]),
            [.v4([127, 0, 0, 1])]
        )

        var linkLocal = [UInt8](repeating: 0, count: 16)
        linkLocal[0] = 0xfe
        linkLocal[1] = 0x80
        linkLocal[15] = 8
        XCTAssertEqual(
            try SystemAddressResolver.canonicalize([
                .ipv6(linkLocal, scopeID: loopbackIndex)
            ]),
            [.v6(linkLocal, scopeID: loopbackIndex)]
        )
        XCTAssertThrowsError(
            try SystemAddressResolver.canonicalize([
                .ipv6(linkLocal, scopeID: 0)
            ])
        )

        var publicV6 = [UInt8](repeating: 0, count: 16)
        publicV6[0] = 0x20
        publicV6[1] = 0x01
        publicV6[15] = 1
        XCTAssertThrowsError(
            try SystemAddressResolver.canonicalize([
                .ipv6(publicV6, scopeID: loopbackIndex)
            ])
        )
    }
}

private extension Result where Success == ProviderDestinationSnapshot,
    Failure == SanitizedFailure {
    var failure: SanitizedFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
