import Darwin
import Foundation

package enum ProviderHostCanonicalizer {
    package static func normalize(
        rawHost: String,
        percentEncodedHost: String
    ) -> String? {
        let raw = unwrapped(rawHost)
        let percentEncoded = unwrapped(percentEncodedHost)
        let lowered = raw.lowercased()
        let fields = lowered.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let addressPart = String(fields[0])
        var v6 = in6_addr()

        if inet_pton(AF_INET6, addressPart, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6, Array.init)
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            if fields.count == 1 {
                guard !isLinkLocal else { return nil }
                return addressPart
            }
            guard isLinkLocal, !fields[1].isEmpty else { return nil }
            let scope = String(fields[1])
            guard scope.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x21
                    && scalar.value <= 0x7e
                    && scalar.value != 0x25
            }) else {
                return nil
            }
            let scopeID = UInt32(scope) ?? if_nametoindex(scope)
            guard scopeID != 0, interfaceExists(scopeID) else { return nil }
            return "\(addressPart)%\(scopeID)"
        }

        guard fields.count == 1, !percentEncoded.contains("%") else {
            return nil
        }
        let dnsHost = lowered.hasSuffix(".")
            ? String(lowered.dropLast())
            : lowered
        guard isValidDNSOrIPv4Host(dnsHost) else { return nil }
        return dnsHost
    }

    private static func unwrapped(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
    }

    private static func isValidDNSOrIPv4Host(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        guard host.utf8.allSatisfy({ byte in
            (byte >= 0x61 && byte <= 0x7a)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2d
                || byte == 0x2e
        }) else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty
                && label.utf8.count <= 63
                && label.first != "-"
                && label.last != "-"
        }) else {
            return false
        }
        if host.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || byte == 0x2e
        }) {
            var address = in_addr()
            return inet_pton(AF_INET, host, &address) == 1
        }
        return true
    }

    private static func interfaceExists(_ scopeID: UInt32) -> Bool {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return name.withUnsafeMutableBufferPointer { buffer in
            if_indextoname(scopeID, buffer.baseAddress) != nil
        }
    }
}
