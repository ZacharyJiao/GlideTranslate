import Foundation
import PrivacyStorage
import SharedSupport

private struct OllamaChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let stream: Bool
    let think: Bool
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct NoOpProviderDiagnosticReporter: ProviderDiagnosticReporting {
    func record(_ event: ProviderDiagnosticEvent) async {}
}

package struct OllamaProvider: Sendable {
    private static let maximumDiscoveryBodyBytes = 1_048_576

    private let transport: any ProviderTransporting
    private let redirecting: RedirectingTransport
    private let access: any ProviderAccess
    private let diagnostics: any ProviderDiagnosticReporting

    package init(
        transport: any ProviderTransporting,
        resolver: any AddressResolving,
        access: any ProviderAccess
    ) {
        self.init(
            transport: transport,
            resolver: resolver,
            access: access,
            diagnostics: NoOpProviderDiagnosticReporter()
        )
    }

    package init(
        transport: any ProviderTransporting,
        resolver: any AddressResolving,
        access: any ProviderAccess,
        diagnostics: any ProviderDiagnosticReporting
    ) {
        self.transport = transport
        redirecting = RedirectingTransport(resolver: resolver)
        self.access = access
        self.diagnostics = diagnostics
    }

    package func discoverModels(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> [String] {
        let started = ContinuousClock.now
        do {
            let response = try await redirecting.open(
                initial: initial.replacingPath(OllamaAPIPath.tags)
            ) { hop in
                try await open(
                    hop: hop,
                    method: "GET",
                    body: Data(),
                    requiresCredential: requiresCredential
                )
            }
            var body = Data()
            var sawSuccessHead = false
            var sawComplete = false
            do {
                for try await event in response.events {
                    switch event {
                    case .head(let head):
                        guard !sawSuccessHead, !sawComplete else {
                            throw SanitizedFailure.providerProtocolFailure
                        }
                        if (100..<200).contains(head.status) { continue }
                        guard head.status == 200 else {
                            throw SanitizedFailure.providerProtocolFailure
                        }
                        sawSuccessHead = true
                    case .body(let bytes):
                        guard sawSuccessHead, !sawComplete,
                              bytes.count <= Self.maximumDiscoveryBodyBytes - body.count else {
                            throw SanitizedFailure.providerProtocolFailure
                        }
                        body.append(bytes)
                    case .complete:
                        guard sawSuccessHead, !sawComplete else {
                            throw SanitizedFailure.providerProtocolFailure
                        }
                        sawComplete = true
                    }
                }
            } catch {
                await response.cancel()
                throw error
            }
            guard sawSuccessHead, sawComplete else {
                throw SanitizedFailure.providerProtocolFailure
            }
            let decoded: OllamaTagsResponse
            do {
                decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: body)
            } catch {
                throw SanitizedFailure.providerProtocolFailure
            }
            let models = Set(decoded.models.map { model in
                model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }).sorted()
            guard !models.isEmpty else { throw SanitizedFailure.modelUnavailable }
            await record(.succeeded, initial.snapshot.privacyClass, started)
            return models
        } catch {
            let failure = Self.sanitize(error)
            await record(Self.outcome(failure), initial.snapshot.privacyClass, started)
            throw failure
        }
    }

    package func testConnection(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws {
        do {
            _ = try await discoverModels(
                at: initial,
                requiresCredential: requiresCredential
            )
        } catch let failure as SanitizedFailure where failure == .modelUnavailable {
            return
        }
    }

    package func generate(
        _ request: TranslationRequest,
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> AsyncThrowingStream<TranslationChunk, Error> {
        guard !request.model.isEmpty else { throw SanitizedFailure.modelUnavailable }
        let body: Data
        do {
            body = try JSONEncoder().encode(OllamaChatRequest(
                model: request.model,
                messages: [
                    .init(role: "system", content: request.instruction),
                    .init(role: "user", content: request.userContent)
                ],
                stream: true,
                think: false
            ))
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        let response = try await redirecting.open(
            initial: initial.replacingPath(OllamaAPIPath.chat)
        ) { hop in
            try await open(
                hop: hop,
                method: "POST",
                body: body,
                requiresCredential: requiresCredential
            )
        }
        let pair = AsyncThrowingStream<TranslationChunk, Error>.makeStream()
        let owner = OllamaStreamOwner(
            response: response,
            continuation: pair.continuation,
            diagnostics: diagnostics,
            privacyClass: initial.snapshot.privacyClass
        )
        pair.continuation.onTermination = { @Sendable _ in
            Task { await owner.cancel() }
        }
        Task { await owner.run() }
        return pair.stream
    }

    private func open(
        hop: RedirectAcceptedHop,
        method: String,
        body: Data,
        requiresCredential: Bool
    ) async throws -> ProviderTransportResponse {
        if requiresCredential {
            return try await access.withCredentialLease(hop.snapshot) { lease in
                var request = try makeRequest(hop: hop, method: method, body: body)
                lease.apply(to: &request)
                return try await transport.open(request)
            }
        }
        return try await access.withValidatedDestination(hop.snapshot) {
            try await transport.open(
                try makeRequest(hop: hop, method: method, body: body)
            )
        }
    }

    private func makeRequest(
        hop: RedirectAcceptedHop,
        method: String,
        body: Data
    ) throws -> ProviderTransportRequest {
        var headers: [SanitizedHeaderName: SensitiveHeaderBytes] = [:]
        if !body.isEmpty {
            headers[try SanitizedHeaderName("Content-Type")] = try SensitiveHeaderBytes(
                copying: Data("application/json".utf8)
            )
        }
        return ProviderTransportRequest(
            method: method,
            endpoint: hop.endpoint,
            numericAddress: hop.numericAddress,
            headers: headers,
            body: SensitiveBodyBytes(copying: body)
        )
    }

    private func record(
        _ outcome: ProviderOutcomeCategory,
        _ privacyClass: DestinationPrivacyClass,
        _ started: ContinuousClock.Instant
    ) async {
        await diagnostics.record(ProviderDiagnosticEvent(
            providerClass: privacyClass,
            outcomeCategory: outcome,
            durationMilliseconds: Self.milliseconds(started.duration(to: .now))
        ))
    }

    fileprivate static func sanitize(_ error: Error) -> SanitizedFailure {
        if let failure = error as? SanitizedFailure {
            switch failure {
            case .connectionTimeout: return .ollamaUnavailable
            default: return failure
            }
        }
        if error is RedirectFailure { return .destinationReconfirmationRequired }
        if error is CancellationError { return .cancelled }
        return .providerProtocolFailure
    }

    fileprivate static func outcome(
        _ failure: SanitizedFailure
    ) -> ProviderOutcomeCategory {
        switch failure {
        case .cancelled: return .cancelled
        case .connectionTimeout, .firstTokenTimeout, .streamIdleTimeout: return .timedOut
        case .ollamaUnavailable, .modelUnavailable: return .unavailable
        default: return .protocolFailure
        }
    }

    fileprivate static func milliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let milliseconds = UInt64(seconds) * 1_000
        let fractional = max(components.attoseconds / 1_000_000_000_000_000, 0)
        return milliseconds &+ UInt64(fractional)
    }
}

private actor OllamaStreamOwner {
    private let response: ProviderTransportResponse
    private let continuation: AsyncThrowingStream<TranslationChunk, Error>.Continuation
    private let diagnostics: any ProviderDiagnosticReporting
    private let privacyClass: DestinationPrivacyClass
    private let started = ContinuousClock.now
    private var terminal = false

    init(
        response: ProviderTransportResponse,
        continuation: AsyncThrowingStream<TranslationChunk, Error>.Continuation,
        diagnostics: any ProviderDiagnosticReporting,
        privacyClass: DestinationPrivacyClass
    ) {
        self.response = response
        self.continuation = continuation
        self.diagnostics = diagnostics
        self.privacyClass = privacyClass
    }

    func run() async {
        var decoder = OllamaStreamDecoder()
        var sawHead = false
        var sawComplete = false
        do {
            for try await event in response.events {
                guard !terminal else { return }
                switch event {
                case .head(let head):
                    guard !sawHead else { throw SanitizedFailure.providerProtocolFailure }
                    if (100..<200).contains(head.status) { continue }
                    if head.status == 404 { throw SanitizedFailure.modelUnavailable }
                    guard head.status == 200 else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    sawHead = true
                    continuation.yield(.connected)
                case .body(let body):
                    guard sawHead, !sawComplete else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    for chunk in try decoder.feed(body) { continuation.yield(chunk) }
                case .complete:
                    guard sawHead, !sawComplete else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    for chunk in try decoder.finish() { continuation.yield(chunk) }
                    sawComplete = true
                }
            }
            guard sawComplete else { throw SanitizedFailure.providerProtocolFailure }
            await finishSuccessfully()
        } catch {
            await finish(throwing: OllamaProvider.sanitize(error))
        }
    }

    func cancel() async {
        guard !terminal else { return }
        terminal = true
        await response.cancel()
        await record(.cancelled)
        continuation.finish(throwing: SanitizedFailure.cancelled)
    }

    private func finishSuccessfully() async {
        guard !terminal else { return }
        terminal = true
        await record(.succeeded)
        continuation.finish()
    }

    private func finish(throwing failure: SanitizedFailure) async {
        guard !terminal else { return }
        terminal = true
        await response.cancel()
        await record(OllamaProvider.outcome(failure))
        continuation.finish(throwing: failure)
    }

    private func record(_ outcome: ProviderOutcomeCategory) async {
        await diagnostics.record(ProviderDiagnosticEvent(
            providerClass: privacyClass,
            outcomeCategory: outcome,
            durationMilliseconds: OllamaProvider.milliseconds(started.duration(to: .now))
        ))
    }
}

private extension RedirectAcceptedHop {
    func replacingPath(_ path: String) -> RedirectAcceptedHop {
        RedirectAcceptedHop(
            endpoint: ParsedProviderEndpoint(origin: endpoint.origin, pathAndQuery: path),
            snapshot: snapshot,
            numericAddress: numericAddress
        )
    }
}
