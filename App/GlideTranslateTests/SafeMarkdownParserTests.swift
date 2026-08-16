import XCTest

@testable import GlideTranslate

final class SafeMarkdownParserTests: XCTestCase {
    func testSafeSyntaxMatrix() {
        let rows: [MarkdownRow] = [
            .init("paragraph", kinds: [.paragraph, .text]),
            .init("*emphasis*", kinds: [.paragraph, .emphasis]),
            .init("**strong**", kinds: [.paragraph, .strong]),
            .init("- first\n- second", kinds: [.list, .listItem, .text]),
            .init("`code`", kinds: [.paragraph, .inlineCode]),
            .literal("<script>run()</script>"),
            .literal("![image](https://example.invalid/image.png)"),
            .literal("[link](https://example.invalid)"),
            .literal("<https://example.invalid>"),
            .literal("<div>html</div>"),
            .literal("```\ncode block\n```"),
            .literal("# heading")
        ]

        for row in rows {
            let document = SafeMarkdownParser().parse(row.input)
            XCTAssertEqual(document.testKinds, row.expectedKinds, row.input)
            if row.expectsLiteral {
                XCTAssertEqual(document.literalString, row.input, row.input)
            }
            XCTAssertFalse(document.wasTruncated, row.input)
        }
    }

    func testParagraphListBoundariesAndInlinePrecedence() {
        let input = "First **bold** and *italic* and `code`\ncontinued\n\n- one\n- two\n\nLast"

        XCTAssertEqual(
            SafeMarkdownParser().parse(input).nodes,
            [
                .paragraph([
                    .text("First "),
                    .strong("bold"),
                    .text(" and "),
                    .emphasis("italic"),
                    .text(" and "),
                    .inlineCode("code"),
                    .text("\ncontinued")
                ]),
                .list([[.text("one")], [.text("two")]]),
                .paragraph([.text("Last")])
            ]
        )
    }

    func testUnmatchedAndUnsupportedMarkersRemainLiteralText() {
        let inputs = [
            "unmatched *marker",
            "unmatched **marker",
            "unmatched `marker",
            "```\nfenced **content**\n```"
        ]

        for input in inputs {
            let document = SafeMarkdownParser().parse(input)
            XCTAssertEqual(document.nodes, [.paragraph([.text(input)])], input)
        }
    }

    func testCRLFAndCRAreLineBoundaries() {
        XCTAssertEqual(
            SafeMarkdownParser().parse("one\r\n\r\n- two\r- three").nodes,
            [
                .paragraph([.text("one")]),
                .list([[.text("two")], [.text("three")]])
            ]
        )
    }

    func testFourMiBUTF8BoundaryIsInclusiveAndOverflowKeepsValidLiteralPrefix() {
        let fourMiB = 4 * 1_024 * 1_024
        XCTAssertEqual(SafeMarkdownParser.maximumInputBytes, fourMiB)
        let exact = String(repeating: "a", count: fourMiB)
        let exactDocument = SafeMarkdownParser().parse(exact)
        XCTAssertFalse(exactDocument.wasTruncated)
        XCTAssertEqual(exactDocument.literalString.utf8.count, fourMiB)

        let activePrefix = "**bold** `code` [x](https://example.invalid) <b>html</b>\n"
        let expectedPrefix = activePrefix + String(
            repeating: "a",
            count: fourMiB - activePrefix.utf8.count
        )
        let overflow = expectedPrefix + "é"
        let overflowDocument = SafeMarkdownParser().parse(overflow)
        assertLiteralTruncation(overflowDocument, prefix: expectedPrefix)
        XCTAssertEqual(expectedPrefix.utf8.count, fourMiB)
    }

    func testTwentyThousandNodeBoundaryIsInclusiveAndOverflowFallsBackToLiteral() {
        XCTAssertEqual(SafeMarkdownParser.maximumNodeCount, 20_000)
        let hostile = "**x** [x](https://example.invalid) <b>html</b> *e*"
        let common = [hostile] + Array(repeating: "x", count: 9_997)
        let exact = (common + ["x"]).joined(separator: "\n\n")
        let exactDocument = SafeMarkdownParser().parse(exact)
        XCTAssertFalse(exactDocument.wasTruncated)
        XCTAssertEqual(exactDocument.nodeCount, 20_000)

        let overflow = (common + ["*x* y"]).joined(separator: "\n\n")
        let overflowDocument = SafeMarkdownParser().parse(overflow)
        assertLiteralTruncation(overflowDocument, prefix: overflow)
        XCTAssertEqual(overflowDocument.nodeCount, 4)

    }

