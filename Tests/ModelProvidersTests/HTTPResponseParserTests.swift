import Foundation
import XCTest

@testable import ModelProviders

final class HTTPResponseParserTests: XCTestCase {
    func testContentLengthAcrossEveryByteBoundary() throws {
        let bytes = Data(
            ("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"
                + "X-Synthetic: discarded\r\nLocation: /next\r\n\r\nhello").utf8
        )
        var parser = HTTPResponseParser()
        var events: [HTTPResponseEvent] = []
        for byte in bytes {
            events += try parser.feed(Data([byte]))
        }
        events += try parser.finish()
        XCTAssertEqual(events.first?.head?.status, 200)
        XCTAssertEqual(events.first?.head?.location, "/next")
        XCTAssertEqual(events.bodyBytes, Data("hello".utf8))
        XCTAssertEqual(events.last, .complete)
    }

    func testChunkedExtensionsAndFragmentation() throws {
        let wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "2;synthetic=yes\r\nhe\r\n3\r\nllo\r\n0\r\nX-End: yes\r\n\r\n"
        let bytes = Data(wire.utf8)
        var parser = HTTPResponseParser()
        var events: [HTTPResponseEvent] = []
        var offset = 0
        for size in [1, 1, 4, 2, 7, 3, 11, 5, 99] {
            guard offset < bytes.count else { break }
            let end = min(bytes.count, offset + size)
            events += try parser.feed(bytes[offset..<end])
            offset = end
        }
        if offset < bytes.count {
            events += try parser.feed(bytes[offset..<bytes.count])
        }
        XCTAssertEqual(events.bodyBytes, Data("hello".utf8))
        XCTAssertEqual(events.last, .complete)
    }

