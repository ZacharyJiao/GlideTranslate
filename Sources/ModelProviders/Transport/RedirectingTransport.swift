import Foundation
import SharedSupport

package struct RedirectAcceptedHop: Sendable {
    package let endpoint: ParsedProviderEndpoint
    package let snapshot: ProviderDestinationSnapshot
    package let numericAddress: IPAddress

    package init(
        endpoint: ParsedProviderEndpoint,
        snapshot: ProviderDestinationSnapshot,
        numericAddress: IPAddress
    ) {
        self.endpoint = endpoint
        self.snapshot = snapshot
        self.numericAddress = numericAddress
    }
}

package struct RedirectingTransport: Sendable {
    private let resolver: any AddressResolving

    package init(resolver: any AddressResolving) {
        self.resolver = resolver
    }

    package func open(
        initial: RedirectAcceptedHop,
        openAcceptedHop: @escaping @Sendable (
            RedirectAcceptedHop
        ) async throws -> ProviderTransportResponse
    ) async throws -> ProviderTransportResponse {
        let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
        let owner = RedirectRequestOwner(
            resolver: resolver,
            initial: initial,
            openAcceptedHop: openAcceptedHop,
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

private struct RedirectHopKey: Hashable, Sendable {
    let origin: ProviderOrigin
    let pathAndQuery: String
}

private actor RedirectRequestOwner {
    private static let maximumRedirects = 5

    private let resolver: any AddressResolving
    private let openAcceptedHop: @Sendable (
        RedirectAcceptedHop
    ) async throws -> ProviderTransportResponse
    private let continuation: AsyncThrowingStream<HTTPResponseEvent, Error>.Continuation

    private var current: RedirectAcceptedHop
    private var currentResponse: ProviderTransportResponse?
    private var visited: Set<RedirectHopKey>
    private var acceptedRedirects = 0
    private var terminal = false

    init(
        resolver: any AddressResolving,
        initial: RedirectAcceptedHop,
        openAcceptedHop: @escaping @Sendable (
            RedirectAcceptedHop
        ) async throws -> ProviderTransportResponse,
        continuation: AsyncThrowingStream<HTTPResponseEvent, Error>.Continuation
    ) {
        self.resolver = resolver
        current = initial
        self.openAcceptedHop = openAcceptedHop
        self.continuation = continuation
        visited = [RedirectHopKey(
            origin: initial.endpoint.origin,
            pathAndQuery: initial.endpoint.pathAndQuery
        )]
    }

    func run() async {
        do {
            while !terminal {
                let response = try await openAcceptedHop(current)
                guard !terminal else {
                    await response.cancel()
                    return
                }
                currentResponse = response
                var followed = false
                for try await event in response.events {
                    guard !terminal else { return }
                    switch event {
                    case .head(let head) where (300..<400).contains(head.status):
                        await response.cancel()
                        currentResponse = nil
                        current = try await acceptedRedirect(head)
                        followed = true
                    case .head, .body, .complete:
                        continuation.yield(event)
                    }
                    if followed { break }
                }
                currentResponse = nil
                if followed { continue }
                finish()
                return
            }
        } catch {
            await finish(throwing: error)
        }
    }

    func cancel() async {
        guard !terminal else { return }
        terminal = true
        if let currentResponse { await currentResponse.cancel() }
        continuation.finish(throwing: SanitizedFailure.cancelled)
    }

    private func acceptedRedirect(
        _ head: HTTPResponseHead
    ) async throws -> RedirectAcceptedHop {
        let currentURL = try currentURL(for: current.endpoint)
        let decision = RedirectPolicy.decide(
            status: head.status,
            location: head.location,
            currentURL: currentURL,
            current: current.endpoint
        )
        guard case .follow(let endpoint) = decision else {
            if case .reject(let failure) = decision { throw failure }
            throw RedirectFailure.invalidLocation
        }

        let key = RedirectHopKey(
            origin: endpoint.origin,
            pathAndQuery: endpoint.pathAndQuery
        )
        guard !visited.contains(key) else { throw RedirectFailure.loop }
        guard acceptedRedirects < Self.maximumRedirects else {
            throw RedirectFailure.hopLimit
        }

        let addresses: Set<IPAddress>
        do {
            addresses = try await resolver.resolve(endpoint.origin.host)
        } catch {
            throw RedirectFailure.unresolvedDestination
        }
        let previous = current.snapshot
        let snapshot: ProviderDestinationSnapshot
        let numericAddress: IPAddress
        do {
            (snapshot, numericAddress) = try RedirectDestinationSnapshotMinter.mint(
                previous: previous,
                endpoint: endpoint,
                addresses: addresses
            )
        } catch RedirectDestinationEvidenceFailure.unresolved {
            throw RedirectFailure.unresolvedDestination
        } catch {
            throw RedirectFailure.destinationChanged
        }
        visited.insert(key)
        acceptedRedirects += 1
        return RedirectAcceptedHop(
            endpoint: endpoint,
            snapshot: snapshot,
            numericAddress: numericAddress
        )
    }

    private func currentURL(for endpoint: ParsedProviderEndpoint) throws -> URL {
        var components = URLComponents()
        components.scheme = endpoint.origin.scheme
        let host = endpoint.origin.host
        if host.contains(":") {
            let encoded = host.replacingOccurrences(of: "%", with: "%25")
            components.percentEncodedHost = "[\(encoded)]"
        } else {
            components.host = host
        }
        let defaultPort = endpoint.origin.scheme == "https" ? UInt16(443) : UInt16(80)
        if endpoint.origin.effectivePort != defaultPort {
            components.port = Int(endpoint.origin.effectivePort)
        }
        let fields = endpoint.pathAndQuery.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        components.percentEncodedPath = String(fields[0])
        if fields.count == 2 { components.percentEncodedQuery = String(fields[1]) }
        guard let url = components.url else { throw RedirectFailure.invalidLocation }
        return url
    }

    private func finish() {
        guard !terminal else { return }
        terminal = true
        continuation.finish()
    }

    private func finish(throwing error: Error) async {
        guard !terminal else { return }
        terminal = true
        if let currentResponse { await currentResponse.cancel() }
        continuation.finish(throwing: error)
    }
}
