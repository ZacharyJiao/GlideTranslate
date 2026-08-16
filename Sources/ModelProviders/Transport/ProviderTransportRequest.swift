import Foundation
import PrivacyStorage
import SharedSupport

package enum ProviderTransportRequestFailure: Error, Equatable, Sendable {
    case invalidHeader
    case invalidMethod
}

extension ProviderTransportRequest: CredentialHeaderTarget {
    package mutating func setAuthorizationCredential(
        _ credential: borrowing CredentialHeaderValue
    ) {
        credential.withUnsafeBytes { bytes in
            headers[.authorization] = SensitiveHeaderBytes(
                prefix: "Bearer ",
                copying: bytes
            )
        }
    }
}

package struct SanitizedHeaderName: Hashable, Sendable {
    package static let authorization = try! SanitizedHeaderName("Authorization")

    fileprivate let canonicalValue: String

    package init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.allSatisfy(Self.isTokenByte) else {
            throw ProviderTransportRequestFailure.invalidHeader
        }
        let lowered = value.lowercased()
        guard ![
            "host", "connection", "accept", "content-length", "transfer-encoding"
        ].contains(lowered) else {
            throw ProviderTransportRequestFailure.invalidHeader
        }
        canonicalValue = lowered
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 33, 35...39, 42, 43, 45, 46, 48...57, 65...90, 94...122, 124, 126:
            return byte != 96 && byte != 123 && byte != 125
        default:
            return false
        }
    }
}

package struct SensitiveHeaderBytes: Sendable {
    private let storage: Data

    package init(copying bytes: Data) throws {
        guard Self.isValidFieldValue(bytes) else {
            throw ProviderTransportRequestFailure.invalidHeader
        }
        storage = bytes
    }

    package init(prefix: String, copying bytes: UnsafeRawBufferPointer) {
        var combined = Data(prefix.utf8)
        combined.append(bytes.bindMemory(to: UInt8.self))
        storage = combined
    }

    fileprivate var isValidForWire: Bool {
        Self.isValidFieldValue(storage)
    }

    package func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes(body)
    }

    private static func isValidFieldValue(_ bytes: Data) -> Bool {
        bytes.allSatisfy { (32...126).contains($0) }
    }
}

package struct SensitiveBodyBytes: Sendable {
    private let storage: Data

    package init(copying bytes: Data) {
        storage = bytes
    }

    package var count: Int { storage.count }
    package var isEmpty: Bool { storage.isEmpty }

    package func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes(body)
    }
}

package struct ProviderTransportRequest: Sendable {
    package let method: String
    package let endpoint: ParsedProviderEndpoint
    package let numericAddress: IPAddress
    package var headers: [SanitizedHeaderName: SensitiveHeaderBytes]
    package var body: SensitiveBodyBytes

    package init(
        method: String,
        endpoint: ParsedProviderEndpoint,
        numericAddress: IPAddress,
        headers: [SanitizedHeaderName: SensitiveHeaderBytes],
        body: SensitiveBodyBytes
    ) {
        self.method = method
        self.endpoint = endpoint
        self.numericAddress = numericAddress
        self.headers = headers
        self.body = body
    }

    package func encodedBytes() throws -> Data {
        guard !method.isEmpty,
              method.utf8.allSatisfy(SanitizedHeaderName.isMethodTokenByte) else {
            throw SanitizedFailure.invalidProviderConfiguration
        }

        let origin = endpoint.origin
        let hostFields = origin.host.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let identityHost = String(hostFields[0])
        if hostFields.count == 2 {
            guard let endpointScope = UInt32(hostFields[1]),
                  endpointScope == numericAddress.scopeID else {
                throw SanitizedFailure.destinationReconfirmationRequired
            }
        }

        let defaultPort = origin.scheme == "https" ? UInt16(443) : UInt16(80)
        let formattedHost = identityHost.contains(":")
            ? "[\(identityHost)]"
            : identityHost
        let hostValue = origin.effectivePort == defaultPort
            ? formattedHost
            : "\(formattedHost):\(origin.effectivePort)"

        var bytes = Data()
        bytes.append(Data("\(method) \(endpoint.pathAndQuery) HTTP/1.1\r\n".utf8))
        bytes.append(Data("Host: \(hostValue)\r\n".utf8))
        bytes.append(Data("Connection: close\r\n".utf8))
        bytes.append(Data("Accept: application/json, text/event-stream\r\n".utf8))
        bytes.append(Data("Content-Length: \(body.count)\r\n".utf8))

        for (name, value) in headers.sorted(by: {
            $0.key.canonicalValue < $1.key.canonicalValue
        }) {
            guard value.isValidForWire else {
                throw SanitizedFailure.invalidProviderConfiguration
            }
            bytes.append(Data(name.canonicalValue.utf8))
            bytes.append(Data(": ".utf8))
            value.withUnsafeBytes { bytes.append(contentsOf: $0) }
            bytes.append(Data("\r\n".utf8))
        }
        bytes.append(Data("\r\n".utf8))
        body.withUnsafeBytes { bytes.append(contentsOf: $0) }
        return bytes
    }
}

private extension SanitizedHeaderName {
    static func isMethodTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 33, 35...39, 42, 43, 45, 46, 48...57, 65...90, 94...122, 124, 126:
            return byte != 96 && byte != 123 && byte != 125
        default:
            return false
        }
    }
}
