import Foundation
import XCTest

@testable import ModelProviders

final class RedirectPolicyTests: XCTestCase {
    func testCompleteRedirectDecisionTable() throws {
        let current = try ProviderOriginParser.parse(
            XCTUnwrap(URL(string: "https://example.invalid/start?x=1"))
        )
        let accepted = [
            (307, "/next", "/next"),
            (308, "?page=2", "/start?page=2"),
            (307, "https://EXAMPLE.INVALID.:443/final", "/final")
        ]
        for (status, location, path) in accepted {
            let decision = RedirectPolicy.decide(
                status: status,
                location: location,
                currentURL: URL(string: "https://example.invalid/start?x=1")!,
                current: current
            )
            guard case .follow(let endpoint) = decision else {
                return XCTFail("Expected accepted row: \(status) \(location)")
            }
            XCTAssertEqual(endpoint.origin, current.origin)
            XCTAssertEqual(endpoint.pathAndQuery, path)
        }

        let rejected: [(Int, String?, RedirectFailure)] = [
            (301, "/next", .unsupportedStatus),
            (302, "/next", .unsupportedStatus),
            (303, "/next", .unsupportedStatus),
            (307, nil, .missingLocation),
            (307, "http://example.invalid/next", .originChanged),
            (307, "https://other.invalid/next", .originChanged),
            (307, "https://example.invalid:444/next", .originChanged),
            (307, ["https://name", "secret@example.invalid/next"]
                .joined(separator: ":"), .embeddedCredentials),
            (307, "not a URL", .invalidLocation),
            (307, "%", .invalidLocation),
            (307, "%2", .invalidLocation),
            (307, "%GG", .invalidLocation),
            (307, "\r\n", .invalidLocation),
            (307, "\t/next", .invalidLocation),
            (307, " /next", .invalidLocation),
            (307, "/next ", .invalidLocation),
            (307, "/bad path", .invalidLocation),
            (307, "\\evil", .invalidLocation)
        ]
        for (status, location, expected) in rejected {
            XCTAssertEqual(
                RedirectPolicy.decide(
                    status: status,
                    location: location,
                    currentURL: URL(string: "https://example.invalid/start?x=1")!,
                    current: current
                ),
                .reject(expected),
                "\(status) \(String(describing: location))"
            )
        }

        guard case .follow(let escaped) = RedirectPolicy.decide(
            status: 307,
            location: "/valid%20path",
            currentURL: URL(string: "https://example.invalid/start")!,
            current: current
        ) else {
            return XCTFail("Expected valid percent escape")
        }
        XCTAssertEqual(escaped.pathAndQuery, "/valid%20path")
    }
}