    func testQuotedChunkExtensionsAreFragmentationIndependent() throws {
        let wire = Data(
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "1;foo=\"a;b\";bar=\"a\\\"b\"\r\na\r\n0\r\n\r\n").utf8
        )
        for fragments in [[wire], wire.map { Data([$0]) }] {
            var parser = HTTPResponseParser()
            var events: [HTTPResponseEvent] = []
            for fragment in fragments {
                events += try parser.feed(fragment)
            }
            XCTAssertEqual(events.bodyBytes, Data("a".utf8))
            XCTAssertEqual(events.last, .complete)
        }
    }

    func testCloseDelimitedBodyCompletesOnlyAtCleanEOF() throws {
        var parser = HTTPResponseParser()
        var events = try parser.feed(
            Data("HTTP/1.1 200 OK\r\nX-Synthetic: yes\r\n\r\nabc".utf8)
        )
        XCTAssertFalse(parser.isComplete)
        events += try parser.feed(Data("def".utf8))
        events += try parser.finish()
        XCTAssertEqual(events.bodyBytes, Data("abcdef".utf8))
        XCTAssertEqual(events.last, .complete)
    }

    func testInformationalResponsePrecedesOneFinalResponse() throws {
        let bytes = Data(
            ("HTTP/1.1 100 Continue\r\nX-Info: yes\r\n\r\n"
                + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").utf8
        )
        var parser = HTTPResponseParser()
        let events = try parser.feed(bytes)
        XCTAssertEqual(events.compactMap(\.head?.status), [100, 200])
        XCTAssertEqual(events.bodyBytes, Data("ok".utf8))
        XCTAssertEqual(events.last, .complete)
    }

    func testHeaderBoundary() throws {
        for acceptedBytes in [65_536, 65_537] {
            let prefix = "HTTP/1.1 200 OK\r\nX-Pad: "
            let suffix = "\r\n\r\n"
            let padding = String(
                repeating: "a",
                count: acceptedBytes - prefix.utf8.count - suffix.utf8.count
            )
            var parser = HTTPResponseParser()
            if acceptedBytes == 65_536 {
                XCTAssertNoThrow(
                    try parser.feed(Data((prefix + padding + suffix).utf8))
                )
            } else {
                XCTAssertThrowsError(
                    try parser.feed(Data((prefix + padding + suffix).utf8))
                ) { error in
                    XCTAssertEqual(error as? HTTPParserFailure, .protocolViolation)
                }
            }
        }
    }

    func testInvalidLengthChunkAndEOFInputsFailClosed() throws {
        let rows = [
            "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;=bad\r\na\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFF\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\naX\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
            "HTTP/1.1 200 OK\r\n folded: no\r\n\r\n"
        ]
        for row in rows {
            var parser = HTTPResponseParser()
            XCTAssertThrowsError(try parser.feed(Data(row.utf8))) { error in
                XCTAssertEqual(error as? HTTPParserFailure, .protocolViolation)
            }
        }

        var fixed = HTTPResponseParser()
        _ = try fixed.feed(
            Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab".utf8)
        )
        XCTAssertThrowsError(try fixed.finish())

        var chunked = HTTPResponseParser()
        _ = try chunked.feed(
            Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na".utf8)
        )
        XCTAssertThrowsError(try chunked.finish())
    }

    func testControlBytesAndMalformedTrailersFailClosed() throws {
        let rows = [
            Data("HTTP/1.1 200 O\u{7}K\r\nContent-Length: 0\r\n\r\n".utf8),
            Data("HTTP/1.1 200 OK\r\nX-Bad: value\u{7}\r\nContent-Length: 0\r\n\r\n".utf8),
            Data("HTTP/1.1 200 OK\r\nX-Bad: value\u{7f}\r\nContent-Length: 0\r\n\r\n".utf8),
            Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;bad=\u{7}x\r\na\r\n0\r\n\r\n".utf8),
            Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nBad-Trailer: value\u{7f}\r\n\r\n".utf8)
        ]
        for row in rows {
            var parser = HTTPResponseParser()
            XCTAssertThrowsError(try parser.feed(row)) { error in
                XCTAssertEqual(error as? HTTPParserFailure, .protocolViolation)
            }
        }
    }

    func testInformationalAndSharedMetadataBounds() throws {
        var switching = HTTPResponseParser()
        XCTAssertThrowsError(try switching.feed(
            Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8)
        ))

        var informational = HTTPResponseParser()
        let one = "HTTP/1.1 100 Continue\r\n\r\n"
        XCTAssertThrowsError(try informational.feed(
            Data((String(repeating: one, count: 9)
                + "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").utf8)
        ))

        let headPrefix = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Pad: "
        let headPadding = String(repeating: "h", count: 39_000)
        let trailerPrefix = "0\r\nX-Trailer: "
        let trailerPadding = String(repeating: "t", count: 30_000)
        var sharedBudget = HTTPResponseParser()
        XCTAssertThrowsError(try sharedBudget.feed(Data(
            (headPrefix + headPadding + "\r\n\r\n"
                + trailerPrefix + trailerPadding + "\r\n\r\n").utf8
        )))
    }

    func testCoalescedAndBytewiseChunkMetadataBothRespectSharedBudget() throws {
        let extensionValue = String(repeating: "a", count: 100)
        let chunk = "1;x=\(extensionValue)\r\na\r\n"
        let wire = Data(
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                + String(repeating: chunk, count: 700)
                + "0\r\n\r\n").utf8
        )
        for fragments in [[wire], wire.map { Data([$0]) }] {
            var parser = HTTPResponseParser()
            XCTAssertThrowsError(try fragments.forEach { fragment in
                _ = try parser.feed(fragment)
            }) { error in
                XCTAssertEqual(error as? HTTPParserFailure, .protocolViolation)
            }
        }
    }

    func testDecodedEventAndCumulativeBounds() throws {
        var eventParser = HTTPResponseParser()
        let eventHeader = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n".utf8
        )
        _ = try eventParser.feed(eventHeader)
        XCTAssertThrowsError(
            try eventParser.feed(Data(repeating: 0x61, count: 1_048_577))
        )

        var cumulativeParser = HTTPResponseParser()
        _ = try cumulativeParser.feed(
            Data("HTTP/1.1 200 OK\r\nContent-Length: 4194305\r\n\r\n".utf8)
        )
        for _ in 0..<4 {
            _ = try cumulativeParser.feed(Data(repeating: 0x61, count: 1_048_576))
        }
        XCTAssertThrowsError(try cumulativeParser.feed(Data([0x61])))
    }
}

private extension Array where Element == HTTPResponseEvent {
    var bodyBytes: Data {
        reduce(into: Data()) { result, event in
            if case .body(let bytes) = event { result.append(bytes) }
        }
    }
}

private extension HTTPResponseEvent {
    var head: HTTPResponseHead? {
        guard case .head(let head) = self else { return nil }
        return head
    }
}
