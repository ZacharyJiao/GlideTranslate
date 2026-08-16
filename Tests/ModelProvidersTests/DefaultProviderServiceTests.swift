import Foundation
import PrivacyStorage
import SharedSupport
import XCTest

@testable import ModelProviders
@testable import PrivacyStorage

private actor RouterPreflightStub: ProviderPreflight {
    let result: Result<ProviderDestinationSnapshot, SanitizedFailure>
    private(set) var calls = 0

    init(_ result: Result<ProviderDestinationSnapshot, SanitizedFailure>) {
        self.result = result
    }

    func resolveDestination(
        for configurationID: ProviderConfigurationID
    ) -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        calls += 1
        return result
    }

    func currentSnapshot(
        for id: ProviderConfigurationID
    ) -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        result
    }
}

private actor RouterAccessStub: ProviderAccess {
    private let result: Result<ProviderConfigurationReadDescriptor, SanitizedFailure>
    private(set) var descriptorCalls = 0
    private(set) var leaseCalls = 0

    init(_ result: Result<ProviderConfigurationReadDescriptor, SanitizedFailure>) {
        self.result = result
    }

    func accessDescriptor(
        _ id: ProviderConfigurationID
    ) throws -> ProviderConfigurationReadDescriptor {
        descriptorCalls += 1
        return try result.get()
    }

    func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result {
        leaseCalls += 1
        throw SanitizedFailure.invalidCredential
    }

    func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await operation()
    }
}