    func testListContainerAndItemsParticipateInTwentyThousandNodeLimit() {
        let exact = (["- *x* y"] + Array(repeating: "- x", count: 9_998))
            .joined(separator: "\n")
        let exactDocument = SafeMarkdownParser().parse(exact)
        XCTAssertFalse(exactDocument.wasTruncated)
        XCTAssertEqual(exactDocument.nodeCount, 20_000)
        XCTAssertEqual(exactDocument.nodes.count, 1)

        let overflow = Array(repeating: "- x", count: 10_000)
            .joined(separator: "\n")
        let overflowDocument = SafeMarkdownParser().parse(overflow)
        assertLiteralTruncation(overflowDocument, prefix: overflow)
        XCTAssertEqual(overflowDocument.nodeCount, 4)

        let containerOverflow = Array(repeating: "- x", count: 9_999)
            .joined(separator: "\n") + "\n\nx"
        let containerOverflowDocument = SafeMarkdownParser().parse(containerOverflow)
        assertLiteralTruncation(
            containerOverflowDocument,
            prefix: containerOverflow
        )
        XCTAssertEqual(containerOverflowDocument.nodeCount, 4)
    }

    private func assertLiteralTruncation(
        _ document: SafeMarkdownDocument,
        prefix expectedPrefix: String
    ) {
        XCTAssertTrue(document.wasTruncated)
        XCTAssertEqual(document.nodes.count, 2)
        guard case let .some(.paragraph(firstInlines)) = document.nodes.first,
              firstInlines.count == 1,
              case let .text(prefix) = firstInlines[0],
              case let .some(.paragraph(lastInlines)) = document.nodes.last,
              lastInlines.count == 1,
              case let .text(notice) = lastInlines[0] else {
            return XCTFail("Expected literal prefix and truncation notice paragraphs")
        }
        XCTAssertTrue(prefix == expectedPrefix)
        XCTAssertEqual(notice, SafeMarkdownParser.truncationNotice)
    }
}

private struct MarkdownRow {
    let input: String
    let expectedKinds: Set<TestMarkdownKind>
    let expectsLiteral: Bool

    init(_ input: String, kinds: Set<TestMarkdownKind>) {
        self.input = input
        expectedKinds = kinds
        expectsLiteral = false
    }

    static func literal(_ input: String) -> Self {
        MarkdownRow(
            input: input,
            expectedKinds: [.paragraph, .text],
            expectsLiteral: true
        )
    }

    private init(
        input: String,
        expectedKinds: Set<TestMarkdownKind>,
        expectsLiteral: Bool
    ) {
        self.input = input
        self.expectedKinds = expectedKinds
        self.expectsLiteral = expectsLiteral
    }
}

private enum TestMarkdownKind: Hashable {
    case paragraph
    case list
    case listItem
    case text
    case emphasis
    case strong
    case inlineCode
}

private extension SafeMarkdownDocument {
    var literalString: String {
        nodes.map { node in
            switch node {
            case let .paragraph(inlines):
                return inlines.literalString
            case let .list(items):
                return items.map { "- " + $0.literalString }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    var testKinds: Set<TestMarkdownKind> {
        var result: Set<TestMarkdownKind> = []
        for node in nodes {
            switch node {
            case let .paragraph(inlines):
                result.insert(.paragraph)
                result.formUnion(inlines.testKinds)
            case let .list(items):
                result.insert(.list)
                result.insert(.listItem)
                for item in items {
                    result.formUnion(item.testKinds)
                }
            }
        }
        return result
    }
}

private extension Array where Element == InlineNode {
    var literalString: String {
        map { node in
            switch node {
            case let .text(value),
                 let .emphasis(value),
                 let .strong(value),
                 let .inlineCode(value):
                return value
            }
        }.joined()
    }

    var testKinds: Set<TestMarkdownKind> {
        Set(map { node in
            switch node {
            case .text: .text
            case .emphasis: .emphasis
            case .strong: .strong
            case .inlineCode: .inlineCode
            }
        })
    }
}
