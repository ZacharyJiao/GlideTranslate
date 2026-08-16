import Foundation
import PrivacyStorage
import SharedSupport
import XCTest

@testable import ModelProviders
@testable import PrivacyStorage

private actor CompatibleResolverStub: AddressResolving {
    private(set) var calls = 0
    func resolve(_ host: String) async throws -> Set<IPAddress> {
        calls += 1
        throw AddressFailure.unresolved
    }
    func count() -> Int { calls }
}

private actor CompatibleResolvedAddressStub: AddressResolving {
    private(set) var calls = 0
    func resolve(_ host: String) async throws -> Set<IPAddress> {
        calls += 1
        return [try IPAddress("93.184.216.34")]
    }
    func count() -> Int { calls }
}

private actor CompatibleAccessSpy: ProviderAccess {
    private(set) var leases = 0

    func accessDescriptor(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationReadDescriptor {
        ProviderConfigurationReadDescriptor(
            id: id,
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://example.invalid/v1")!,
            model: "model",
            hasCredential: true,
            confirmedClass: .cloud,
            configurationRevision: 1,
            confirmationRevision: 1
        )
    }

    func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result {
        leases += 1
        let value = CredentialHeaderValue(storage: Data("compatible-token".utf8))
        let lease = ProviderCredentialLease(credential: value)
        return try await operation(lease)
    }

    func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await operation()
    }

    func count() -> Int { leases }
}

private actor CompatibleTransportSpy: ProviderTransporting {
    enum Outcome: Sendable {
        case events([HTTPResponseEvent])
        case failure(SanitizedFailure)
    }
    private var outcomes: [Outcome]
    private var requests: [Data] = []

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

    func open(
        _ request: ProviderTransportRequest
    ) async throws -> ProviderTransportResponse {
        requests.append(try request.encodedBytes())
        guard !outcomes.isEmpty else { throw SanitizedFailure.providerProtocolFailure }
        switch outcomes.removeFirst() {
        case .failure(let failure): throw failure
        case .events(let events):
            let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
            for event in events { pair.continuation.yield(event) }
            pair.continuation.finish()
            return ProviderTransportResponse(events: pair.stream, cancelOperation: {})
        }
    }

    func captured() -> [Data] { requests }
}

