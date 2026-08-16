import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import ModelProviders

final class DestinationClassifierTests: XCTestCase {
    private func privateIPv4(
        _ first: UInt8,
        _ second: UInt8,
        _ third: UInt8,
        _ fourth: UInt8
    ) -> String {
        [first, second, third, fourth].map(String.init).joined(separator: ".")
    }

    func testCanonicalAddressBytesAndFingerprintRoundTrip() throws {
        let loopback = try IPAddress("127.0.0.1")
        XCTAssertEqual(loopback, .v4([127, 0, 0, 1]))

        let privateAddress = try IPAddress(privateIPv4(192, 168, 1, 8))
        XCTAssertEqual(privateAddress, .v4([192, 168, 1, 8]))

        let v6 = try IPAddress("2001:4860:4860::8888")
        XCTAssertEqual(try IPAddress(fingerprint: v6.fingerprint), v6)
        XCTAssertEqual(try IPAddress(fingerprint: loopback.fingerprint), loopback)
        XCTAssertEqual(try IPAddress("::ffff:127.0.0.1"), loopback)
        XCTAssertEqual(try IPAddress(v6.presentation), v6)
        XCTAssertThrowsError(try IPAddress(fingerprint: "v4:AAAA"))
        XCTAssertThrowsError(try IPAddress(fingerprint: "v6:AAAA:0"))
    }

    func testAddressClassificationMatrix() throws {
        let loopbackIndex = if_nametoindex("lo0")
        XCTAssertNotEqual(loopbackIndex, 0)
        let rows: [([String], DestinationPrivacyClass)] = [
            (["127.0.0.1"], .localOnDevice),
            (["::1"], .localOnDevice),
            (["::ffff:127.0.0.1"], .localOnDevice),
            ([privateIPv4(10, 0, 0, 8)], .localNetwork),
            ([privateIPv4(172, 16, 0, 8)], .localNetwork),
            ([privateIPv4(172, 31, 255, 254)], .localNetwork),
            ([privateIPv4(192, 168, 1, 8)], .localNetwork),
            ([privateIPv4(169, 254, 10, 2)], .localNetwork),
            (["fd00::8"], .localNetwork),
            (["fe80::8%\(loopbackIndex)"], .localNetwork),
            (["93.184.216.34"], .cloud),
            (["0.0.0.0"], .unresolvedOrChanged),
            (["::"], .unresolvedOrChanged),
            (["224.0.0.1"], .unresolvedOrChanged),
            (["ff02::1"], .unresolvedOrChanged),
            (["192.0.2.1"], .unresolvedOrChanged),
            (["198.51.100.1"], .unresolvedOrChanged),
            (["203.0.113.1"], .unresolvedOrChanged),
            (["2001:db8::1"], .unresolvedOrChanged),
            ([], .unresolvedOrChanged),
            (["127.0.0.1", "93.184.216.34"], .unresolvedOrChanged),
            ([
                privateIPv4(10, 0, 0, 8),
                privateIPv4(192, 168, 1, 8)
            ], .localNetwork)
        ]

        for (presentations, expected) in rows {
            let addresses = Set(try presentations.map { try IPAddress($0) })
            XCTAssertEqual(
                DestinationClassifier.classify(addresses),
                expected,
                presentations.joined(separator: ",")
            )
        }
    }

    func testAddressParserRejectsInvalidScopeCombinations() throws {
        XCTAssertThrowsError(try IPAddress("fe80::8"))
        XCTAssertThrowsError(try IPAddress("fe80::8%0"))
        XCTAssertThrowsError(
            try IPAddress("fe80::8%synthetic-missing-interface")
        )
        XCTAssertThrowsError(try IPAddress("::1%lo0"))
        XCTAssertThrowsError(try IPAddress("2001:4860:4860::8888%lo0"))
        XCTAssertThrowsError(try IPAddress("127.0.0.1%lo0"))
    }

