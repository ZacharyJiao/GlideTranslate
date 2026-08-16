import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import ModelProviders

final class EndpointPolicyTests: XCTestCase {
    private enum EndpointRow {
        case parseReject(String, EndpointFailure)
        case policy(
            String,
            resolvedClass: DestinationPrivacyClass,
            confirmedClass: DestinationPrivacyClass?,
            expectedPort: UInt16,
            expectedPathAndQuery: String,
            expectedFailure: EndpointFailure?
        )
        case sameOrigin(String, String)
        case differentOrigin(String, String)
    }

    private func privateIPv4(
        _ first: UInt8,
        _ second: UInt8,
        _ third: UInt8,
        _ fourth: UInt8
    ) -> String {
        [first, second, third, fourth].map(String.init).joined(separator: ".")
    }

    private var scopedLinkLocalURL: String? {
        let index = if_nametoindex("lo0")
        guard index != 0 else { return nil }
        return "http://[fe80::8%25\(index)]:11434"
    }

    func testEndpointMatrix() throws {
        let privateAddress = privateIPv4(192, 168, 1, 8)
        let rows: [EndpointRow] = [
            .parseReject(
                ["https://name", "secret@example.invalid/v1"]
                    .joined(separator: ":"),
                .embeddedCredentials
            ),
            .parseReject("ftp://example.invalid/v1", .unsupportedScheme),
            .parseReject("https:///v1", .missingHost),
            .parseReject("https://example.invalid:70000/v1", .invalidURL),
            .parseReject("https://%0d%0a.example.invalid/v1", .invalidURL),
            .parseReject("https://%00.example.invalid/v1", .invalidURL),
            .parseReject("https://%2f.example.invalid/v1", .invalidURL),
            .parseReject("https://éxample.invalid/v1", .invalidURL),
            .parseReject("https://.example.invalid/v1", .invalidURL),
            .parseReject("https://-example.invalid/v1", .invalidURL),
            .parseReject("https://example-.invalid/v1", .invalidURL),
            .parseReject("https://example..invalid/v1", .invalidURL),
            .parseReject("http://[fe80::8]:11434", .invalidURL),
            .parseReject("http://[fe80::8%250]:11434", .invalidURL),
            .parseReject(
                "http://[fe80::8%25synthetic-missing-interface]:11434",
                .invalidURL
            ),
            .parseReject(
                "http://[fe80::8%25lo0%00synthetic-suffix]:11434",
                .invalidURL
            ),
            .parseReject("http://[::1%25lo0]:11434", .invalidURL),
            .parseReject("https://example.invalid%25lo0/v1", .invalidURL),
            .policy(
                "http://127.0.0.1:11434",
                resolvedClass: .localOnDevice,
                confirmedClass: nil,
                expectedPort: 11434,
                expectedPathAndQuery: "/",
                expectedFailure: nil
            ),
            .policy(
                "http://[::1]:11434",
                resolvedClass: .localOnDevice,
                confirmedClass: nil,
                expectedPort: 11434,
                expectedPathAndQuery: "/",
                expectedFailure: nil
            ),
            .policy(
                "http://\(privateAddress):11434",
                resolvedClass: .localNetwork,
                confirmedClass: nil,
                expectedPort: 11434,
                expectedPathAndQuery: "/",
                expectedFailure: .confirmationRequired
            ),
            .policy(
                "http://\(privateAddress):11434",
                resolvedClass: .localNetwork,
                confirmedClass: .localNetwork,
                expectedPort: 11434,
                expectedPathAndQuery: "/",
                expectedFailure: nil
            ),
            .policy(
                "http://example.invalid/v1",
                resolvedClass: .cloud,
                confirmedClass: .cloud,
                expectedPort: 80,
                expectedPathAndQuery: "/v1",
                expectedFailure: .httpsRequired
            ),
            .policy(
                "https://example.invalid/v1",
                resolvedClass: .cloud,
                confirmedClass: nil,
                expectedPort: 443,
                expectedPathAndQuery: "/v1",
                expectedFailure: .confirmationRequired
            ),
            .policy(
                "https://example.invalid/v1",
                resolvedClass: .cloud,
                confirmedClass: .localNetwork,
                expectedPort: 443,
                expectedPathAndQuery: "/v1",
                expectedFailure: .confirmationRequired
            ),
            .policy(
                "https://example.invalid/v1",
                resolvedClass: .localNetwork,
                confirmedClass: .cloud,
                expectedPort: 443,
                expectedPathAndQuery: "/v1",
                expectedFailure: .confirmationRequired
            ),
            .policy(
                "https://example.invalid/v1",
                resolvedClass: .unresolvedOrChanged,
                confirmedClass: .cloud,
                expectedPort: 443,
                expectedPathAndQuery: "/v1",
                expectedFailure: .destinationUnresolved
            ),
            .policy(
                "https://example.invalid/v1?mode=synthetic#ignored",
                resolvedClass: .cloud,
                confirmedClass: .cloud,
                expectedPort: 443,
                expectedPathAndQuery: "/v1?mode=synthetic",
                expectedFailure: nil
            ),
            .sameOrigin(
                "https://EXAMPLE.invalid./a",
                "https://example.invalid:443/b"
            ),
            .sameOrigin(
                "http://127.0.0.1/a",
                "http://127.0.0.1:80/b"
            ),
            .differentOrigin(
                "https://example.invalid/a",
                "http://example.invalid/a"
            ),
            .differentOrigin(
                "https://example.invalid/a",
                "https://other.invalid/a"
            ),
            .differentOrigin(
                "https://example.invalid/a",
                "https://example.invalid:444/a"
            )
        ]

        for row in rows {
            switch row {
            case .parseReject(let value, let expectedFailure):
                XCTAssertThrowsError(
                    try ProviderOriginParser.parse(try XCTUnwrap(URL(string: value)))
                ) { error in
                    XCTAssertEqual(error as? EndpointFailure, expectedFailure)
                }

            case .policy(
                let value,
                let resolvedClass,
                let confirmedClass,
                let expectedPort,
                let expectedPathAndQuery,
                let expectedFailure
            ):
                let parsed = try ProviderOriginParser.parse(
                    try XCTUnwrap(URL(string: value))
                )
                XCTAssertEqual(parsed.origin.scheme, value.hasPrefix("https") ? "https" : "http")
                XCTAssertEqual(parsed.origin.host, expectedHost(for: value))
                XCTAssertEqual(parsed.origin.effectivePort, expectedPort)
                XCTAssertEqual(parsed.pathAndQuery, expectedPathAndQuery)
                let result = EndpointPolicy.validate(
                    endpoint: parsed,
                    resolvedClass: resolvedClass,
                    confirmedClass: confirmedClass
                )
                if let expectedFailure {
                    XCTAssertThrowsError(try result.get()) { error in
                        XCTAssertEqual(error as? EndpointFailure, expectedFailure)
                    }
                } else {
                    XCTAssertNoThrow(try result.get())
                }

            case .sameOrigin(let first, let second):
                let firstEndpoint = try ProviderOriginParser.parse(
                    try XCTUnwrap(URL(string: first))
                )
                let secondEndpoint = try ProviderOriginParser.parse(
                    try XCTUnwrap(URL(string: second))
                )
                XCTAssertEqual(firstEndpoint.origin, secondEndpoint.origin)

            case .differentOrigin(let first, let second):
                let firstEndpoint = try ProviderOriginParser.parse(
                    try XCTUnwrap(URL(string: first))
                )
                let secondEndpoint = try ProviderOriginParser.parse(
                    try XCTUnwrap(URL(string: second))
                )
                XCTAssertNotEqual(firstEndpoint.origin, secondEndpoint.origin)
            }
        }
    }

    func testScopedLinkLocalRequiresAndNormalizesCurrentInterface() throws {
        let interfaceIndex = if_nametoindex("lo0")
        XCTAssertNotEqual(interfaceIndex, 0)
        let value = try XCTUnwrap(scopedLinkLocalURL)
        let parsed = try ProviderOriginParser.parse(
            try XCTUnwrap(URL(string: value))
        )

        XCTAssertEqual(parsed.origin.host, "fe80::8%\(interfaceIndex)")
        XCTAssertEqual(parsed.origin.effectivePort, 11434)
        XCTAssertEqual(parsed.pathAndQuery, "/")
        XCTAssertNoThrow(
            try EndpointPolicy.validate(
                endpoint: parsed,
                resolvedClass: .localNetwork,
                confirmedClass: .localNetwork
            ).get()
        )
    }

    private func expectedHost(for value: String) -> String {
        if value.contains("127.0.0.1") { return "127.0.0.1" }
        if value.contains("[::1]") { return "::1" }
        if value.contains(privateIPv4(192, 168, 1, 8)) {
            return privateIPv4(192, 168, 1, 8)
        }
        return "example.invalid"
    }
}
