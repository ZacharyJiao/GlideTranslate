import Darwin
import Foundation
import Network
import SharedSupport
import XCTest

@testable import ModelProviders

actor ScriptedProviderConnection: ProviderNetworkConnection {
    private var reads: [ProviderConnectionRead]
    private(set) var sent = Data()
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(reads: [ProviderConnectionRead] = [
        ProviderConnectionRead(
            bytes: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8),
            isComplete: false
        ),
        ProviderConnectionRead(bytes: Data(), isComplete: true)
    ]) {
        self.reads = reads
    }

    func start() async throws {
        startCount += 1
    }

    func send(_ bytes: Data) async throws {
        sent.append(bytes)
    }

    func receive() async throws -> ProviderConnectionRead {
        if reads.isEmpty {
            return ProviderConnectionRead(bytes: Data(), isComplete: true)
        }
        return reads.removeFirst()
    }

    func cancel() async {
        cancelCount += 1
    }

    func snapshot() -> (Data, Int, Int) {
        (sent, startCount, cancelCount)
    }
}

actor SpyProviderConnectionFactory: ProviderConnectionFactory {
    private let connection: ScriptedProviderConnection
    private(set) var descriptors: [ProviderConnectionDescriptor] = []

    init(connection: ScriptedProviderConnection = ScriptedProviderConnection()) {
        self.connection = connection
    }

    func makeConnection(
        descriptor: ProviderConnectionDescriptor
    ) async throws -> any ProviderNetworkConnection {
        descriptors.append(descriptor)
        return connection
    }

    func capturedDescriptors() -> [ProviderConnectionDescriptor] {
        descriptors
    }
}

final class PinnedHTTPTransportTests: XCTestCase {
    func testConnectionUsesAcceptedNumericAddressAndOriginalHostIdentity() async throws {
        let connection = ScriptedProviderConnection()
        let factory = SpyProviderConnectionFactory(connection: connection)
        let transport = PinnedHTTPTransport(factory: factory)
        let request = try transportRequest(
            endpoint: "https://example.invalid/v1/chat?synthetic=yes",
            numericAddress: "93.184.216.34"
        )

        let response = try await transport.open(request)
        let events = try await response.events.collect()
        XCTAssertEqual(events.transportBodyBytes, Data("ok".utf8))

        let descriptors = await factory.capturedDescriptors()
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors[0].numericHost, "93.184.216.34")
        XCTAssertEqual(descriptors[0].port, 443)
        XCTAssertEqual(descriptors[0].tlsServerName, "example.invalid")
        XCTAssertNil(descriptors[0].interfaceScopeID)

