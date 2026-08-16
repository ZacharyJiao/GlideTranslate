import Darwin

package protocol AddressResolving: Sendable {
    func resolve(_ host: String) async throws -> Set<IPAddress>
}

package enum ResolvedAddressRecord: Equatable, Sendable {
    case ipv4([UInt8])
    case ipv6([UInt8], scopeID: UInt32)
    case unsupported
    case malformed
}

package struct SystemAddressResolver: AddressResolving {
    package init() {}

    package func resolve(_ host: String) async throws -> Set<IPAddress> {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw AddressFailure.unresolved
        }
        defer { freeaddrinfo(first) }

        var records: [ResolvedAddressRecord] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let info = current.pointee
            records.append(Self.record(from: info))
            cursor = info.ai_next
        }
        return try Self.canonicalize(records)
    }

    package static func canonicalize(
        _ records: [ResolvedAddressRecord]
    ) throws -> Set<IPAddress> {
        var addresses = Set<IPAddress>()
        for record in records {
            let address: IPAddress
            switch record {
            case .ipv4(let bytes):
                guard bytes.count == 4 else {
                    throw AddressFailure.invalid
                }
                address = .v4(bytes)

            case .ipv6(let bytes, let scopeID):
                guard bytes.count == 16 else {
                    throw AddressFailure.invalid
                }
                if Self.isMappedIPv4(bytes) {
                    guard scopeID == 0 else {
                        throw AddressFailure.invalid
                    }
                    address = .v4(Array(bytes[12..<16]))
                } else {
                    let isLinkLocal = bytes[0] == 0xfe
                        && (bytes[1] & 0xc0) == 0x80
                    guard isLinkLocal == (scopeID != 0) else {
                        throw AddressFailure.invalid
                    }
                    address = .v6(bytes, scopeID: scopeID)
                }

            case .unsupported, .malformed:
                throw AddressFailure.invalid
            }

            addresses.insert(address)
            guard addresses.count <= 32 else {
                throw AddressFailure.tooManyAddresses
            }
        }
        guard !addresses.isEmpty else {
            throw AddressFailure.unresolved
        }
        return addresses
    }

    private static func record(from info: addrinfo) -> ResolvedAddressRecord {
        guard let socketAddress = info.ai_addr else {
            return .malformed
        }
        switch info.ai_family {
        case AF_INET:
            guard info.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size) else {
                return .malformed
            }
            let resolved = socketAddress.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { $0.pointee }
            return .ipv4(withUnsafeBytes(of: resolved.sin_addr, Array.init))

        case AF_INET6:
            guard info.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in6>.size) else {
                return .malformed
            }
            let resolved = socketAddress.withMemoryRebound(
                to: sockaddr_in6.self,
                capacity: 1
            ) { $0.pointee }
            return .ipv6(
                withUnsafeBytes(of: resolved.sin6_addr, Array.init),
                scopeID: resolved.sin6_scope_id
            )

        default:
            return .unsupported
        }
    }

    private static func isMappedIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
    }
}
