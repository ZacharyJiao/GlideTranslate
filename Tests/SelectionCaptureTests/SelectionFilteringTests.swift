import SharedSupport
import XCTest
@testable import SelectionCapture

final class SelectionFilteringTests: XCTestCase {
    func testFilterMatrix() {
        let limitText = String(repeating: "a", count: 2_000)
        let overLimit = String(repeating: "a", count: 2_001)
        let rows: [(String, Result<String, SelectionFilterFailure>)] = [
            ("", .failure(.empty)),
            (" \n\t ", .failure(.empty)),
            ("12345", .failure(.pureNumber)),
            ("-12.5", .failure(.pureNumber)),
            ("１２３", .failure(.pureNumber)),
            ("!", .failure(.singlePunctuation)),
            ("。", .failure(.singlePunctuation)),
            (" hello ", .success("hello")),
            ("你好", .success("你好")),
            ("123 apples", .success("123 apples")),
            (limitText, .success(limitText)),
            (overLimit, .failure(.tooLong))
        ]
        for (input, expected) in rows {
            XCTAssertEqual(SelectionFilter(limit: 2_000).apply(input), expected)
        }
    }
}
