import Foundation
import SharedSupport

package struct ProviderTransportResponse: Sendable {
    package let events: AsyncThrowingStream<HTTPResponseEvent, Error>
    private let cancelOperation: @Sendable () async -> Void

    package init(
        events: AsyncThrowingStream<HTTPResponseEvent, Error>,
        cancelOperation: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.cancelOperation = cancelOperation
    }

    package func cancel() async {
        await cancelOperation()
    }
}

package protocol ProviderTransporting: Sendable {
    func open(
        _ request: ProviderTransportRequest
    ) async throws -> ProviderTransportResponse
}

package struct PinnedHTTPTransport: ProviderTransporting {
    private let factory: any ProviderConnectionFactory

    package init(factory: any ProviderConnectionFactory = NetworkConnectionFactory()) {
        self.factory = factory
    }

    package func open(
        _ request: ProviderTransportRequest
    ) async throws -> ProviderTransportResponse {
        let requestBytes = try request.encodedBytes()
        let identityHost = String(request.endpoint.origin.host.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0])
        let descriptor = ProviderConnectionDescriptor(
            numericHost: request.numericAddress.presentation,
            port: request.endpoint.origin.effectivePort,
            tlsServerName: request.endpoint.origin.scheme == "https"
                ? identityHost
                : nil,
            interfaceScopeID: request.numericAddress.scopeID == 0
                ? nil
                : request.numericAddress.scopeID
        )

        let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
        let owner = PinnedRequestOwner(
            factory: factory,
            descriptor: descriptor,
            requestBytes: requestBytes,
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { @Sendable _ in
            Task { await owner.cancel() }
        }
        Task { await owner.run() }

        return ProviderTransportResponse(
            events: pair.stream,
            cancelOperation: { await owner.cancel() }
        )
    }
}

private actor PinnedRequestOwner {
    private let factory: any ProviderConnectionFactory
    private let descriptor: ProviderConnectionDescriptor
    private let requestBytes: Data
    private let continuation: AsyncThrowingStream<HTTPResponseEvent, Error>.Continuation

    private var connection: (any ProviderNetworkConnection)?
    private var generation: UInt64 = 1
    private var terminal = false
    private var connectionClosed = false

    init(
        factory: any ProviderConnectionFactory,
        descriptor: ProviderConnectionDescriptor,
        requestBytes: Data,
        continuation: AsyncThrowingStream<HTTPResponseEvent, Error>.Continuation
    ) {
        self.factory = factory
        self.descriptor = descriptor
        self.requestBytes = requestBytes
        self.continuation = continuation
    }

    func run() async {
        let activeGeneration = generation
        do {
            let created = try await factory.makeConnection(descriptor: descriptor)
            connection = created
            guard isActive(activeGeneration) else {
                await closeConnectionOnce()
                return
            }

            try await created.start()
            guard isActive(activeGeneration) else { return }
            try await created.send(requestBytes)
            guard isActive(activeGeneration) else { return }

            var parser = HTTPResponseParser()
            while isActive(activeGeneration) {
                let read = try await created.receive()
                guard isActive(activeGeneration) else { return }

                if !read.bytes.isEmpty {
                    for event in try parser.feed(read.bytes) {
                        guard isActive(activeGeneration) else { return }
                        continuation.yield(event)
                    }
                }

                if parser.isComplete {
                    await finishSuccessfully(generation: activeGeneration)
                    return
                }
                if read.isComplete {
                    for event in try parser.finish() {
                        guard isActive(activeGeneration) else { return }
                        continuation.yield(event)
                    }
                    await finishSuccessfully(generation: activeGeneration)
                    return
                }
                guard !read.bytes.isEmpty else {
                    throw HTTPParserFailure.protocolViolation
                }
            }
        } catch {
            await finish(
                throwing: Self.sanitize(error),
                generation: activeGeneration
            )
        }
    }

    func cancel() async {
        guard !terminal else { return }
        terminal = true
        generation &+= 1
        await closeConnectionOnce()
        continuation.finish(throwing: SanitizedFailure.cancelled)
    }

    private func isActive(_ candidate: UInt64) -> Bool {
        !terminal && generation == candidate
    }

    private func finishSuccessfully(generation candidate: UInt64) async {
        guard isActive(candidate) else { return }
        terminal = true
        generation &+= 1
        await closeConnectionOnce()
        continuation.finish()
    }

    private func finish(
        throwing error: SanitizedFailure,
        generation candidate: UInt64
    ) async {
        guard isActive(candidate) else { return }
        terminal = true
        generation &+= 1
        await closeConnectionOnce()
        continuation.finish(throwing: error)
    }

    private func closeConnectionOnce() async {
        guard !connectionClosed, let connection else { return }
        connectionClosed = true
        await connection.cancel()
    }

    private static func sanitize(_ error: Error) -> SanitizedFailure {
        if let failure = error as? SanitizedFailure { return failure }
        if error is HTTPParserFailure { return .providerProtocolFailure }
        if error is CancellationError { return .cancelled }
        return .connectionTimeout
    }
}
