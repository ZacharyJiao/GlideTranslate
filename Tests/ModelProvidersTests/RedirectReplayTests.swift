import Foundation
import Darwin
import PrivacyStorage
import SharedSupport
import XCTest

@testable import ModelProviders

private actor RedirectSpyResolver: AddressResolving {
    private var rows: [Result<Set<IPAddress>, Error>]
    private(set) var calls = 0

    init(_ rows: [Result<Set<IPAddress>, Error>]) { self.rows = rows }

    func resolve(_ host: String) async throws -> Set<IPAddress> {
        calls += 1
        guard !rows.isEmpty else { throw AddressFailure.unresolved }
        return try rows.removeFirst().get()
    }

    func callCount() -> Int { calls }
}

private final class RedirectReplayCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0
    private var leases = 0
    private var reads = 0
    private var applies = 0
    private var bodies = 0

    func recordAcceptedHop() {
        lock.lock()
        opens += 1; leases += 1; reads += 1; applies += 1; bodies += 1
        lock.unlock()
    }

    func snapshot() -> (Int, Int, Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (opens, leases, reads, applies, bodies)
    }
}

final class RedirectReplayTests: XCTestCase {
    func testIPv6LiteralRedirectsReconstructCanonicalBaseURL() async throws {
        let scopeID = if_nametoindex("lo0")
        XCTAssertNotEqual(scopeID, 0)
        let rows: [(String, IPAddress, DestinationPrivacyClass)] = [
            ("http://[::1]/start", try IPAddress("::1"), .localOnDevice),
            (
                "http://[fe80::8%25\(scopeID)]:8080/start",
                try IPAddress("fe80::8%\(scopeID)"),
                .localNetwork
            )
        ]
        for (url, address, privacyClass) in rows {
            let fixture = try redirectFixture(
                url: url,
                address: address,
                privacyClass: privacyClass
            )
            let resolver = RedirectSpyResolver([.success([address])])
            let counts = RedirectReplayCounts()
            let response = try await RedirectingTransport(resolver: resolver).open(
                initial: fixture.hop
            ) { hop in
                counts.recordAcceptedHop()
                return counts.snapshot().0 == 1
                    ? syntheticResponse(status: 307, location: "/next")
                    : syntheticResponse(status: 200, body: "ok")
            }
            _ = try await response.events.redirectCollect()
            XCTAssertEqual(counts.snapshot().0, 2, url)
            let resolverCalls = await resolver.callCount()
            XCTAssertEqual(resolverCalls, 1, url)
        }
    }

