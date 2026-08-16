import Darwin
import Foundation
import SharedSupport

package enum AddressFailure: Error, Equatable, Sendable {
    case invalid
    case unresolved
    case tooManyAddresses
}

package enum IPAddress: Hashable, Sendable {
    case v4([UInt8])
    case v6([UInt8], scopeID: UInt32)

    package init(_ presentation: String) throws {
        var v4 = in_addr()
        if inet_pton(AF_INET, presentation, &v4) == 1 {
            self = .v4(withUnsafeBytes(of: v4, Array.init))
            return
        }

        let fields = presentation.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count <= 2 else {
            throw AddressFailure.invalid
        }
        let scopeID: UInt32
        if fields.count == 2 {
            guard !fields[1].isEmpty else {
                throw AddressFailure.invalid
            }
            let scope = String(fields[1])
            guard scope.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x21
                    && scalar.value <= 0x7e
                    && scalar.value != 0x25
            }) else {
                throw AddressFailure.invalid
            }
            scopeID = UInt32(scope) ?? if_nametoindex(scope)
            guard scopeID != 0, Self.interfaceExists(scopeID) else {
                throw AddressFailure.invalid
            }
        } else {
            scopeID = 0
        }

        var v6 = in6_addr()
        guard inet_pton(AF_INET6, String(fields[0]), &v6) == 1 else {
            throw AddressFailure.invalid
        }
        let bytes = withUnsafeBytes(of: &v6, Array.init)
        if Self.isMappedIPv4(bytes) {
            guard scopeID == 0 else {
                throw AddressFailure.invalid
            }
            self = .v4(Array(bytes[12..<16]))
            return
        }

        let candidate = IPAddress.v6(bytes, scopeID: scopeID)
        guard candidate.isIPv6LinkLocal == (scopeID != 0) else {
            throw AddressFailure.invalid
        }
        self = candidate
    }

    package init(fingerprint: String) throws {
        let fields = fingerprint.split(
            separator: ":",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count >= 2,
              let bytes = Data(base64Encoded: String(fields[1])) else {
            throw AddressFailure.invalid
        }

        switch (fields[0], bytes.count, fields.count) {
        case ("v4", 4, 2):
            self = .v4(Array(bytes))
        case ("v6", 16, 3):
            guard let scopeID = UInt32(fields[2]),
                  scopeID == 0 || Self.interfaceExists(scopeID) else {
                throw AddressFailure.invalid
            }
            let rawBytes = Array(bytes)
            guard !Self.isMappedIPv4(rawBytes) else {
                throw AddressFailure.invalid
            }
            let candidate = IPAddress.v6(rawBytes, scopeID: scopeID)
            guard candidate.isIPv6LinkLocal == (scopeID != 0) else {
                throw AddressFailure.invalid
            }
            self = candidate
        default:
            throw AddressFailure.invalid
        }
        guard fingerprint == self.fingerprint else {
            throw AddressFailure.invalid
        }
    }

    package var fingerprint: String {
        switch self {
        case .v4(let bytes):
            return "v4:" + Data(bytes).base64EncodedString()
        case .v6(let bytes, let scopeID):
            return "v6:"
                + Data(bytes).base64EncodedString()
                + ":\(scopeID)"
        }
    }

    package var presentation: String {
        switch self {
        case .v4(let bytes):
            return Self.presentation(bytes: bytes, family: AF_INET)
        case .v6(let bytes, let scopeID):
            let address = Self.presentation(bytes: bytes, family: AF_INET6)
            return scopeID == 0 ? address : "\(address)%\(scopeID)"
        }
    }

    package var scopeID: UInt32 {
        switch self {
        case .v4:
            return 0
        case .v6(_, let scopeID):
            return scopeID
        }
    }

    package var canonicalSortKey: [UInt8] {
        switch self {
        case .v4(let bytes):
            return [4] + bytes
        case .v6(let bytes, let scopeID):
            return [6] + bytes + [
                UInt8(truncatingIfNeeded: scopeID >> 24),
                UInt8(truncatingIfNeeded: scopeID >> 16),
                UInt8(truncatingIfNeeded: scopeID >> 8),
                UInt8(truncatingIfNeeded: scopeID)
            ]
        }
    }

    fileprivate var isLoopback: Bool {
        switch self {
        case .v4(let bytes):
            return bytes[0] == 127
        case .v6(let bytes, _):
            return bytes.dropLast().allSatisfy { $0 == 0 }
                && bytes.last == 1
        }
    }

    fileprivate var isRFC1918: Bool {
        guard case .v4(let bytes) = self else { return false }
        return bytes[0] == 10
            || (bytes[0] == 172 && (bytes[1] & 0xf0) == 16)
            || (bytes[0] == 192 && bytes[1] == 168)
    }

    fileprivate var isIPv4LinkLocal: Bool {
        guard case .v4(let bytes) = self else { return false }
        return bytes[0] == 169 && bytes[1] == 254
    }

    fileprivate var isIPv6UniqueLocal: Bool {
        guard case .v6(let bytes, _) = self else { return false }
        return (bytes[0] & 0xfe) == 0xfc
    }

    fileprivate var isIPv6LinkLocal: Bool {
        guard case .v6(let bytes, _) = self else { return false }
        return bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    }

    fileprivate var isUnspecified: Bool {
        switch self {
        case .v4(let bytes):
            return bytes.allSatisfy { $0 == 0 }
        case .v6(let bytes, _):
            return bytes.allSatisfy { $0 == 0 }
        }
    }

    fileprivate var isMulticast: Bool {
        switch self {
        case .v4(let bytes):
            return (bytes[0] & 0xf0) == 0xe0
        case .v6(let bytes, _):
            return bytes[0] == 0xff
        }
    }

    fileprivate var isDocumentationOnly: Bool {
        switch self {
        case .v4(let bytes):
            return (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 2)
                || (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100)
                || (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113)
        case .v6(let bytes, _):
            return bytes[0] == 0x20
                && bytes[1] == 0x01
                && bytes[2] == 0x0d
                && bytes[3] == 0xb8
        }
    }

    fileprivate var isReserved: Bool {
        switch self {
        case .v4(let bytes):
            return bytes[0] == 0
                || (bytes[0] == 100 && (bytes[1] & 0xc0) == 64)
                || (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 0)
                || (bytes[0] == 192 && bytes[1] == 88 && bytes[2] == 99)
                || (bytes[0] == 198 && (bytes[1] & 0xfe) == 18)
                || bytes[0] >= 240
        case .v6(let bytes, _):
            let isDiscardOnly = bytes[0] == 0x01
                && bytes[1...7].allSatisfy { $0 == 0 }
            let isDeprecatedSiteLocal = bytes[0] == 0xfe
                && (bytes[1] & 0xc0) == 0xc0
            return isDiscardOnly || isDeprecatedSiteLocal
        }
    }

    private static func isMappedIPv4(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16
            && bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
    }

    private static func interfaceExists(_ scopeID: UInt32) -> Bool {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return name.withUnsafeMutableBufferPointer { buffer in
            if_indextoname(scopeID, buffer.baseAddress) != nil
        }
    }

    private static func presentation(bytes: [UInt8], family: Int32) -> String {
        var output = [CChar](
            repeating: 0,
            count: family == AF_INET ? Int(INET_ADDRSTRLEN) : Int(INET6_ADDRSTRLEN)
        )
        return bytes.withUnsafeBytes { addressBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                guard let address = addressBuffer.baseAddress,
                      let result = inet_ntop(
                          family,
                          address,
                          outputBuffer.baseAddress,
                          socklen_t(outputBuffer.count)
                      ) else {
                    return ""
                }
                return String(cString: result)
            }
        }
    }
}

package enum DestinationClassifier {
    private static func classifyOne(
        _ address: IPAddress
    ) -> DestinationPrivacyClass {
        if address.isLoopback { return .localOnDevice }
        if address.isRFC1918
            || address.isIPv4LinkLocal
            || address.isIPv6UniqueLocal
            || address.isIPv6LinkLocal {
            return .localNetwork
        }
        if address.isUnspecified
            || address.isMulticast
            || address.isDocumentationOnly
            || address.isReserved {
            return .unresolvedOrChanged
        }
        return .cloud
    }

    package static func classify(
        _ addresses: Set<IPAddress>
    ) -> DestinationPrivacyClass {
        guard !addresses.isEmpty else { return .unresolvedOrChanged }
        let classes = Set(addresses.map(classifyOne))
        guard classes.count == 1,
              let only = classes.first,
              only != .unresolvedOrChanged else {
            return .unresolvedOrChanged
        }
        return only
    }
}
