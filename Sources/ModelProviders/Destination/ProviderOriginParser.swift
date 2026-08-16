import Foundation
import SharedSupport

package enum EndpointFailure: Error, Equatable, Sendable {
    case invalidURL
    case missingHost
    case embeddedCredentials
    case unsupportedScheme
    case httpsRequired
    case confirmationRequired
    case destinationUnresolved
}

package struct ParsedProviderEndpoint: Equatable, Sendable {
    package let origin: ProviderOrigin
    package let pathAndQuery: String
}

package enum ProviderOriginParser {
    package static func parse(_ url: URL) throws -> ParsedProviderEndpoint {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw EndpointFailure.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw EndpointFailure.embeddedCredentials
        }
        guard let rawScheme = components.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https" else {
            throw EndpointFailure.unsupportedScheme
        }
        guard let rawHost = components.host,
              let percentEncodedHost = components.percentEncodedHost,
              !rawHost.isEmpty else {
            throw EndpointFailure.missingHost
        }

        guard let host = ProviderHostCanonicalizer.normalize(
            rawHost: rawHost,
            percentEncodedHost: percentEncodedHost
        ) else {
            throw EndpointFailure.invalidURL
        }
        let rawPort = components.port ?? (rawScheme == "https" ? 443 : 80)
        guard let port = UInt16(exactly: rawPort) else {
            throw EndpointFailure.invalidURL
        }

        let path = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
        let pathAndQuery = components.percentEncodedQuery.map {
            "\(path)?\($0)"
        } ?? path
        return ParsedProviderEndpoint(
            origin: ProviderOrigin(
                scheme: rawScheme,
                host: host,
                effectivePort: port
            ),
            pathAndQuery: pathAndQuery
        )
    }

}
