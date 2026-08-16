import Foundation
import PrivacyStorage
import SharedSupport

private struct CompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let stream: Bool
}

private struct CompatibleModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct NoOpCompatibleDiagnosticReporter: ProviderDiagnosticReporting {
    func record(_ event: ProviderDiagnosticEvent) async {}
}

package struct OpenAICompatibleProvider: Sendable {
    private static let maximumDiscoveryBodyBytes = 1_048_576
    private static let connectionInspectionTimeout = Duration.seconds(10)

    private let transport: any ProviderTransporting
    private let redirecting: RedirectingTransport
    private let access: any ProviderAccess
    private let diagnostics: any ProviderDiagnosticReporting
    private let connectionFactory: any ProviderConnectionFactory

    package init(
        transport: any ProviderTransporting,
        resolver: any AddressResolving,
        access: any ProviderAccess
    ) {
        self.init(
            transport: transport,
            resolver: resolver,
            access: access,
            diagnostics: NoOpCompatibleDiagnosticReporter(),
            connectionFactory: NetworkConnectionFactory()
        )
    }

    package init(
        transport: any ProviderTransporting,
        resolver: any AddressResolving,
        access: any ProviderAccess,
        diagnostics: any ProviderDiagnosticReporting,
        connectionFactory: any ProviderConnectionFactory = NetworkConnectionFactory()
    ) {
        self.transport = transport
        redirecting = RedirectingTransport(resolver: resolver)
        self.access = access
        self.diagnostics = diagnostics
        self.connectionFactory = connectionFactory
    }

    package func discoverModels(
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool
    ) async throws -> [String] {
        let response = try await redirecting.open(
            initial: initial.appendingCompatiblePath(OpenAICompatibleAPIPath.models)
        ) { hop in
            try await open(
                hop: hop,
                method: "GET",
                body: Data(),
                requiresCredential: requiresCredential
            )
        }
        var body = Data()
        var sawFinal = false
        var sawComplete = false
        do {
            for try await event in response.events {
                try Task.checkCancellation()
                switch event {
                case .head(let head):
                    guard !sawFinal, !sawComplete else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    if (100..<200).contains(head.status) { continue }
                    if let failure = Self.discoveryFailure(for: head.status) {
                        throw failure
                    }
                    sawFinal = true
                case .body(let bytes):
                    let (newBodyCount, overflow) = body.count.addingReportingOverflow(
                        bytes.count
                    )
                    guard sawFinal, !sawComplete, !overflow,
                          newBodyCount <= Self.maximumDiscoveryBodyBytes else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    body.append(bytes)
                case .complete:
                    guard sawFinal, !sawComplete else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    sawComplete = true
                }
            }
            try Task.checkCancellation()
        } catch {
            await response.cancel()
            if Task.isCancelled { throw SanitizedFailure.cancelled }
            throw Self.sanitize(error)
        }
        guard sawFinal, sawComplete else {
            throw SanitizedFailure.providerProtocolFailure
        }
        let decoded: CompatibleModelsResponse
        do {
            decoded = try JSONDecoder().decode(CompatibleModelsResponse.self, from: body)
        } catch {
            throw SanitizedFailure.providerProtocolFailure
        }
        let names = Set(decoded.data.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }).sorted()
        guard !names.isEmpty else { throw SanitizedFailure.modelUnavailable }
        return names
    }

    package func generate(
        _ request: TranslationRequest,
        at initial: RedirectAcceptedHop,
        requiresCredential: Bool = true
    ) async throws -> AsyncThrowingStream<TranslationChunk, Error> {
        guard !request.model.isEmpty else { throw SanitizedFailure.modelUnavailable }
        let body: Data
        do {
            body = try JSONEncoder().encode(CompletionRequest(
                model: request.model,
                messages: [
                    .init(role: "system", content: request.instruction),
                    .init(role: "user", content: request.userContent)
                ],
                stream: true
            ))
        } catch {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        let response = try await redirecting.open(
            initial: initial.appendingCompatiblePath(
                OpenAICompatibleAPIPath.chatCompletions
            )
        ) { hop in
            try await open(
                hop: hop,
                method: "POST",
                body: body,
                requiresCredential: requiresCredential
            )
        }
        let channel = CompatibleChunkChannel()
        let owner = CompatibleStreamOwner(
            response: response,
            channel: channel,
            diagnostics: diagnostics,
            privacyClass: initial.snapshot.privacyClass
        )
        await channel.installCancellation {
            Task { await owner.cancel() }
        }
        Task { await owner.run() }
        let lifetime = CompatibleStreamLifetime {
            Task { await channel.cancel() }
        }
        return AsyncThrowingStream(unfolding: {
            _ = lifetime
            return try await channel.next()
        })
    }

    package func testConnection(at initial: RedirectAcceptedHop) async throws {
        let connection: any ProviderNetworkConnection = try await access
            .withValidatedDestination(initial.snapshot) {
            let host = initial.endpoint.origin.host
            let identityHost = String(host.split(
                separator: "%",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0])
            let descriptor = ProviderConnectionDescriptor(
                numericHost: initial.numericAddress.presentation,
                port: initial.endpoint.origin.effectivePort,
                tlsServerName: initial.endpoint.origin.scheme == "https"
                    ? identityHost
                    : nil,
                interfaceScopeID: initial.numericAddress.scopeID == 0
                    ? nil
                    : initial.numericAddress.scopeID
            )
            do {
                return try await connectionFactory.makeConnection(
                    descriptor: descriptor
                )
            } catch {
                throw Self.sanitizeConnection(error)
            }
        }
        let owner = CompatibleConnectionInspectionOwner(connection: connection)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await owner.start()
                    } onCancel: {
                        Task { await owner.close() }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: Self.connectionInspectionTimeout)
                    throw SanitizedFailure.connectionTimeout
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            await owner.close()
        } catch {
            await owner.close()
            if Task.isCancelled { throw SanitizedFailure.cancelled }
            throw Self.sanitizeConnection(error)
        }
    }

    private actor CompatibleConnectionInspectionOwner {
        private let connection: any ProviderNetworkConnection
        private var closed = false

        init(connection: any ProviderNetworkConnection) {
            self.connection = connection
        }

        func start() async throws {
            do {
                try await connection.start()
            } catch {
                throw OpenAICompatibleProvider.sanitizeConnection(error)
            }
        }

        func close() async {
            guard !closed else { return }
            closed = true
            await connection.cancel()
        }
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

    fileprivate static func sanitize(_ error: Error) -> SanitizedFailure {
        if let failure = error as? SanitizedFailure { return failure }
        if error is RedirectFailure { return .destinationReconfirmationRequired }
        if error is CancellationError { return .cancelled }
        return .providerProtocolFailure
    }

    private static func sanitizeConnection(_ error: Error) -> SanitizedFailure {
        if let failure = error as? SanitizedFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .connectionTimeout
    }

    private static func discoveryFailure(for status: Int) -> SanitizedFailure? {
        switch status {
        case 200: return nil
        case 401, 403: return .invalidCredential
        case 404, 405, 501: return .modelUnavailable
        default: return .providerProtocolFailure
        }
    }

    fileprivate static func outcome(
        _ failure: SanitizedFailure
    ) -> ProviderOutcomeCategory {
        switch failure {
        case .cancelled: return .cancelled
        case .connectionTimeout, .firstTokenTimeout, .streamIdleTimeout: return .timedOut
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

private final class CompatibleStreamLifetime: @unchecked Sendable {
    private let cancellation: @Sendable () -> Void

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    deinit { cancellation() }
}

private actor CompatibleChunkChannel {
    private enum State {
        case open
        case finished
        case failed(SanitizedFailure)
    }

    private var state = State.open
    private var queued: [TranslationChunk] = []
    private var waiters: [UUID: CheckedContinuation<TranslationChunk?, Error>] = [:]
    private var cancellationOperation: (@Sendable () -> Void)?

    func installCancellation(
        _ operation: @escaping @Sendable () -> Void
    ) {
        cancellationOperation = operation
    }

    func next() async throws -> TranslationChunk? {
        if Task.isCancelled {
            transitionToCancelled()
            throw SanitizedFailure.cancelled
        }
        if !queued.isEmpty { return queued.removeFirst() }
        switch state {
        case .finished:
            return nil
        case .failed(let failure):
            throw failure
        case .open:
            break
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    transitionToCancelled()
                    continuation.resume(throwing: SanitizedFailure.cancelled)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    @discardableResult
    func yield(_ chunk: TranslationChunk) -> Bool {
        guard case .open = state else { return false }
        if let (id, waiter) = waiters.first {
            waiters.removeValue(forKey: id)
            waiter.resume(returning: chunk)
        } else {
            queued.append(chunk)
        }
        return true
    }

    @discardableResult
    func finish() -> Bool {
        guard case .open = state else { return false }
        state = .finished
        cancellationOperation = nil
        for waiter in waiters.values { waiter.resume(returning: nil) }
        waiters.removeAll()
        return true
    }

    @discardableResult
    func fail(_ failure: SanitizedFailure) -> Bool {
        guard case .open = state else { return false }
        state = .failed(failure)
        cancellationOperation = nil
        queued.removeAll(keepingCapacity: false)
        for waiter in waiters.values { waiter.resume(throwing: failure) }
        waiters.removeAll()
        return true
    }

    func cancel() {
        transitionToCancelled()
    }

    private func cancelWaiter(_ id: UUID) {
        guard waiters[id] != nil else {
            if case .open = state { transitionToCancelled() }
            return
        }
        transitionToCancelled()
    }

    private func transitionToCancelled() {
        guard case .open = state else { return }
        state = .failed(.cancelled)
        queued.removeAll(keepingCapacity: false)
        for waiter in waiters.values {
            waiter.resume(throwing: SanitizedFailure.cancelled)
        }
        waiters.removeAll()
        let operation = cancellationOperation
        cancellationOperation = nil
        operation?()
    }
}

private actor CompatibleStreamOwner {
    private let response: ProviderTransportResponse
    private let channel: CompatibleChunkChannel
    private let diagnostics: any ProviderDiagnosticReporting
    private let privacyClass: DestinationPrivacyClass
    private let started = ContinuousClock.now
    private var cancellationCleanupStarted = false

    init(
        response: ProviderTransportResponse,
        channel: CompatibleChunkChannel,
        diagnostics: any ProviderDiagnosticReporting,
        privacyClass: DestinationPrivacyClass
    ) {
        self.response = response
        self.channel = channel
        self.diagnostics = diagnostics
        self.privacyClass = privacyClass
    }

    func run() async {
        var decoder = ServerSentEventDecoder()
        var sawFinal = false
        var sawComplete = false
        do {
            for try await event in response.events {
                switch event {
                case .head(let head):
                    guard !sawFinal, !sawComplete else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    if (100..<200).contains(head.status) { continue }
                    if head.status == 401 || head.status == 403 {
                        throw SanitizedFailure.invalidCredential
                    }
                    guard head.status == 200 else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    sawFinal = true
                    guard await channel.yield(.connected) else { return }
                case .body(let body):
                    guard sawFinal, !sawComplete else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    for chunk in try decoder.feed(body) {
                        guard await channel.yield(chunk) else { return }
                    }
                case .complete:
                    guard sawFinal, !sawComplete else {
                        throw SanitizedFailure.providerProtocolFailure
                    }
                    for chunk in try decoder.finish() {
                        guard await channel.yield(chunk) else { return }
                    }
                    sawComplete = true
                }
            }
            guard sawComplete else { throw SanitizedFailure.providerProtocolFailure }
            await finishSuccessfully()
        } catch {
            await finish(throwing: OpenAICompatibleProvider.sanitize(error))
        }
    }

    func cancel() async {
        guard !cancellationCleanupStarted else { return }
        cancellationCleanupStarted = true
        await response.cancel()
        await record(.cancelled)
    }

    private func finishSuccessfully() async {
        guard await channel.finish() else { return }
        await record(.succeeded)
    }

    private func finish(throwing failure: SanitizedFailure) async {
        guard await channel.fail(failure) else { return }
        await response.cancel()
        await record(OpenAICompatibleProvider.outcome(failure))
    }

    private func record(_ outcome: ProviderOutcomeCategory) async {
        await diagnostics.record(ProviderDiagnosticEvent(
            providerClass: privacyClass,
            outcomeCategory: outcome,
            durationMilliseconds: OpenAICompatibleProvider.milliseconds(
                started.duration(to: .now)
            )
        ))
    }
}

private extension RedirectAcceptedHop {
    func appendingCompatiblePath(_ component: String) -> RedirectAcceptedHop {
        let basePath = endpoint.pathAndQuery.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        let trimmed = basePath.hasSuffix("/")
            ? String(basePath.dropLast())
            : String(basePath)
        let path = (trimmed.isEmpty ? "" : trimmed) + "/" + component
        return RedirectAcceptedHop(
            endpoint: ParsedProviderEndpoint(
                origin: endpoint.origin,
                pathAndQuery: path
            ),
            snapshot: snapshot,
            numericAddress: numericAddress
        )
    }
}
