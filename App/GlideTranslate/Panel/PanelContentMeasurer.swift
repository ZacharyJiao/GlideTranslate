import AppKit

@MainActor
enum PanelContentMeasurer {
    static func measure(
        presentation: TranslationPresentation,
        appearance _: NSAppearance?
    ) -> PanelRenderedMeasurement? {
        let collapsed = Dictionary(
            uniqueKeysWithValues: PanelWidthTier.allCases.compactMap { tier in
                completeHeight(
                    presentation: presentation,
                    width: tier.width,
                    sourceExpanded: false
                ).map { (tier, $0) }
            }
        )
        let expanded = Dictionary(
            uniqueKeysWithValues: PanelWidthTier.allCases.compactMap { tier in
                completeHeight(
                    presentation: presentation,
                    width: tier.width,
                    sourceExpanded: true
                ).map { (tier, $0) }
            }
        )
        let measurement = PanelRenderedMeasurement(
            collapsedHeights: collapsed,
            expandedHeights: expanded
        )
        return measurement.isValid ? measurement : nil
    }

    private static func completeHeight(
        presentation: TranslationPresentation,
        width: CGFloat,
        sourceExpanded: Bool
    ) -> CGFloat? {
        let contentWidth = width - PanelSizingPolicy.horizontalContentPadding
        guard contentWidth.isFinite, contentWidth > 0 else { return nil }

        let sourceFont = NSFont.preferredFont(forTextStyle: .callout)
        guard let measuredSource = textHeight(
            NSAttributedString(
                string: presentation.sourceText,
                attributes: [.font: sourceFont]
            ),
            width: contentWidth
        ) else { return nil }
        let sourceLineHeight = ceil(
            sourceFont.ascender - sourceFont.descender + sourceFont.leading
        )
        let sourceTextHeight = sourceExpanded
            ? measuredSource
            : min(measuredSource, sourceLineHeight * 2)

        let renderedOutput = SafeMarkdownRenderer().render(
            SafeMarkdownParser().parse(presentation.resultText)
        )
        guard let outputHeight = textHeight(
            renderedOutput,
            width: contentWidth
        ) else { return nil }

        let headerHeight: CGFloat = 22
        let disclosureHeight: CGFloat = 20
        let outputHeadingHeight: CGFloat = 20
        let metadataHeight: CGFloat = 18
        let actionHeight: CGFloat = 28
        let sourceInternalSpacing: CGFloat = 4
        let verticalGroupSpacing = GlideVisualTokens.panelSpacing * 5
        let verticalPadding = GlideVisualTokens.panelPadding * 2

        let complete = verticalPadding
            + headerHeight
            + sourceTextHeight
            + sourceInternalSpacing
            + disclosureHeight
            + outputHeadingHeight
            + max(28, outputHeight)
            + metadataHeight
            + actionHeight
            + verticalGroupSpacing
        return complete.isFinite && complete >= 0 ? ceil(complete) : nil
    }

    private static func textHeight(
        _ attributed: NSAttributedString,
        width: CGFloat
    ) -> CGFloat? {
        guard width.isFinite, width > 0 else { return nil }
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        guard bounds.height.isFinite, bounds.height >= 0 else { return nil }
        return ceil(bounds.height)
    }
}