private actor RouterOllamaSpy: OllamaProviderAdapting {
    var generationFailure: SanitizedFailure?
    var discoveryFailure: SanitizedFailure?
    private(set) var generated: [(TranslationRequest, RedirectAcceptedHop, Bool)] = []
    private(set) var discoveries: [(RedirectAcceptedHop, Bool)] = []
    private(set) var connectionTests: [(RedirectAcceptedHop, Bool)] = []

    func generate(
        _ request: TranslationRequest,
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> AsyncThrowingStream<TranslationChunk, Error> {
        generated.append((request, initial, requiresCredential))
        if let generationFailure { throw generationFailure }
        return routerStream([.content("ollama"), .done])
    }

    func discoverModels(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> [String] {
        discoveries.append((initial, requiresCredential))
        if let discoveryFailure { throw discoveryFailure }
        return ["ollama-model"]
    }

    func testConnection(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws {
        connectionTests.append((initial, requiresCredential))
    }

    func counts() -> (Int, Int, Int) {
        (generated.count, discoveries.count, connectionTests.count)
    }

    func generationHops() -> [(TranslationRequest, RedirectAcceptedHop, Bool)] {
        generated
    }
}

private actor RouterCompatibleSpy: OpenAICompatibleProviderAdapting {
    var generationFailure: SanitizedFailure?
    var discoveryFailure: SanitizedFailure?
    private(set) var generated: [(TranslationRequest, RedirectAcceptedHop, Bool)] = []
    private(set) var discoveries: [(RedirectAcceptedHop, Bool)] = []
    private(set) var connectionTests: [RedirectAcceptedHop] = []

    func generate(
        _ request: TranslationRequest,
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> AsyncThrowingStream<TranslationChunk, Error> {
        generated.append((request, initial, requiresCredential))
        if let generationFailure { throw generationFailure }
        return routerStream([.content("compatible"), .done])
    }

    func discoverModels(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> [String] {
        discoveries.append((initial, requiresCredential))
        if let discoveryFailure { throw discoveryFailure }
        return ["compatible-model"]
    }

    func testConnection(at initial: RedirectAcceptedHop) async throws {
        connectionTests.append(initial)
    }

    func counts() -> (Int, Int, Int) {
        (generated.count, discoveries.count, connectionTests.count)
    }

    func generationHops() -> [(TranslationRequest, RedirectAcceptedHop, Bool)] {
        generated
    }
}

private actor RouterNeverResolver: AddressResolving {
    func resolve(_ host: String) async throws -> Set<IPAddress> {
        throw AddressFailure.unresolved
    }
}

private actor RouterOpenCountingTransport: ProviderTransporting {
    private(set) var opens = 0

    func open(
        _ request: ProviderTransportRequest
    ) async throws -> ProviderTransportResponse {
        opens += 1
        throw SanitizedFailure.providerProtocolFailure
    }

    func count() -> Int { opens }
}

private actor RouterConnectionFactoryCounting: ProviderConnectionFactory {
    private(set) var calls = 0

    func makeConnection(
        descriptor: ProviderConnectionDescriptor
    ) async throws -> any ProviderNetworkConnection {
        calls += 1
        throw SanitizedFailure.providerProtocolFailure
    }

    func count() -> Int { calls }
}

private actor RouterMutationAccess: ProviderAccess {
    enum Drift: CaseIterable {
        case id, configurationRevision, confirmationRevision
        case protocolKind, model, confirmedClass, origin, inactive
    }

    private let initial: ProviderConfigurationReadDescriptor
    private let drift: Drift
    private var current: ProviderConfigurationReadDescriptor?
    private(set) var validatedCalls = 0
    private(set) var leaseCalls = 0
    private(set) var keychainReads = 0

    init(initial: ProviderConfigurationReadDescriptor, drift: Drift) {
        self.initial = initial
        self.drift = drift
        current = initial
    }

    func accessDescriptor(
        _ id: ProviderConfigurationID
    ) -> ProviderConfigurationReadDescriptor {
        defer { applyDrift() }
        return initial
    }

    func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        validatedCalls += 1
        try validate(expected)
        return try await operation()
    }

    func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result {
        leaseCalls += 1
        try validate(expected)
        keychainReads += 1
        let lease = ProviderCredentialLease(
            credential: CredentialHeaderValue(storage: Data("token".utf8))
        )
        return try await operation(lease)
    }

    func counts() -> (Int, Int, Int) {
        (validatedCalls, leaseCalls, keychainReads)
    }

    private func validate(_ expected: ProviderDestinationSnapshot) throws {
        guard let current,
              current.id == expected.configurationID,
              current.configurationRevision == expected.configurationRevision,
              current.confirmationRevision == expected.confirmationRevision,
              current.protocolKind == expected.protocolKind,
              current.model == expected.model,
              current.confirmedClass == expected.privacyClass,
              (try? ProviderOriginParser.parse(current.endpoint).origin)
                == expected.origin else {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
    }

    private func applyDrift() {
        switch drift {
        case .inactive:
            current = nil
        case .id:
            current = routerDescriptorCopy(initial, id: ProviderConfigurationID())
        case .configurationRevision:
            current = routerDescriptorCopy(initial, configurationRevision: 2)
        case .confirmationRevision:
            current = routerDescriptorCopy(initial, confirmationRevision: 2)
        case .protocolKind:
            current = routerDescriptorCopy(
                initial,
                protocolKind: initial.protocolKind == .ollamaNative
                    ? .openAICompatible
                    : .ollamaNative
            )
        case .model:
            current = routerDescriptorCopy(initial, model: "changed")
        case .confirmedClass:
            current = routerDescriptorCopy(initial, confirmedClass: .localNetwork)
        case .origin:
            current = routerDescriptorCopy(
                initial,
                endpoint: URL(string: "https://other.invalid/v1")!
            )
        }
    }
}

final class DefaultProviderServiceTests: XCTestCase {
    func testGenerateRoutesToExactlyOneAdapterWithoutFallback() async throws {
        for kind in [ProviderProtocolKind.ollamaNative, .openAICompatible] {
            let snapshot = try routerSnapshot(kind: kind)
            let ollama = RouterOllamaSpy()
            let compatible = RouterCompatibleSpy()
            let service = DefaultProviderService(
                preflight: RouterPreflightStub(.success(snapshot)),
                access: RouterAccessStub(.success(try routerDescriptor(snapshot))),
                ollama: ollama,
                compatible: compatible
            )
            let chunks = try await service.generate(
                routerRequest(model: "model"),
                authorizedDestination: snapshot
            ).routerCollect()
            XCTAssertEqual(
                chunks,
                [.content(kind == .ollamaNative ? "ollama" : "compatible"), .done]
            )
            let ollamaCounts = await ollama.counts()
            let compatibleCounts = await compatible.counts()
            XCTAssertEqual(ollamaCounts.0, kind == .ollamaNative ? 1 : 0)
            XCTAssertEqual(compatibleCounts.0, kind == .openAICompatible ? 1 : 0)
            let selectedCalls = kind == .ollamaNative
                ? await ollama.generationHops()
                : await compatible.generationHops()
            XCTAssertEqual(
                selectedCalls.first?.2,
                kind == .openAICompatible
            )

            if kind == .ollamaNative {
                await ollama.setGenerationFailure(.providerProtocolFailure)
            } else {
                await compatible.setGenerationFailure(.providerProtocolFailure)
            }
            let failure = await routerFailure(service.generate(
                routerRequest(model: "model"),
                authorizedDestination: snapshot
            ))
            XCTAssertEqual(failure, .providerProtocolFailure)
            let afterOllama = await ollama.counts()
            let afterCompatible = await compatible.counts()
            XCTAssertEqual(afterOllama.0, kind == .ollamaNative ? 2 : 0)
            XCTAssertEqual(afterCompatible.0, kind == .openAICompatible ? 2 : 0)
        }
    }

    func testEveryFreshSnapshotMismatchStopsBeforeDescriptorAndAdapters() async throws {
        let fresh = try routerSnapshot(kind: .openAICompatible)
        let otherOrigin = try ProviderOriginParser.parse(
            URL(string: "https://other.invalid/v1")!
        ).origin
        let variants = [
            try routerSnapshot(kind: .openAICompatible, id: ProviderConfigurationID()),
            routerCopy(fresh, privacyClass: .localNetwork),
            routerCopy(fresh, configurationRevision: 2),
            routerCopy(fresh, confirmationRevision: 2),
            routerCopy(fresh, origin: otherOrigin),
            routerCopy(fresh, resolutionFingerprint: [try IPAddress("93.184.216.35").fingerprint]),
            routerCopy(fresh, protocolKind: .ollamaNative),
            routerCopy(fresh, model: "other-model")
        ]

        for authorized in variants {
            let access = RouterAccessStub(.success(try routerDescriptor(fresh)))
            let ollama = RouterOllamaSpy()
            let compatible = RouterCompatibleSpy()
            let service = DefaultProviderService(
                preflight: RouterPreflightStub(.success(fresh)),
                access: access,
                ollama: ollama,
                compatible: compatible
            )
            let failure = await routerFailure(service.generate(
                routerRequest(model: authorized.model),
                authorizedDestination: authorized
            ))
            XCTAssertEqual(failure, .destinationReconfirmationRequired)
            let accessCounts = await access.counts()
            let ollamaCounts = await ollama.counts()
            let compatibleCounts = await compatible.counts()
            XCTAssertEqual(accessCounts.0, 0)
            XCTAssertEqual(accessCounts.1, 0)
            XCTAssertEqual(ollamaCounts.0, 0)
            XCTAssertEqual(compatibleCounts.0, 0)
        }
    }

    func testDescriptorDriftInvalidFingerprintAndRequestModelFailClosed() async throws {
        let snapshot = try routerSnapshot(kind: .openAICompatible)
        let descriptor = try routerDescriptor(snapshot)
        let descriptorVariants = [
            routerDescriptorCopy(descriptor, id: ProviderConfigurationID()),
            routerDescriptorCopy(descriptor, protocolKind: .ollamaNative),
            routerDescriptorCopy(
                descriptor,
                endpoint: URL(string: "https://other.invalid/v1")!
            ),
            routerDescriptorCopy(descriptor, model: "other-model"),
            routerDescriptorCopy(descriptor, confirmedClass: .localNetwork),
            routerDescriptorCopy(descriptor, configurationRevision: 2),
            routerDescriptorCopy(descriptor, confirmationRevision: 2)
        ]
        for changed in descriptorVariants {
            try await assertRouterRejects(
                snapshot: snapshot,
                descriptor: .success(changed),
                requestModel: "model"
            )
        }
        try await assertRouterRejects(
            snapshot: snapshot,
            descriptor: .failure(.invalidProviderConfiguration),
            requestModel: "model",
            expected: .invalidProviderConfiguration
        )
        try await assertRouterRejects(
            snapshot: snapshot,
            descriptor: .success(descriptor),
            requestModel: "other-model"
        )
        try await assertRouterRejects(
            snapshot: routerCopy(snapshot, resolutionFingerprint: []),
            descriptor: .success(descriptor),
            requestModel: "model"
        )
        try await assertRouterRejects(
            snapshot: routerCopy(snapshot, resolutionFingerprint: ["not-an-address"]),
            descriptor: .success(descriptor),
            requestModel: "model"
        )
    }

    func testInspectionRoutesContentFreeAndEmptyModelOnlyBlocksGenerate() async throws {
        for kind in [ProviderProtocolKind.ollamaNative, .openAICompatible] {
            let snapshot = try routerSnapshot(kind: kind, model: "")
            let ollama = RouterOllamaSpy()
            let compatible = RouterCompatibleSpy()
            let service = DefaultProviderService(
                preflight: RouterPreflightStub(.success(snapshot)),
                access: RouterAccessStub(.success(try routerDescriptor(snapshot))),
                ollama: ollama,
                compatible: compatible
            )
            let names = try await service.discoverModels(
                for: snapshot.configurationID
            )
            XCTAssertEqual(
                names,
                [kind == .ollamaNative ? "ollama-model" : "compatible-model"]
            )
            try await service.testConnection(for: snapshot.configurationID)
            let failure = await routerFailure(service.generate(
                routerRequest(model: ""),
                authorizedDestination: snapshot
            ))
            XCTAssertEqual(failure, .modelUnavailable)
            let ollamaCounts = await ollama.counts()
            let compatibleCounts = await compatible.counts()
            XCTAssertEqual(ollamaCounts.1, kind == .ollamaNative ? 1 : 0)
            XCTAssertEqual(ollamaCounts.2, kind == .ollamaNative ? 1 : 0)
            XCTAssertEqual(compatibleCounts.1, kind == .openAICompatible ? 1 : 0)
            XCTAssertEqual(compatibleCounts.2, kind == .openAICompatible ? 1 : 0)
            XCTAssertEqual(ollamaCounts.0 + compatibleCounts.0, 0)
        }
    }

    func testCanonicalAddressSelectionAndFactoryComposition() async throws {
        let low = try IPAddress("1.1.1.1")
        let high = try IPAddress("93.184.216.34")
        let snapshot = routerCopy(
            try routerSnapshot(kind: .openAICompatible),
            resolutionFingerprint: [high.fingerprint, low.fingerprint]
        )
        let compatible = RouterCompatibleSpy()
        let service = DefaultProviderService(
            preflight: RouterPreflightStub(.success(snapshot)),
            access: RouterAccessStub(.success(try routerDescriptor(snapshot))),
            ollama: RouterOllamaSpy(),
            compatible: compatible
        )
        _ = try await service.generate(
            routerRequest(model: "model"),
            authorizedDestination: snapshot
        ).routerCollect()
        let calls = await compatible.generationHops()
        XCTAssertEqual(calls.first?.1.numericAddress, low)
        XCTAssertEqual(calls.first?.2, true)

        let handle = ProviderVaultHandle(
            access: RouterAccessStub(.success(try routerDescriptor(snapshot))),
            confirmation: RouterConfirmationStub()
        )
        let services = ModelProviderFactory.make(
            vault: handle,
            diagnostics: RouterDiagnosticsStub()
        )
        XCTAssertTrue(services.service is DefaultProviderService)
        XCTAssertTrue(services.inspection is DefaultProviderService)
        XCTAssertTrue(
            services.service as AnyObject === services.inspection as AnyObject
        )
        _ = ModelProviderServices(
            preflight: services.preflight,
            confirmation: services.confirmation,
            service: services.service,
            inspection: services.inspection
        )
    }

    func testMutationWindowRevalidatesBeforeKeychainOrRequestForBothAdapters()
        async throws {
        for kind in [ProviderProtocolKind.ollamaNative, .openAICompatible] {
            for hasCredential in [false, true] {
                for drift in RouterMutationAccess.Drift.allCases {
                    let snapshot = try routerSnapshot(kind: kind)
                    let descriptor = routerDescriptorCopy(
                        try routerDescriptor(snapshot),
                        hasCredential: hasCredential
                    )
                    let access = RouterMutationAccess(
                        initial: descriptor,
                        drift: drift
                    )
                    let transport = RouterOpenCountingTransport()
                    let resolver = RouterNeverResolver()
                    let ollamaSpy = RouterOllamaSpy()
                    let compatibleSpy = RouterCompatibleSpy()
                    let service: DefaultProviderService
                    if kind == .ollamaNative {
                        service = DefaultProviderService(
                            preflight: RouterPreflightStub(.success(snapshot)),
                            access: access,
                            ollama: OllamaProvider(
                                transport: transport,
                                resolver: resolver,
                                access: access
                            ),
                            compatible: compatibleSpy
                        )
                    } else {
                        service = DefaultProviderService(
                            preflight: RouterPreflightStub(.success(snapshot)),
                            access: access,
                            ollama: ollamaSpy,
                            compatible: OpenAICompatibleProvider(
                                transport: transport,
                                resolver: resolver,
                                access: access
                            )
                        )
                    }

                    let failure = await routerFailure(service.generate(
                        routerRequest(model: "model"),
                        authorizedDestination: snapshot
                    ))
                    XCTAssertEqual(
                        failure,
                        .destinationReconfirmationRequired,
                        "\(kind) credential=\(hasCredential) drift=\(drift)"
                    )
                    let accessCounts = await access.counts()
                    XCTAssertEqual(accessCounts.0, hasCredential ? 0 : 1)
                    XCTAssertEqual(accessCounts.1, hasCredential ? 1 : 0)
                    XCTAssertEqual(accessCounts.2, 0)
                    let openCount = await transport.count()
                    let ollamaCounts = await ollamaSpy.counts()
                    let compatibleCounts = await compatibleSpy.counts()
                    XCTAssertEqual(openCount, 0)
                    XCTAssertEqual(ollamaCounts.0, 0)
                    XCTAssertEqual(compatibleCounts.0, 0)
                }
            }
        }
    }

    func testCompatibleConnectionInspectionRevalidatesBeforeTCP() async throws {
        for hasCredential in [false, true] {
            for drift in RouterMutationAccess.Drift.allCases {
                let snapshot = try routerSnapshot(kind: .openAICompatible)
                let descriptor = routerDescriptorCopy(
                    try routerDescriptor(snapshot),
                    hasCredential: hasCredential
                )
                let access = RouterMutationAccess(
                    initial: descriptor,
                    drift: drift
                )
                let factory = RouterConnectionFactoryCounting()
                let compatible = OpenAICompatibleProvider(
                    transport: RouterOpenCountingTransport(),
                    resolver: RouterNeverResolver(),
                    access: access,
                    diagnostics: RouterDiagnosticsStub(),
                    connectionFactory: factory
                )
                let ollama = RouterOllamaSpy()
                let service = DefaultProviderService(
                    preflight: RouterPreflightStub(.success(snapshot)),
                    access: access,
                    ollama: ollama,
                    compatible: compatible
                )
                do {
                    try await service.testConnection(
                        for: snapshot.configurationID
                    )
                    XCTFail("Expected drift rejection")
                } catch {
                    XCTAssertEqual(
                        error as? SanitizedFailure,
                        .destinationReconfirmationRequired,
                        "credential=\(hasCredential) drift=\(drift)"
                    )
                }
                let accessCounts = await access.counts()
                let connectionCalls = await factory.count()
                let ollamaCounts = await ollama.counts()
                XCTAssertEqual(accessCounts.0, 1)
                XCTAssertEqual(accessCounts.1, 0)
                XCTAssertEqual(accessCounts.2, 0)
                XCTAssertEqual(connectionCalls, 0)
                XCTAssertEqual(ollamaCounts.2, 0)
            }
        }
    }

    private func assertRouterRejects(
        snapshot: ProviderDestinationSnapshot,
        descriptor: Result<ProviderConfigurationReadDescriptor, SanitizedFailure>,
        requestModel: String,
        expected: SanitizedFailure = .destinationReconfirmationRequired
    ) async throws {
        let ollama = RouterOllamaSpy()
        let compatible = RouterCompatibleSpy()
        let access = RouterAccessStub(descriptor)
        let service = DefaultProviderService(
            preflight: RouterPreflightStub(.success(snapshot)),
            access: access,
            ollama: ollama,
            compatible: compatible
        )
        let failure = await routerFailure(service.generate(
            routerRequest(model: requestModel),
            authorizedDestination: snapshot
        ))
        XCTAssertEqual(failure, expected)
        let ollamaCounts = await ollama.counts()
        let compatibleCounts = await compatible.counts()
        let accessCounts = await access.counts()
        XCTAssertEqual(ollamaCounts.0, 0)
        XCTAssertEqual(compatibleCounts.0, 0)
        XCTAssertEqual(accessCounts.1, 0)
    }
}

private actor RouterConfirmationStub: ProviderConfirmationCommitting {
    func commitConfirmation(
        id: ProviderConfigurationID,
        expectedConfigurationRevision: UInt64,
        expectedConfirmationRevision: UInt64,
        proposedClass: DestinationPrivacyClass
    ) throws -> ProviderConfirmationCommit {
        ProviderConfirmationCommit(
            configurationRevision: expectedConfigurationRevision,
            confirmationRevision: expectedConfirmationRevision + 1
        )
    }
}

private actor RouterDiagnosticsStub: ProviderDiagnosticReporting {
    func record(_ event: ProviderDiagnosticEvent) {}
}

private extension RouterAccessStub {
    func counts() -> (Int, Int) { (descriptorCalls, leaseCalls) }
}

private extension RouterOllamaSpy {
    func setGenerationFailure(_ failure: SanitizedFailure) {
        generationFailure = failure
    }
}

private extension RouterCompatibleSpy {
    func setGenerationFailure(_ failure: SanitizedFailure) {
        generationFailure = failure
    }
}

private func routerSnapshot(
    kind: ProviderProtocolKind,
    id: ProviderConfigurationID = ProviderConfigurationID(),
    model: String = "model"
) throws -> ProviderDestinationSnapshot {
    let endpoint = try ProviderOriginParser.parse(
        URL(string: "https://example.invalid/v1")!
    )
    let address = try IPAddress("93.184.216.34")
    return .mintAfterResolution(
        configurationID: id,
        privacyClass: .cloud,
        configurationRevision: 1,
        confirmationRevision: 1,
        origin: endpoint.origin,
        resolutionFingerprint: [address.fingerprint],
        protocolKind: kind,
        model: model
    )
}

private func routerCopy(
    _ value: ProviderDestinationSnapshot,
    privacyClass: DestinationPrivacyClass? = nil,
    configurationRevision: UInt64? = nil,
    confirmationRevision: UInt64? = nil,
    origin: ProviderOrigin? = nil,
    resolutionFingerprint: Set<String>? = nil,
    protocolKind: ProviderProtocolKind? = nil,
    model: String? = nil
) -> ProviderDestinationSnapshot {
    .mintAfterResolution(
        configurationID: value.configurationID,
        privacyClass: privacyClass ?? value.privacyClass,
        configurationRevision: configurationRevision ?? value.configurationRevision,
        confirmationRevision: confirmationRevision ?? value.confirmationRevision,
        origin: origin ?? value.origin,
        resolutionFingerprint: resolutionFingerprint ?? value.resolutionFingerprint,
        protocolKind: protocolKind ?? value.protocolKind,
        model: model ?? value.model
    )
}

private func routerDescriptor(
    _ snapshot: ProviderDestinationSnapshot
) throws -> ProviderConfigurationReadDescriptor {
    ProviderConfigurationReadDescriptor(
        id: snapshot.configurationID,
        protocolKind: snapshot.protocolKind,
        endpoint: URL(string: "https://example.invalid/v1")!,
        model: snapshot.model,
        hasCredential: snapshot.protocolKind == .openAICompatible,
        confirmedClass: snapshot.privacyClass,
        configurationRevision: snapshot.configurationRevision,
        confirmationRevision: snapshot.confirmationRevision
    )
}

private func routerDescriptorCopy(
    _ value: ProviderConfigurationReadDescriptor,
    id: ProviderConfigurationID? = nil,
    protocolKind: ProviderProtocolKind? = nil,
    endpoint: URL? = nil,
    model: String? = nil,
    hasCredential: Bool? = nil,
    confirmedClass: DestinationPrivacyClass?? = nil,
    configurationRevision: UInt64? = nil,
    confirmationRevision: UInt64? = nil
) -> ProviderConfigurationReadDescriptor {
    ProviderConfigurationReadDescriptor(
        id: id ?? value.id,
        protocolKind: protocolKind ?? value.protocolKind,
        endpoint: endpoint ?? value.endpoint,
        model: model ?? value.model,
        hasCredential: hasCredential ?? value.hasCredential,
        confirmedClass: confirmedClass ?? value.confirmedClass,
        configurationRevision: configurationRevision ?? value.configurationRevision,
        confirmationRevision: confirmationRevision ?? value.confirmationRevision
    )
}

private func routerRequest(model: String) -> TranslationRequest {
    TranslationRequest(
        instruction: "instruction",
        userContent: "selected-text",
        model: model,
        timeouts: TranslationTimeoutPolicy(
            connection: .seconds(1),
            firstToken: .seconds(1),
            streamIdle: .seconds(1)
        ),
        requestID: TranslationRequestID()
    )
}

private func routerStream(
    _ chunks: [TranslationChunk]
) -> AsyncThrowingStream<TranslationChunk, Error> {
    let pair = AsyncThrowingStream<TranslationChunk, Error>.makeStream()
    for chunk in chunks { pair.continuation.yield(chunk) }
    pair.continuation.finish()
    return pair.stream
}

private func routerFailure(
    _ stream: AsyncThrowingStream<TranslationChunk, Error>
) async -> SanitizedFailure? {
    do {
        _ = try await stream.routerCollect()
        return nil
    } catch {
        return error as? SanitizedFailure
    }
}

private extension AsyncThrowingStream where Failure == Error {
    func routerCollect() async throws -> [Element] {
        var values: [Element] = []
        for try await value in self { values.append(value) }
        return values
    }
}
