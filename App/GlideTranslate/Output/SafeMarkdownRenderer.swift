import AppKit

struct SafeMarkdownRenderer: Sendable {
    func render(_ document: SafeMarkdownDocument) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")

        for (blockIndex, node) in document.nodes.enumerated() {
            if blockIndex > 0 {
                result.append(attributed("\n", font: baseFont, style: paragraphStyle))
            }
            switch node {
            case let .paragraph(inlines):
                append(inlines, to: result, style: paragraphStyle)
            case let .list(items):
                for (itemIndex, item) in items.enumerated() {
                    if itemIndex > 0 {
                        result.append(attributed("\n", font: baseFont, style: listStyle))
                    }
                    result.append(attributed("• ", font: baseFont, style: listStyle))
                    append(item, to: result, style: listStyle)
                }
            }
        }

        return result.copy() as! NSAttributedString
    }

    private func append(
        _ inlines: [InlineNode],
        to result: NSMutableAttributedString,
        style: NSParagraphStyle
    ) {
        for inline in inlines {
            switch inline {
            case let .text(value):
                result.append(attributed(value, font: baseFont, style: style))
            case let .emphasis(value):
                result.append(attributed(value, font: emphasisFont, style: style))
            case let .strong(value):
                result.append(attributed(value, font: strongFont, style: style))
            case let .inlineCode(value):
                result.append(attributed(value, font: codeFont, style: style))
            }
        }
    }

    private func attributed(
        _ value: String,
        font: NSFont,
        style: NSParagraphStyle
    ) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
        )
    }

    private var baseFont: NSFont {
        let semanticBody = NSFont.preferredFont(forTextStyle: .body)
        guard let serifDescriptor = semanticBody.fontDescriptor.withDesign(.serif),
              let serif = NSFont(
                  descriptor: serifDescriptor,
                  size: semanticBody.pointSize
              ) else {
            return semanticBody
        }
        return serif
    }

    private var emphasisFont: NSFont {
        NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
    }

    private var strongFont: NSFont {
        NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    }

    private var codeFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
    }

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = GlideVisualTokens.outputAdditionalLineSpacing
        style.paragraphSpacing = 8
        return style.copy() as! NSParagraphStyle
    }

    private var listStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = GlideVisualTokens.outputAdditionalLineSpacing
        style.paragraphSpacing = 4
        style.headIndent = 14
        style.firstLineHeadIndent = 0
        return style.copy() as! NSParagraphStyle
    }
}
