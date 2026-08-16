import Foundation
import SharedSupport
import XCTest

@testable import ModelProviders

final class OllamaStreamDecoderTests: XCTestCase {
    func testFragmentationUtf8AndMultipleLines() throws {
        let wire = Data((
            "{\"message\":{\"content\":\"你\"},\"done\":false}\n"
                + "\n"
                + "{\"message\":{\"content\":\"好\"},\"done\":false}\r\n"
                + "{\"message\":{\"content\":\"\"},\"done\":true}\n"
        ).utf8)
        for size in [1, 7, 19, wire.count] {
            var decoder = OllamaStreamDecoder()
            var chunks: [TranslationChunk] = []
            for start in stride(from: 0, to: wire.count, by: size) {
                chunks += try decoder.feed(wire[start..<min(start + size, wire.count)])
            }
            chunks += try decoder.finish()
            XCTAssertEqual(chunks, [.content("你"), .content("好"), .done], "\(size)")
        }
    }

    func testMalformedErrorPrematureEOFAndBytesAfterDoneFailClosed() throws {
        let rows = [
            Data("not-json\n".utf8),
            Data("{\"error\":\"SYNTHETIC_BODY\",\"done\":false}\n".utf8),
            Data("{\"message\":{\"content\":\"a\"},\"done\":false}\n".utf8),
            Data((
                "{\"message\":{\"content\":\"\"},\"done\":true}\n"
                    + "{\"message\":{\"content\":\"late\"},\"done\":false}\n"
            ).utf8)
        ]
        for (index, row) in rows.enumerated() {
            var decoder = OllamaStreamDecoder()
            XCTAssertThrowsError(try {
                _ = try decoder.feed(row)
                _ = try decoder.finish()
            }(), "\(index)") { error in
                XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
                XCTAssertFalse(String(describing: error).contains("SYNTHETIC_BODY"))
            }
        }
    }

    func testLineAndCumulativeContentBounds() throws {
        var oversizedLine = OllamaStreamDecoder()
        XCTAssertThrowsError(try oversizedLine.feed(
            Data(repeating: 0x61, count: 1_048_577)
        )) { error in
            XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
        }

        let unit = String(repeating: "a", count: 1_000_000)
        let line = try JSONSerialization.data(withJSONObject: [
            "message": ["content": unit],
            "done": false
        ]) + Data("\n".utf8)
        var decoder = OllamaStreamDecoder()
        for _ in 0..<4 { _ = try decoder.feed(line) }
        let overflow = try JSONSerialization.data(withJSONObject: [
            "message": ["content": String(repeating: "b", count: 194_305)],
            "done": false
        ]) + Data("\n".utf8)
        XCTAssertThrowsError(try decoder.feed(overflow)) { error in
            XCTAssertEqual(error as? SanitizedFailure, .providerProtocolFailure)
        }
    }
}
