import Foundation
import PrivacyStorage
import SharedSupport
import XCTest

@testable import ModelProviders
@testable import PrivacyStorage

private actor OllamaResolverStub: AddressResolving {
    func resolve(_ host: String) async throws -> Set<IPAddress> {
        throw AddressFailure.unresolved
    }
}

private actor OllamaAccessSpy: ProviderAccess {
    private(set) var leaseCalls = 0

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
        leaseCalls += 1
        let value = CredentialHeaderValue(storage: Data("synthetic-token".utf8))
        let lease = ProviderCredentialLease(credential: value)
        return try await operation(lease)
    }

    func withValidatedDestination<Result: Sendable>(
        _ expected: ProviderDestinationSnapshot,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await operation()
    }

    func count() -> Int { leaseCalls }
}

private actor OllamaTransportSpy: ProviderTransporting {
    enum Outcome: Sendable {
        case response(status: Int, body: Data)
        case events([HTTPResponseEvent])
        case failure(SanitizedFailure)
    }

    private var outcomes: [Outcome]
    private var encodedRequests: [Data] = []

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

    func open(
        _ request: ProviderTransportRequest
    ) async throws -> ProviderTransportResponse {
        encodedRequests.append(try request.encodedBytes())
        guard !outcomes.isEmpty else { throw SanitizedFailure.providerProtocolFailure }
        switch outcomes.removeFirst() {
        case .failure(let failure):
            throw failure
        case .response(let status, let body):
            let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
            pair.continuation.yield(.head(HTTPResponseHead(status: status, location: nil)))
            if !body.isEmpty { pair.continuation.yield(.body(body)) }
            pair.continuation.yield(.complete)
            pair.continuation.finish()
            return ProviderTransportResponse(events: pair.stream, cancelOperation: {})
        case .events(let events):
            let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
            for event in events { pair.continuation.yield(event) }
            pair.continuation.finish()
            return ProviderTransportResponse(events: pair.stream, cancelOperation: {})
        }
    }

    func requests() -> [Data] { encodedRequests }
}

