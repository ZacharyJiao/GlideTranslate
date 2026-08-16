import Foundation

package enum RedirectDecision: Equatable, Sendable {
    case follow(ParsedProviderEndpoint)
    case reject(RedirectFailure)
}

package enum RedirectFailure: Error, Equatable, Sendable {
    case unsupportedStatus
    case missingLocation
    case invalidLocation
    case embeddedCredentials
    case originChanged
    case destinationChanged
    case unresolvedDestination
    case loop
    case hopLimit
}

package enum RedirectPolicy {
    package static func decide(
        status: Int,
        location: String?,
        currentURL: URL,
        current: ParsedProviderEndpoint
    ) -> RedirectDecision {
        guard status == 307 || status == 308 else {
            return .reject(.unsupportedStatus)
        }
        guard let location else { return .reject(.missingLocation) }
        guard StrictURIReferenceValidator.accepts(location),
              let resolvedURL = URL(
                  string: location,
                  relativeTo: currentURL
              )?.absoluteURL else {
            return .reject(.invalidLocation)
        }
        let next: ParsedProviderEndpoint
        do {
            next = try ProviderOriginParser.parse(resolvedURL)
        } catch EndpointFailure.embeddedCredentials {
            return .reject(.embeddedCredentials)
        } catch {
            return .reject(.invalidLocation)
        }
        guard next.origin == current.origin else {
            return .reject(.originChanged)
        }
        return .follow(next)
    }
}

private enum StrictURIReferenceValidator {
    static func accepts(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte >= 0x21, byte <= 0x7e, byte != 0x5c else {
                return false
            }
            if byte == 0x25 {
                guard index + 2 < bytes.count,
                      isHex(bytes[index + 1]),
                      isHex(bytes[index + 2]) else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }

        if let colon = bytes.firstIndex(of: 0x3a) {
            let delimiter = bytes.firstIndex(where: { $0 == 0x2f || $0 == 0x3f || $0 == 0x23 })
            if delimiter == nil || colon < delimiter! {
                let scheme = bytes[..<colon]
                guard let first = scheme.first,
                      isAlpha(first),
                      scheme.dropFirst().allSatisfy({ byte in
                          isAlpha(byte)
                              || (0x30...0x39).contains(byte)
                              || byte == 0x2b
                              || byte == 0x2d
                              || byte == 0x2e
                      }) else {
                    return false
                }
            }
        }
        return true
    }

    private static func isAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}
