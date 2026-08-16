import Foundation
import SharedSupport
import XCTest

@testable import ModelProviders

final class ServerSentEventDecoderTests: XCTestCase {
    func testFramingFragmentationFieldsAndDone() throws {
        let json = "{\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}"
        let wire = Data((
            ": comment\r\n"
                + "event: message\r\n"
                + "id: synthetic\r\n"
                + "data: \(json)\r\n\r\n"
                + "\r\n"
                + "data: [DONE]\r\n\r\n"
        ).utf8)
        for size in [1, 7, 23, wire.count] {
            var decoder = ServerSentEventDecoder()
            var chunks: [TranslationChunk] = []
            for start in stride(from: 0, to: wire.count, by: size) {
                chunks += try decoder.feed(wire[start..<min(start + size, wire.count)])
            }
            chunks += try decoder.finish()
            XCTAssertEqual(chunks, [.content("你好"), .done], "\(size)")
        }
    }

    func testMultipleDataLinesJoinWithLF() throws {
        var decoder = ServerSentEventDecoder()
        let wire = Data((
            "data: {\"choices\":[{\"delta\":\n"
                + "data: {\"content\":\"a\"}}]}\n\n"
                + "data:[DONE]\n\n"
        ).utf8)
        XCTAssertEqual(
            try decoder.feed(wire) + decoder.finish(),
            [.content("a"), .done]
        )
    }

    func testMalformedMissingChoicesEOFAndPostDoneFailClosed() throws {
        let rows = [
            Data("data: not-json\n\n".utf8),
            Data("data: {\"choices\":[]}\n\n".utf8),
            Data("data: {\"other\":true}\n\n".utf8),
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n".utf8),
            Data("data: [DONE]\n\ndata: [DONE]\n\n".utf8)
        ]
        for (index, row) in rows.enumerated() {
            var decoder = ServerSentEventDecoder()
            XCTAssertThrowsError(try {
                _ = try decoder.feed(row)
                _ = try decoder.finish()
            }(), "\(index)") { error in
                XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
            }
        }
    }

    func testEventAndCumulativeContentBounds() throws {
        var oversized = ServerSentEventDecoder()
        XCTAssertThrowsError(try oversized.feed(
            Data("data: ".utf8)
                + Data(repeating: 0x61, count: 1_048_577)
                + Data("\n".utf8)
        )) { error in
            XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
        }

        let unit = String(repeating: "a", count: 1_000_000)
        let object: [String: Any] = [
            "choices": [["delta": ["content": unit]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let event = Data("data: ".utf8) + data + Data("\n\n".utf8)
        var decoder = ServerSentEventDecoder()
        for _ in 0..<4 { _ = try decoder.feed(event) }
        let overflowObject: [String: Any] = [
            "choices": [["delta": [
                "content": String(repeating: "b", count: 194_305)
            ]]]
        ]
        let overflow = Data("data: ".utf8)
            + (try JSONSerialization.data(withJSONObject: overflowObject))
            + Data("\n\n".utf8)
        XCTAssertThrowsError(try decoder.feed(overflow)) { error in
            XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
        }
    }

    func testExactEventPayloadBoundaryAndJoinedFieldOverflow() throws {
        let prefix = Data("{\"choices\":[{\"delta\":{\"content\":\"".utf8)
        let suffix = Data("\"}}]}".utf8)
        let content = Data(
            repeating: 0x61,
            count: 1_048_576 - prefix.count - suffix.count
        )
        let payload = prefix + content + suffix
        XCTAssertEqual(payload.count, 1_048_576)

        for lineEnding in ["\n", "\r\n"] {
            var exact = ServerSentEventDecoder()
            let chunks = try exact.feed(
                Data("data: ".utf8)
                    + payload
                    + Data((lineEnding + lineEnding
                        + "data: [DONE]" + lineEnding + lineEnding).utf8)
            ) + exact.finish()
            XCTAssertEqual(chunks.count, 2, lineEnding.debugDescription)
            XCTAssertEqual(chunks.last, .done, lineEnding.debugDescription)
        }

        var joined = ServerSentEventDecoder()
        _ = try joined.feed(
            Data("data: ".utf8)
                + Data(repeating: 0x61, count: 1_048_576)
                + Data("\n".utf8)
        )
        XCTAssertThrowsError(try joined.feed(Data("data:\n".utf8))) { error in
            XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
        }
    }

    func testExactCumulativeContentBoundaryAndPlusOne() throws {
        func event(_ count: Int, byte: UInt8 = 0x61) -> Data {
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"".utf8)
                + Data(repeating: byte, count: count)
                + Data("\"}}]}\n\n".utf8)
        }

        var baseline = ServerSentEventDecoder()
        for _ in 0..<4 { _ = try baseline.feed(event(1_000_000)) }

        var exact = baseline
        let exactChunks = try exact.feed(event(194_304))
            + exact.feed(Data("data: [DONE]\n\n".utf8))
            + exact.finish()
        XCTAssertEqual(
            exactChunks.compactMap { chunk -> Int? in
                guard case .content(let value) = chunk else { return nil }
                return value.utf8.count
            },
            [194_304]
        )
        XCTAssertEqual(exactChunks.last, .done)

        var overflow = baseline
        XCTAssertThrowsError(try overflow.feed(event(194_305, byte: 0x62))) { error in
            XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
        }
    }
}