private actor BlockingOllamaTransport: ProviderTransporting {
    private var opened = false
    private var cancelled = 0
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func open(
        _ request: ProviderTransportRequest
    ) async throws -> ProviderTransportResponse {
        opened = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
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
        if cancelled > 0 { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func recordCancel() {
        cancelled += 1
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func cancelCount() -> Int { cancelled }
}

final class OllamaProviderTests: XCTestCase {
    func testInformationalHeadsPrecedeOneFinalResponse() async throws {
        let tagsBody = try JSONSerialization.data(withJSONObject: [
            "models": [["name": "model"]]
        ])
        let discoveryTransport = OllamaTransportSpy([.events([
            .head(HTTPResponseHead(status: 100, location: nil)),
            .head(HTTPResponseHead(status: 103, location: nil)),
            .head(HTTPResponseHead(status: 200, location: nil)),
            .body(tagsBody),
            .complete
        ])])
        let access = OllamaAccessSpy()
        let discovery = OllamaProvider(
            transport: discoveryTransport,
            resolver: OllamaResolverStub(),
            access: access
        )
        let discovered = try await discovery.discoverModels(
            at: ollamaHop(), requiresCredential: false
        )
        XCTAssertEqual(discovered, ["model"])

        let chatBody = Data((
            "{\"message\":{\"content\":\"ok\"},\"done\":false}\n"
                + "{\"message\":{\"content\":\"\"},\"done\":true}\n"
        ).utf8)
        let generationTransport = OllamaTransportSpy([.events([
            .head(HTTPResponseHead(status: 103, location: nil)),
            .head(HTTPResponseHead(status: 200, location: nil)),
            .body(chatBody),
            .complete
        ])])
        let generation = OllamaProvider(
            transport: generationTransport,
            resolver: OllamaResolverStub(),
            access: access
        )
        let stream = try await generation.generate(
            ollamaRequest(), at: ollamaHop(), requiresCredential: false
        )
        let chunks = try await stream.ollamaCollect()
        XCTAssertEqual(chunks, [.connected, .content("ok"), .done])
    }

    func testCancellationClosesUnderlyingRequestExactlyOnce() async throws {
        let transport = BlockingOllamaTransport()
        let provider = OllamaProvider(
            transport: transport,
            resolver: OllamaResolverStub(),
            access: OllamaAccessSpy()
        )
        let stream = try await provider.generate(
            ollamaRequest(), at: try ollamaHop(), requiresCredential: false
        )
        let collector = Task { try await stream.ollamaCollect() }
        await transport.waitUntilOpened()
        collector.cancel()
        _ = try? await collector.value
        await transport.waitUntilCancelled()
        let cancellations = await transport.cancelCount()
        XCTAssertEqual(cancellations, 1)
    }

    func testTagsProvidesHealthAndSortedModelNamesWithoutBody() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "models": [
                ["name": "z-model"],
                ["name": " a-model "],
                ["name": "z-model"],
                ["name": "   "]
            ]
        ])
        let transport = OllamaTransportSpy([.response(status: 200, body: body)])
        let access = OllamaAccessSpy()
        let models = try await OllamaProvider(
            transport: transport,
            resolver: OllamaResolverStub(),
            access: access
        ).discoverModels(at: try ollamaHop(model: ""), requiresCredential: false)
        XCTAssertEqual(models, ["a-model", "z-model"])
        let capturedRequests = await transport.requests()
        let request = try XCTUnwrap(capturedRequests.only)
        let wire = String(decoding: request, as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("GET /api/tags HTTP/1.1\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"))
        let leaseCalls = await access.count()
        XCTAssertEqual(leaseCalls, 0)
    }

    func testChatSeparatesMessagesAndAppliesCredentialInsideAcceptedHop() async throws {
        let streamBody = Data((
            "{\"message\":{\"content\":\"ok\"},\"done\":false}\n"
                + "{\"message\":{\"content\":\"\"},\"done\":true}\n"
        ).utf8)
        let transport = OllamaTransportSpy([.response(status: 200, body: streamBody)])
        let access = OllamaAccessSpy()
        let provider = OllamaProvider(
            transport: transport,
            resolver: OllamaResolverStub(),
            access: access
        )
        let stream = try await provider.generate(
            ollamaRequest(),
            at: try ollamaHop(),
            requiresCredential: true
        )
        let chunks = try await stream.ollamaCollect()
        XCTAssertEqual(chunks, [.connected, .content("ok"), .done])
        let leaseCalls = await access.count()
        XCTAssertEqual(leaseCalls, 1)

        let capturedRequests = await transport.requests()
        let wire = try XCTUnwrap(capturedRequests.only)
        let separator = Data("\r\n\r\n".utf8)
        let range = try XCTUnwrap(wire.range(of: separator))
        let head = String(decoding: wire[..<range.lowerBound], as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("POST /api/chat HTTP/1.1"))
        XCTAssertTrue(head.lowercased().contains("authorization: bearer synthetic-token"))
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

    func testClosedFailureMappingDiscardsProviderBody() async throws {
        let access = OllamaAccessSpy()
        let unavailable = OllamaProvider(
            transport: OllamaTransportSpy([.failure(.connectionTimeout)]),
            resolver: OllamaResolverStub(),
            access: access
        )
        do {
            _ = try await unavailable.discoverModels(
                at: try ollamaHop(),
                requiresCredential: false
            )
            XCTFail("Expected unavailable")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .ollamaUnavailable)
        }

        let emptyBody = try JSONSerialization.data(withJSONObject: ["models": []])
        let empty = OllamaProvider(
            transport: OllamaTransportSpy([.response(status: 200, body: emptyBody)]),
            resolver: OllamaResolverStub(),
            access: access
        )
        do {
            _ = try await empty.discoverModels(at: try ollamaHop(), requiresCredential: false)
            XCTFail("Expected model unavailable")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .modelUnavailable)
        }

        let marker = "SYNTHETIC_BODY_MARKER"
        let missing = OllamaProvider(
            transport: OllamaTransportSpy([
                .response(status: 404, body: Data(marker.utf8))
            ]),
            resolver: OllamaResolverStub(),
            access: access
        )
        let stream = try await missing.generate(
            ollamaRequest(), at: try ollamaHop(), requiresCredential: false
        )
        do {
            _ = try await stream.ollamaCollect()
            XCTFail("Expected missing model")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .modelUnavailable)
            XCTAssertFalse(String(describing: error).contains(marker))
        }
    }
}

private func ollamaHop(model: String = "model") throws -> RedirectAcceptedHop {
    let endpoint = try ProviderOriginParser.parse(
        URL(string: "http://127.0.0.1:11434")!
    )
    let address = try IPAddress("127.0.0.1")
    let snapshot = ProviderDestinationSnapshot.mintAfterResolution(
        configurationID: ProviderConfigurationID(),
        privacyClass: .localOnDevice,
        configurationRevision: 1,
        confirmationRevision: 0,
        origin: endpoint.origin,
        resolutionFingerprint: [address.fingerprint],
        protocolKind: .ollamaNative,
        model: model
    )
    return RedirectAcceptedHop(
        endpoint: endpoint,
        snapshot: snapshot,
        numericAddress: address
    )
}

private func ollamaRequest() -> TranslationRequest {
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
    func ollamaCollect() async throws -> [Element] {
        var output: [Element] = []
        for try await element in self { output.append(element) }
        return output
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