private actor BlockingCompatibleTransport: ProviderTransporting {
    private var opened = false
    private var cancellations = 0
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: AsyncThrowingStream<HTTPResponseEvent, Error>.Continuation?

    func open(
        _ request: ProviderTransportRequest
    ) async throws -> ProviderTransportResponse {
        opened = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
        continuation = pair.continuation
        return ProviderTransportResponse(
            events: pair.stream,
            cancelOperation: { await self.recordCancel() }
        )
    }

    func waitUntilOpened() async {
        if opened { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        if cancellations > 0 { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func recordCancel() {
        cancellations += 1
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func count() -> Int { cancellations }

    func sendLate(_ events: [HTTPResponseEvent]) {
        for event in events { continuation?.yield(event) }
        continuation?.finish()
    }
}

private actor CompatibleDiagnosticSpy: ProviderDiagnosticReporting {
    private var events: [ProviderDiagnosticEvent] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ event: ProviderDiagnosticEvent) {
        events.append(event)
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func waitForEvent() async {
        if !events.isEmpty { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func captured() -> [ProviderDiagnosticEvent] { events }
}

private actor CompatibleConnectionSpy: ProviderNetworkConnection {
    private(set) var starts = 0
    private(set) var sends = 0
    private(set) var cancellations = 0

    func start() { starts += 1 }
    func send(_ bytes: Data) { sends += 1 }
    func receive() -> ProviderConnectionRead {
        ProviderConnectionRead(bytes: Data(), isComplete: true)
    }
    func cancel() { cancellations += 1 }

    func counts() -> (Int, Int, Int) { (starts, sends, cancellations) }
}

private actor CompatibleConnectionFactorySpy: ProviderConnectionFactory {
    let connection: any ProviderNetworkConnection
    private(set) var descriptors: [ProviderConnectionDescriptor] = []

    init(connection: any ProviderNetworkConnection) { self.connection = connection }

    func makeConnection(
        descriptor: ProviderConnectionDescriptor
    ) -> any ProviderNetworkConnection {
        descriptors.append(descriptor)
        return connection
    }

    func captured() -> [ProviderConnectionDescriptor] { descriptors }
}

private actor BlockingInspectionConnection: ProviderNetworkConnection {
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellations = 0

    func start() async throws {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await withCheckedThrowingContinuation { startWaiter = $0 }
    }

    func send(_ bytes: Data) {}
    func receive() -> ProviderConnectionRead {
        ProviderConnectionRead(bytes: Data(), isComplete: true)
    }

    func cancel() {
        cancellations += 1
        startWaiter?.resume(throwing: SanitizedFailure.cancelled)
        startWaiter = nil
    }

    func waitUntilStarted() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func cancelCount() -> Int { cancellations }
}

private actor SerialCompatibleAccessSpy: ProviderAccess {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func accessDescriptor(
        _ id: ProviderConfigurationID
    ) async throws -> ProviderConfigurationReadDescriptor {
        await acquire()
        defer { release() }
        return ProviderConfigurationReadDescriptor(
            id: id,
            protocolKind: .openAICompatible,
            endpoint: URL(string: "https://example.invalid/v1")!,
            model: "model",
            hasCredential: false,
            confirmedClass: .cloud,
            configurationRevision: 1,
            confirmationRevision: 1
        )
    }

    func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        await acquire()
        defer { release() }
        return try await operation()
    }

    func withCredentialLease<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable (
            borrowing ProviderCredentialLease
        ) async throws -> Result
    ) async throws -> Result {
        throw SanitizedFailure.invalidCredential
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class OpenAICompatibleProviderTests: XCTestCase {
    func testCancellationClosesUnderlyingRequestExactlyOnce() async throws {
        let transport = BlockingCompatibleTransport()
        let diagnostics = CompatibleDiagnosticSpy()
        let provider = OpenAICompatibleProvider(
            transport: transport,
            resolver: CompatibleResolverStub(),
            access: CompatibleAccessSpy(),
            diagnostics: diagnostics
        )
        let stream = try await provider.generate(
            compatibleRequest(), at: compatibleHop()
        )
        let collector = Task { try await stream.compatibleCollect() }
        await transport.waitUntilOpened()
        collector.cancel()
        do {
            _ = try await collector.value
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .cancelled)
        }
        await transport.waitUntilCancelled()
        await transport.sendLate([
            .head(HTTPResponseHead(status: 200, location: nil)),
            .body(Data("data: [DONE]\n\n".utf8)),
            .complete
        ])
        await diagnostics.waitForEvent()
        let count = await transport.count()
        let diagnosticEvents = await diagnostics.captured()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(diagnosticEvents.map(\.outcomeCategory), [.cancelled])
    }

    func testRequestShapeCredentialTimingAndInformationalHead() async throws {
        let body = Data((
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"
                + "data: [DONE]\n\n"
        ).utf8)
        let transport = CompatibleTransportSpy([.events([
            .head(HTTPResponseHead(status: 103, location: nil)),
            .head(HTTPResponseHead(status: 200, location: nil)),
            .body(body),
            .complete
        ])])
        let access = CompatibleAccessSpy()
        let provider = OpenAICompatibleProvider(
            transport: transport,
            resolver: CompatibleResolverStub(),
            access: access
        )
        let stream = try await provider.generate(
            compatibleRequest(), at: compatibleHop()
        )
        let chunks = try await stream.compatibleCollect()
        XCTAssertEqual(chunks, [.connected, .content("ok"), .done])
        let leases = await access.count()
        XCTAssertEqual(leases, 1)

        let requests = await transport.captured()
        let wire = try XCTUnwrap(requests.compatibleOnly)
        let separator = Data("\r\n\r\n".utf8)
        let range = try XCTUnwrap(wire.range(of: separator))
        let head = String(decoding: wire[..<range.lowerBound], as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("POST /v1/chat/completions HTTP/1.1"))
        XCTAssertTrue(head.lowercased().contains("authorization: bearer compatible-token"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(wire[range.upperBound...])
        ) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [
            ["role": "system", "content": "instruction"],
            ["role": "user", "content": "selected-text"]
        ])
    }

    func testAuthenticationAndProtocolFailuresDiscardBody() async throws {
        for status in [401, 403, 429, 500] {
            let marker = "SYNTHETIC_BODY_\(status)"
            let transport = CompatibleTransportSpy([.events([
                .head(HTTPResponseHead(status: status, location: nil)),
                .body(Data(marker.utf8)),
                .complete
            ])])
            let provider = OpenAICompatibleProvider(
                transport: transport,
                resolver: CompatibleResolverStub(),
                access: CompatibleAccessSpy()
            )
            let stream = try await provider.generate(
                compatibleRequest(), at: compatibleHop()
            )
            do {
                _ = try await stream.compatibleCollect()
                XCTFail("Expected failure for \(status)")
            } catch {
                XCTAssertEqual(
                    error as? SanitizedFailure,
                    status == 401 || status == 403
                        ? .invalidCredential
                        : .providerProtocolFailure
                )
                XCTAssertFalse(String(describing: error).contains(marker))
            }
        }
    }

    func testCrossOriginRedirectHasNoSecondLeaseOrRequest() async throws {
        let transport = CompatibleTransportSpy([.events([
            .head(HTTPResponseHead(
                status: 307,
                location: "https://other.invalid/v1/chat/completions"
            )),
            .complete
        ])])
        let access = CompatibleAccessSpy()
        let resolver = CompatibleResolverStub()
        let provider = OpenAICompatibleProvider(
            transport: transport,
            resolver: resolver,
            access: access
        )
        let stream = try await provider.generate(
            compatibleRequest(), at: compatibleHop()
        )
        do {
            _ = try await stream.compatibleCollect()
            XCTFail("Expected redirect rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .destinationReconfirmationRequired)
        }
        let leases = await access.count()
        let requests = await transport.captured()
        let resolverCalls = await resolver.count()
        XCTAssertEqual(leases, 1)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(resolverCalls, 0)
    }

    func testSameOriginRedirectRevalidatesAndReacquiresCredential() async throws {
        let responseBody = Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"
                .utf8
        ) + Data("data: [DONE]\n\n".utf8)
        let transport = CompatibleTransportSpy([
            .events([
                .head(HTTPResponseHead(
                    status: 307,
                    location: "https://example.invalid/v1/redirected"
                )),
                .complete
            ]),
            .events([
                .head(HTTPResponseHead(status: 200, location: nil)),
                .body(responseBody),
                .complete
            ])
        ])
        let access = CompatibleAccessSpy()
        let resolver = CompatibleResolvedAddressStub()
        let provider = OpenAICompatibleProvider(
            transport: transport,
            resolver: resolver,
            access: access
        )
        let stream = try await provider.generate(
            compatibleRequest(), at: compatibleHop()
        )
        let chunks = try await stream.compatibleCollect()
        XCTAssertEqual(chunks, [.connected, .content("ok"), .done])
        let leaseCount = await access.count()
        let resolutionCount = await resolver.count()
        let requestCount = await transport.captured().count
        XCTAssertEqual(leaseCount, 2)
        XCTAssertEqual(resolutionCount, 1)
        XCTAssertEqual(requestCount, 2)
    }

    func testExplicitDiscoveryIsContentFreeAndBoundedToModelsPath() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [["id": "z"], ["id": " a "], ["id": "z"]]
        ])
        let transport = CompatibleTransportSpy([.events([
            .head(HTTPResponseHead(status: 200, location: nil)),
            .body(body),
            .complete
        ])])
        let provider = OpenAICompatibleProvider(
            transport: transport,
            resolver: CompatibleResolverStub(),
            access: CompatibleAccessSpy()
        )
        let models = try await provider.discoverModels(
            at: compatibleHop(), requiresCredential: true
        )
        XCTAssertEqual(models, ["a", "z"])
        let requests = await transport.captured()
        let wire = String(decoding: try XCTUnwrap(requests.compatibleOnly), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("GET /v1/models HTTP/1.1\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(wire.contains("selected-text"))
    }

    func testDiscoveryStatusClassificationAndBodyDiscard() async throws {
        let rows: [(Int, SanitizedFailure)] = [
            (401, .invalidCredential),
            (403, .invalidCredential),
            (404, .modelUnavailable),
            (405, .modelUnavailable),
            (501, .modelUnavailable),
            (429, .providerProtocolFailure),
            (500, .providerProtocolFailure)
        ]
        for (status, expected) in rows {
            let marker = "SYNTHETIC_DISCOVERY_BODY_\(status)"
            let transport = CompatibleTransportSpy([.events([
                .head(HTTPResponseHead(status: status, location: nil)),
                .body(Data(marker.utf8)),
                .complete
            ])])
            let provider = OpenAICompatibleProvider(
                transport: transport,
                resolver: CompatibleResolverStub(),
                access: CompatibleAccessSpy()
            )
            do {
                _ = try await provider.discoverModels(
                    at: compatibleHop(), requiresCredential: true
                )
                XCTFail("Expected failure for \(status)")
            } catch {
                XCTAssertEqual(error as? SanitizedFailure, expected)
                XCTAssertFalse(String(describing: error).contains(marker))
            }
        }
    }

    func testDiscoveryRejectsBodyLargerThanOneMiB() async throws {
        let transport = CompatibleTransportSpy([.events([
            .head(HTTPResponseHead(status: 200, location: nil)),
            .body(Data(repeating: 0x61, count: 1_048_577)),
            .complete
        ])])
        let provider = OpenAICompatibleProvider(
            transport: transport,
            resolver: CompatibleResolverStub(),
            access: CompatibleAccessSpy()
        )
        do {
            _ = try await provider.discoverModels(
                at: compatibleHop(), requiresCredential: true
            )
            XCTFail("Expected bounded-body rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
        }
    }

    func testDiscoveryCancellationIsReportedAndClosesOnce() async throws {
        let transport = BlockingCompatibleTransport()
        let provider = OpenAICompatibleProvider(
            transport: transport,
            resolver: CompatibleResolverStub(),
            access: CompatibleAccessSpy()
        )
        let operation = Task {
            try await provider.discoverModels(
                at: compatibleHop(), requiresCredential: true
            )
        }
        await transport.waitUntilOpened()
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .cancelled)
        }
        await transport.waitUntilCancelled()
        let cancellationCount = await transport.count()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testCompatibleBasePathTrailingSlashAndQueryAreReplaced() async throws {
        for (url, expectedPath) in [
            ("https://example.invalid/v1/", "/v1/chat/completions"),
            ("https://example.invalid/v1?tenant=synthetic", "/v1/chat/completions")
        ] {
            let transport = CompatibleTransportSpy([.events([
                .head(HTTPResponseHead(status: 200, location: nil)),
                .body(Data("data: [DONE]\n\n".utf8)),
                .complete
            ])])
            let provider = OpenAICompatibleProvider(
                transport: transport,
                resolver: CompatibleResolverStub(),
                access: CompatibleAccessSpy()
            )
            let stream = try await provider.generate(
                compatibleRequest(),
                at: compatibleHop(url: URL(string: url)!)
            )
            _ = try await stream.compatibleCollect()
            let requests = await transport.captured()
            let wire = String(
                decoding: try XCTUnwrap(requests.compatibleOnly),
                as: UTF8.self
            )
            XCTAssertTrue(wire.hasPrefix("POST \(expectedPath) HTTP/1.1"))
        }
    }

    func testConnectionEstablishesAndClosesWithoutSendingBytes() async throws {
        let connection = CompatibleConnectionSpy()
        let factory = CompatibleConnectionFactorySpy(connection: connection)
        let provider = OpenAICompatibleProvider(
            transport: CompatibleTransportSpy([]),
            resolver: CompatibleResolverStub(),
            access: CompatibleAccessSpy(),
            diagnostics: CompatibleDiagnosticSpy(),
            connectionFactory: factory
        )
        try await provider.testConnection(at: compatibleHop())
        let counts = await connection.counts()
        let descriptors = await factory.captured()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.numericHost, "93.184.216.34")
        XCTAssertEqual(descriptors.first?.tlsServerName, "example.invalid")
    }

    func testBlockedConnectionStartReleasesAccessAndCancellationClosesOnce()
        async throws {
        let connection = BlockingInspectionConnection()
        let factory = CompatibleConnectionFactorySpy(connection: connection)
        let access = SerialCompatibleAccessSpy()
        let provider = OpenAICompatibleProvider(
            transport: CompatibleTransportSpy([]),
            resolver: CompatibleResolverStub(),
            access: access,
            diagnostics: CompatibleDiagnosticSpy(),
            connectionFactory: factory
        )
        let operation = Task {
            try await provider.testConnection(at: compatibleHop())
        }
        await connection.waitUntilStarted()

        let descriptorRead = expectation(description: "access lock released")
        Task {
            _ = try await access.accessDescriptor(ProviderConfigurationID())
            descriptorRead.fulfill()
        }
        await fulfillment(of: [descriptorRead], timeout: 1)

        operation.cancel()
        do {
            try await operation.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .cancelled)
        }
        let cancellationCount = await connection.cancelCount()
        XCTAssertEqual(cancellationCount, 1)
    }
}

private func compatibleHop(
    url: URL = URL(string: "https://example.invalid/v1")!
) throws -> RedirectAcceptedHop {
    let endpoint = try ProviderOriginParser.parse(
        url
    )
    let address = try IPAddress("93.184.216.34")
    let snapshot = ProviderDestinationSnapshot.mintAfterResolution(
        configurationID: ProviderConfigurationID(),
        privacyClass: .cloud,
        configurationRevision: 1,
        confirmationRevision: 1,
        origin: endpoint.origin,
        resolutionFingerprint: [address.fingerprint],
        protocolKind: .openAICompatible,
        model: "model"
    )
    return RedirectAcceptedHop(
        endpoint: endpoint,
        snapshot: snapshot,
        numericAddress: address
    )
}

private func compatibleRequest() -> TranslationRequest {
    TranslationRequest(
        instruction: "instruction",
        userContent: "selected-text",
        model: "model",
        timeouts: TranslationTimeoutPolicy(
            connection: .seconds(1),
            firstToken: .seconds(1),
            streamIdle: .seconds(1)
        ),
        requestID: TranslationRequestID()
    )
}

private extension AsyncThrowingStream where Failure == Error {
    func compatibleCollect() async throws -> [Element] {
        var output: [Element] = []
        for try await element in self { output.append(element) }
        return output
    }
}

private extension Array {
    var compatibleOnly: Element? { count == 1 ? self[0] : nil }
}