        let sent = await connection.snapshot().0
        let head = String(decoding: sent, as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("POST /v1/chat?synthetic=yes HTTP/1.1\r\n"))
        XCTAssertTrue(head.contains("\r\nHost: example.invalid\r\n"))
        XCTAssertFalse(head.contains("Host: 93.184.216.34"))
    }

    func testIPv6AuthorityFormattingAndScopeBinding() async throws {
        let loopbackRows = [
            ("http://[::1]/v1", "Host: [::1]\r\n"),
            ("http://[::1]:8080/v1", "Host: [::1]:8080\r\n")
        ]
        for row in loopbackRows {
            let connection = ScriptedProviderConnection()
            let factory = SpyProviderConnectionFactory(connection: connection)
            let response = try await PinnedHTTPTransport(factory: factory).open(
                try transportRequest(endpoint: row.0, numericAddress: "::1")
            )
            _ = try await response.events.collect()
            let sent = await connection.snapshot().0
            XCTAssertTrue(String(decoding: sent, as: UTF8.self).contains(row.1))
        }

        let scopeID = if_nametoindex("lo0")
        XCTAssertNotEqual(scopeID, 0)
        let connection = ScriptedProviderConnection()
        let factory = SpyProviderConnectionFactory(connection: connection)
        let endpoint = "http://[fe80::8%25\(scopeID)]:8080/v1"
        let response = try await PinnedHTTPTransport(factory: factory).open(
            try transportRequest(
                endpoint: endpoint,
                numericAddress: "fe80::8%\(scopeID)"
            )
        )
        _ = try await response.events.collect()

        let captured = await factory.capturedDescriptors()
        let descriptor = try XCTUnwrap(captured.only)
        XCTAssertEqual(descriptor.numericHost, "fe80::8%\(scopeID)")
        XCTAssertEqual(descriptor.interfaceScopeID, scopeID)
        let sent = await connection.snapshot().0
        let head = String(decoding: sent, as: UTF8.self)
        XCTAssertTrue(head.contains("Host: [fe80::8]:8080\r\n"))
        XCTAssertFalse(head.contains("%\(scopeID)"))
    }

    func testScopeMismatchAndCRLFHeaderFailBeforeConnection() async throws {
        let scopeID = if_nametoindex("lo0")
        let otherScope = scopeID == 1 ? UInt32(2) : UInt32(1)
        let factory = SpyProviderConnectionFactory()
        let endpoint = try ProviderOriginParser.parse(
            XCTUnwrap(URL(string: "http://[fe80::8%25\(scopeID)]:8080/v1"))
        )
        let mismatch = ProviderTransportRequest(
            method: "GET",
            endpoint: endpoint,
            numericAddress: .v6(
                [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [8],
                scopeID: otherScope
            ),
            headers: [:],
            body: SensitiveBodyBytes(copying: Data())
        )
        do {
            _ = try await PinnedHTTPTransport(factory: factory).open(mismatch)
            XCTFail("Expected scope mismatch rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .destinationReconfirmationRequired)
        }

        XCTAssertThrowsError(try SanitizedHeaderName("X-Bad\r\nInjected"))
        XCTAssertThrowsError(try SensitiveHeaderBytes(copying: Data([0x61, 13, 10])))
        let descriptors = await factory.capturedDescriptors()
        XCTAssertEqual(descriptors.count, 0)
    }

    func testCredentialPrefixInjectionAndCaseAliasesFailBeforeConnection() async throws {
        let uppercase = try SanitizedHeaderName("Authorization")
        let lowercase = try SanitizedHeaderName("authorization")
        XCTAssertEqual(uppercase, lowercase)
        XCTAssertEqual(Set([uppercase, lowercase]).count, 1)

        let credential = Data("token\r\nX-Injected: yes".utf8)
        let unsafeValue = credential.withUnsafeBytes {
            SensitiveHeaderBytes(prefix: "Bearer ", copying: $0)
        }
        let endpoint = try ProviderOriginParser.parse(
            XCTUnwrap(URL(string: "https://example.invalid/v1"))
        )
        let request = ProviderTransportRequest(
            method: "GET",
            endpoint: endpoint,
            numericAddress: try IPAddress("93.184.216.34"),
            headers: [uppercase: unsafeValue],
            body: SensitiveBodyBytes(copying: Data())
        )
        let factory = SpyProviderConnectionFactory()
        do {
            _ = try await PinnedHTTPTransport(factory: factory).open(request)
            XCTFail("Expected header injection rejection")
        } catch {
            XCTAssertEqual(error as? SanitizedFailure, .invalidProviderConfiguration)
        }
        let descriptors = await factory.capturedDescriptors()
        XCTAssertEqual(descriptors.count, 0)
    }

    func testCancellationAcrossEveryBlockedPhaseClosesOnceAndFinishesCancelled() async throws {
        for phase in ControlledPhase.allCases {
            let fixture = ControlledTransportFixture(phase: phase)
            let response = try await PinnedHTTPTransport(factory: fixture.factory).open(
                try transportRequest(
                    endpoint: "http://127.0.0.1:11434/api/chat",
                    numericAddress: "127.0.0.1"
                )
            )
            await fixture.waitUntilBlocked()
            let collector = Task {
                do {
                    _ = try await response.events.collect()
                    return nil as SanitizedFailure?
                } catch {
                    return error as? SanitizedFailure
                }
            }
            await response.cancel()
            await response.cancel()
            await fixture.releaseBlockedPhase()
            let terminalFailure = await collector.value
            XCTAssertEqual(terminalFailure, .cancelled, String(describing: phase))
            await fixture.waitUntilSettled()
            let cancelCalls = await fixture.connection.cancelCalls()
            let makeCalls = await fixture.factory.makeCalls()
            XCTAssertEqual(cancelCalls, 1, String(describing: phase))
            XCTAssertEqual(makeCalls, 1, String(describing: phase))
        }
    }

    func testNetworkFactoryBuildsScopedEndpointWithoutTraffic() throws {
        let scopeID = if_nametoindex("lo0")
        XCTAssertNotEqual(scopeID, 0)
        let host = try NetworkConnectionFactory.endpointHost(
            numericHost: "fe80::8%\(scopeID)",
            requiredScopeID: scopeID
        )
        XCTAssertNotNil(host.interface)
    }
}

private enum ControlledPhase: CaseIterable {
    case preparing
    case connecting
    case awaitingHead
    case receivingBody
}

private actor AsyncGate {
    private var reached = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func block() async {
        reached = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releases.append($0) }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for continuation in releases { continuation.resume() }
        releases.removeAll()
    }
}