    func testIPv4ClassificationBoundaries() throws {
        let rows: [(String, DestinationPrivacyClass)] = [
            (privateIPv4(0, 0, 0, 0), .unresolvedOrChanged),
            (privateIPv4(0, 255, 255, 255), .unresolvedOrChanged),
            (privateIPv4(1, 0, 0, 0), .cloud),
            (privateIPv4(9, 255, 255, 255), .cloud),
            (privateIPv4(10, 0, 0, 0), .localNetwork),
            (privateIPv4(10, 255, 255, 255), .localNetwork),
            (privateIPv4(11, 0, 0, 0), .cloud),
            (privateIPv4(100, 63, 255, 255), .cloud),
            (privateIPv4(100, 64, 0, 0), .unresolvedOrChanged),
            (privateIPv4(100, 127, 255, 255), .unresolvedOrChanged),
            (privateIPv4(100, 128, 0, 0), .cloud),
            (privateIPv4(126, 255, 255, 255), .cloud),
            (privateIPv4(127, 0, 0, 0), .localOnDevice),
            (privateIPv4(127, 255, 255, 255), .localOnDevice),
            (privateIPv4(128, 0, 0, 0), .cloud),
            (privateIPv4(172, 15, 255, 255), .cloud),
            (privateIPv4(172, 16, 0, 0), .localNetwork),
            (privateIPv4(172, 31, 255, 255), .localNetwork),
            (privateIPv4(172, 32, 0, 0), .cloud),
            (privateIPv4(192, 167, 255, 255), .cloud),
            (privateIPv4(192, 168, 0, 0), .localNetwork),
            (privateIPv4(192, 168, 255, 255), .localNetwork),
            (privateIPv4(192, 169, 0, 0), .cloud),
            (privateIPv4(169, 253, 255, 255), .cloud),
            (privateIPv4(169, 254, 0, 0), .localNetwork),
            (privateIPv4(169, 254, 255, 255), .localNetwork),
            (privateIPv4(169, 255, 0, 0), .cloud),
            (privateIPv4(192, 0, 0, 0), .unresolvedOrChanged),
            (privateIPv4(192, 0, 0, 255), .unresolvedOrChanged),
            (privateIPv4(192, 0, 1, 0), .cloud),
            (privateIPv4(192, 0, 1, 255), .cloud),
            (privateIPv4(192, 0, 2, 0), .unresolvedOrChanged),
            (privateIPv4(192, 0, 2, 255), .unresolvedOrChanged),
            (privateIPv4(192, 0, 3, 0), .cloud),
            (privateIPv4(192, 88, 98, 255), .cloud),
            (privateIPv4(192, 88, 99, 0), .unresolvedOrChanged),
            (privateIPv4(192, 88, 99, 255), .unresolvedOrChanged),
            (privateIPv4(192, 88, 100, 0), .cloud),
            (privateIPv4(223, 255, 255, 255), .cloud),
            (privateIPv4(198, 17, 255, 255), .cloud),
            (privateIPv4(198, 18, 0, 0), .unresolvedOrChanged),
            (privateIPv4(198, 19, 255, 255), .unresolvedOrChanged),
            (privateIPv4(198, 20, 0, 0), .cloud),
            (privateIPv4(198, 51, 99, 255), .cloud),
            (privateIPv4(198, 51, 100, 0), .unresolvedOrChanged),
            (privateIPv4(198, 51, 100, 255), .unresolvedOrChanged),
            (privateIPv4(198, 51, 101, 0), .cloud),
            (privateIPv4(203, 0, 112, 255), .cloud),
            (privateIPv4(203, 0, 113, 0), .unresolvedOrChanged),
            (privateIPv4(203, 0, 113, 255), .unresolvedOrChanged),
            (privateIPv4(203, 0, 114, 0), .cloud),
            (privateIPv4(224, 0, 0, 0), .unresolvedOrChanged),
            (privateIPv4(239, 255, 255, 255), .unresolvedOrChanged),
            (privateIPv4(240, 0, 0, 0), .unresolvedOrChanged),
            (privateIPv4(255, 255, 255, 255), .unresolvedOrChanged)
        ]

        for (presentation, expected) in rows {
            XCTAssertEqual(
                DestinationClassifier.classify([try IPAddress(presentation)]),
                expected,
                presentation
            )
        }
    }

    func testIPv6ClassificationBoundaries() throws {
        let loopbackIndex = if_nametoindex("lo0")
        XCTAssertNotEqual(loopbackIndex, 0)
        let rows: [(String, DestinationPrivacyClass)] = [
            ("::", .unresolvedOrChanged),
            ("::1", .localOnDevice),
            ("ff00::", .unresolvedOrChanged),
            ("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .unresolvedOrChanged),
            ("fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .cloud),
            ("fc00::", .localNetwork),
            ("fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .localNetwork),
            ("fe00::", .cloud),
            ("fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .cloud),
            ("fe80::%\(loopbackIndex)", .localNetwork),
            ("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff%\(loopbackIndex)", .localNetwork),
            ("fec0::", .unresolvedOrChanged),
            ("feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .unresolvedOrChanged),
            ("2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", .cloud),
            ("2001:db8::", .unresolvedOrChanged),
            ("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", .unresolvedOrChanged),
            ("2001:db9::", .cloud),
            ("ff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .cloud),
            ("100::", .unresolvedOrChanged),
            ("100::ffff:ffff:ffff:ffff", .unresolvedOrChanged),
            ("100:0:0:1::", .cloud)
        ]

        for (presentation, expected) in rows {
            XCTAssertEqual(
                DestinationClassifier.classify([try IPAddress(presentation)]),
                expected,
                presentation
            )
        }
    }
}
