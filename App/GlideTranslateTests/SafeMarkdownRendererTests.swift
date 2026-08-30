import AppKit
import XCTest

@testable import GlideTranslate

final class SafeMarkdownRendererTests: XCTestCase {
    func testRenderedOutputHasNoLinksAttachmentsHTMLOrUnexpectedAttributes() {
        let input = "[x](https://example.invalid) ![y](https://example.invalid/y.png) <b>z</b>"
        let attributed = SafeMarkdownRenderer().render(
            SafeMarkdownParser().parse(input)
        )
        assertOnlySafeAttributes(in: attributed)
        XCTAssertTrue(attributed.string.contains("https://example.invalid"))
        XCTAssertTrue(attributed.string.contains("<b>z</b>"))
    }

    func testRendererUsesOnlyLocalKnownStylesAndDeterministicBlockLayout() throws {
        let document = SafeMarkdownDocument(
            nodes: [
                .paragraph([
                    .text("plain "),
                    .emphasis("italic"),
                    .text(" "),
                    .strong("bold"),
                    .text(" "),
                    .inlineCode("code")
                ]),
                .list([[.text("one")], [.strong("two")]])
            ],
            wasTruncated: false
        )
        let attributed = SafeMarkdownRenderer().render(document)

        XCTAssertEqual(attributed.string, "plain italic bold code\n• one\n• two")
        assertOnlySafeAttributes(in: attributed)
        let italic = try font(in: attributed, substring: "italic")
        let bold = try font(in: attributed, substring: "bold")
        let code = try font(in: attributed, substring: "code")
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(code.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testTruncationNoticeRendersAsVisibleLocalTextWithoutActiveContent() {
        let input = String(repeating: "a", count: SafeMarkdownParser.maximumInputBytes + 1)
        let attributed = SafeMarkdownRenderer().render(
            SafeMarkdownParser().parse(input)
        )

        XCTAssertTrue(attributed.string.hasSuffix(SafeMarkdownParser.truncationNotice))
        XCTAssertNil(attributed.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testTranslationBodyUsesSemanticSerifAndFourPointLineSpacing() throws {
        let attributed = SafeMarkdownRenderer().render(
            SafeMarkdownParser().parse("synthetic reading text")
        )
        let font = try XCTUnwrap(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        let paragraph = try XCTUnwrap(
            attributed.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        let semanticBody = NSFont.preferredFont(forTextStyle: .body)

        XCTAssertEqual(font.pointSize, semanticBody.pointSize, accuracy: 0.001)
        XCTAssertNotEqual(font.familyName, semanticBody.familyName)
        XCTAssertEqual(
            paragraph.lineSpacing,
            GlideVisualTokens.outputAdditionalLineSpacing,
            accuracy: 0.001
        )
    }

    private func assertOnlySafeAttributes(in attributed: NSAttributedString) {
        let permitted: Set<NSAttributedString.Key> = [
            .font,
            .foregroundColor,
            .paragraphStyle
        ]
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, _, _ in
            XCTAssertNil(attributes[.link])
            XCTAssertNil(attributes[.attachment])
            XCTAssertTrue(Set(attributes.keys).isSubset(of: permitted))
        }
    }

    private func font(
        in attributed: NSAttributedString,
        substring: String
    ) throws -> NSFont {
        let range = (attributed.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound)
        return try XCTUnwrap(
            attributed.attribute(.font, at: range.location, effectiveRange: nil)
                as? NSFont
        )
    }
}