private actor ControlledConnection: ProviderNetworkConnection {
    private let phase: ControlledPhase
    private let gate: AsyncGate
    private var receiveCount = 0
    private var cancellations = 0

    init(phase: ControlledPhase, gate: AsyncGate) {
        self.phase = phase
        self.gate = gate
    }

    func start() async throws {
        if phase == .connecting { await gate.block() }
    }

    func send(_ bytes: Data) async throws {}

    func receive() async throws -> ProviderConnectionRead {
        receiveCount += 1
        if phase == .awaitingHead {
            await gate.block()
            return ProviderConnectionRead(bytes: Data(), isComplete: false)
        }
        if phase == .receivingBody, receiveCount == 1 {
            return ProviderConnectionRead(
                bytes: Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab".utf8),
                isComplete: false
            )
        }
        if phase == .receivingBody {
            await gate.block()
            return ProviderConnectionRead(bytes: Data("cd".utf8), isComplete: false)
        }
        return ProviderConnectionRead(bytes: Data(), isComplete: false)
    }

    func cancel() { cancellations += 1 }
    func cancelCalls() -> Int { cancellations }
}

private actor ControlledFactory: ProviderConnectionFactory {
    private let phase: ControlledPhase
    private let gate: AsyncGate
    private let connection: ControlledConnection
    private var calls = 0

    init(phase: ControlledPhase, gate: AsyncGate, connection: ControlledConnection) {
        self.phase = phase
        self.gate = gate
        self.connection = connection
    }

    func makeConnection(
        descriptor: ProviderConnectionDescriptor
    ) async throws -> any ProviderNetworkConnection {
        calls += 1
        if phase == .preparing { await gate.block() }
        return connection
    }

    func makeCalls() -> Int { calls }
}

private struct ControlledTransportFixture {
    let gate: AsyncGate
    let connection: ControlledConnection
    let factory: ControlledFactory

    init(phase: ControlledPhase) {
        let gate = AsyncGate()
        self.gate = gate
        connection = ControlledConnection(phase: phase, gate: gate)
        factory = ControlledFactory(phase: phase, gate: gate, connection: connection)
    }

    func waitUntilBlocked() async { await gate.waitUntilReached() }
    func releaseBlockedPhase() async { await gate.release() }

    func waitUntilSettled() async {
        for _ in 0..<100 where await connection.cancelCalls() == 0 {
            await Task.yield()
        }
    }
}

private func transportRequest(
    endpoint: String,
    numericAddress: String
) throws -> ProviderTransportRequest {
    let parsed = try ProviderOriginParser.parse(XCTUnwrap(URL(string: endpoint)))
    return ProviderTransportRequest(
        method: "POST",
        endpoint: parsed,
        numericAddress: try IPAddress(numericAddress),
        headers: [
            try SanitizedHeaderName("X-Synthetic"): try SensitiveHeaderBytes(
                copying: Data("yes".utf8)
            )
        ],
        body: SensitiveBodyBytes(copying: Data("{}".utf8))
    )
}

private extension AsyncThrowingStream where Failure == Error {
    func collect() async throws -> [Element] {
        var result: [Element] = []
        for try await element in self { result.append(element) }
        return result
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private extension Array where Element == HTTPResponseEvent {
    var transportBodyBytes: Data {
        reduce(into: Data()) { result, event in
            if case .body(let bytes) = event { result.append(bytes) }
        }
    }
}