    func testRejectedHopNeverInvokesSecondRequestBoundary() async throws {
        let rows: [(String, Set<IPAddress>, RedirectFailure)] = [
            ("https://other.invalid/next", [try IPAddress("93.184.216.34")], .originChanged),
            ("/next", [try IPAddress("10.0.0.8")], .destinationChanged),
            ("/next", [try IPAddress("0.0.0.0")], .unresolvedDestination)
        ]
        for (location, addresses, expected) in rows {
            let resolver = RedirectSpyResolver([.success(addresses)])
            let counts = RedirectReplayCounts()
            let fixture = try redirectFixture()
            let response = try await RedirectingTransport(resolver: resolver).open(
                initial: fixture.hop
            ) { hop in
                counts.recordAcceptedHop()
                return syntheticResponse(status: 307, location: location)
            }
            do {
                _ = try await response.events.redirectCollect()
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? RedirectFailure, expected)
            }
            XCTAssertEqual(counts.snapshot().0, 1)
            XCTAssertEqual(counts.snapshot().1, 1)
            XCTAssertEqual(counts.snapshot().2, 1)
            XCTAssertEqual(counts.snapshot().3, 1)
            XCTAssertEqual(counts.snapshot().4, 1)
        }
    }

    func testSameOriginRedirectRevalidatesThenRebuildsExactlyOnce() async throws {
        let address = try IPAddress("93.184.216.34")
        let resolver = RedirectSpyResolver([.success([address])])
        let counts = RedirectReplayCounts()
        let fixture = try redirectFixture()
        let response = try await RedirectingTransport(resolver: resolver).open(
            initial: fixture.hop
        ) { hop in
            counts.recordAcceptedHop()
            if counts.snapshot().0 == 1 {
                return syntheticResponse(status: 307, location: "/next")
            }
            XCTAssertEqual(hop.endpoint.pathAndQuery, "/next")
            XCTAssertEqual(hop.snapshot.resolutionFingerprint, [address.fingerprint])
            return syntheticResponse(status: 200, body: "ok")
        }
        let events = try await response.events.redirectCollect()
        XCTAssertEqual(events, [
            .head(HTTPResponseHead(status: 200, location: nil)),
            .body(Data("ok".utf8)),
            .complete
        ])
        let resolverCalls = await resolver.callCount()
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(counts.snapshot().0, 2)
    }

    func testLoopAndHopLimitStopBeforeAnotherRequestBoundary() async throws {
        let address = try IPAddress("93.184.216.34")
        let fixture = try redirectFixture()

        let loopResolver = RedirectSpyResolver([.success([address])])
        let loopCounts = RedirectReplayCounts()
        let loopResponse = try await RedirectingTransport(resolver: loopResolver).open(
            initial: fixture.hop
        ) { _ in
            loopCounts.recordAcceptedHop()
            return syntheticResponse(status: 307, location: "/start")
        }
        do {
            _ = try await loopResponse.events.redirectCollect()
            XCTFail("Expected loop")
        } catch {
            XCTAssertEqual(error as? RedirectFailure, .loop)
        }
        XCTAssertEqual(loopCounts.snapshot().0, 1)
        let loopResolverCalls = await loopResolver.callCount()
        XCTAssertEqual(loopResolverCalls, 0)

        let limitResolver = RedirectSpyResolver(
            (0..<5).map { _ in .success([address]) }
        )
        let limitCounts = RedirectReplayCounts()
        let limitResponse = try await RedirectingTransport(resolver: limitResolver).open(
            initial: fixture.hop
        ) { _ in
            limitCounts.recordAcceptedHop()
            return syntheticResponse(
                status: 308,
                location: "/hop-\(limitCounts.snapshot().0)"
            )
        }
        do {
            _ = try await limitResponse.events.redirectCollect()
            XCTFail("Expected hop limit")
        } catch {
            XCTAssertEqual(error as? RedirectFailure, .hopLimit)
        }
        XCTAssertEqual(limitCounts.snapshot().0, 6)
        let limitResolverCalls = await limitResolver.callCount()
        XCTAssertEqual(limitResolverCalls, 5)
    }
}

private struct RedirectFixture {
    let hop: RedirectAcceptedHop
}

private func redirectFixture(
    url: String = "https://example.invalid/start",
    address: IPAddress? = nil,
    privacyClass: DestinationPrivacyClass = .cloud
) throws -> RedirectFixture {
    let endpoint = try ProviderOriginParser.parse(
        URL(string: url)!
    )
    let address = try address ?? IPAddress("93.184.216.34")
    let snapshot = ProviderDestinationSnapshot.mintAfterResolution(
        configurationID: ProviderConfigurationID(),
        privacyClass: privacyClass,
        configurationRevision: 1,
        confirmationRevision: 1,
        origin: endpoint.origin,
        resolutionFingerprint: [address.fingerprint],
        protocolKind: .openAICompatible,
        model: "model"
    )
    return RedirectFixture(hop: RedirectAcceptedHop(
        endpoint: endpoint,
        snapshot: snapshot,
        numericAddress: address
    ))
}

private func syntheticResponse(
    status: Int,
    location: String? = nil,
    body: String? = nil
) -> ProviderTransportResponse {
    let pair = AsyncThrowingStream<HTTPResponseEvent, Error>.makeStream()
    pair.continuation.yield(.head(HTTPResponseHead(status: status, location: location)))
    if let body { pair.continuation.yield(.body(Data(body.utf8))) }
    pair.continuation.yield(.complete)
    pair.continuation.finish()
    return ProviderTransportResponse(events: pair.stream, cancelOperation: {})
}

private extension AsyncThrowingStream where Failure == Error {
    func redirectCollect() async throws -> [Element] {
        var output: [Element] = []
        for try await element in self { output.append(element) }
        return output
    }
}
