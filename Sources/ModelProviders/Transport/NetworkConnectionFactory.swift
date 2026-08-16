import Foundation
import Network
import SharedSupport

package struct ProviderConnectionDescriptor: Equatable, Sendable {
    package let numericHost: String
    package let port: UInt16
    package let tlsServerName: String?
    package let interfaceScopeID: UInt32?
}

package struct ProviderConnectionRead: Sendable {
    package let bytes: Data
    package let isComplete: Bool

    package init(bytes: Data, isComplete: Bool) {
        self.bytes = bytes
        self.isComplete = isComplete
    }
}

package protocol ProviderNetworkConnection: Actor {
    func start() async throws
    func send(_ bytes: Data) async throws
    func receive() async throws -> ProviderConnectionRead
    func cancel() async
}

package protocol ProviderConnectionFactory: Sendable {
    func makeConnection(
        descriptor: ProviderConnectionDescriptor
    ) async throws -> any ProviderNetworkConnection
}

package struct NetworkConnectionFactory: ProviderConnectionFactory {
    package init() {}

    package func makeConnection(
        descriptor: ProviderConnectionDescriptor
    ) async throws -> any ProviderNetworkConnection {
        guard let port = NWEndpoint.Port(rawValue: descriptor.port) else {
            throw SanitizedFailure.invalidProviderConfiguration
        }
        let host = try Self.endpointHost(
            numericHost: descriptor.numericHost,
            requiredScopeID: descriptor.interfaceScopeID
        )

        let parameters: NWParameters
        if let tlsServerName = descriptor.tlsServerName {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                tlsServerName
            )
            TrustVerification.install(
                on: tls.securityProtocolOptions,
                expectedHost: tlsServerName
            )
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }

        return SystemProviderNetworkConnection(
            connection: NWConnection(host: host, port: port, using: parameters)
        )
    }

    package static func endpointHost(
        numericHost: String,
        requiredScopeID: UInt32?
    ) throws -> NWEndpoint.Host {
        let host = NWEndpoint.Host(numericHost)
        if requiredScopeID != nil, host.interface == nil {
            throw SanitizedFailure.destinationReconfirmationRequired
        }
        return host
    }
}

private actor SystemProviderNetworkConnection: ProviderNetworkConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "GlideTranslate.ProviderConnection")

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ConnectionStartGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed:
                    gate.resume(throwing: SanitizedFailure.connectionTimeout)
                case .cancelled:
                    gate.resume(throwing: SanitizedFailure.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: bytes,
                completion: .contentProcessed { error in
                    if error == nil {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(
                            throwing: SanitizedFailure.connectionTimeout
                        )
                    }
                }
            )
        }
    }

    func receive() async throws -> ProviderConnectionRead {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65_536
            ) { content, _, isComplete, error in
                if error != nil {
                    continuation.resume(
                        throwing: SanitizedFailure.connectionTimeout
                    )
                } else {
                    continuation.resume(returning: ProviderConnectionRead(
                        bytes: content ?? Data(),
                        isComplete: isComplete
                    ))
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class ConnectionStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func resume(throwing error: Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
