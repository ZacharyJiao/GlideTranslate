import CoreGraphics

enum PanelWidthTier: String, CaseIterable, Equatable, Hashable, Sendable {
    case compact
    case standard
    case reading

    var width: CGFloat {
        switch self {
        case .compact: 380
        case .standard: 460
        case .reading: 560
        }
    }
}

enum PanelActionLayout: Equatable, Sendable {
    case full
    case compactOverflow
}

struct PanelRenderedMeasurement: Equatable, Sendable {
    let collapsedHeights: [PanelWidthTier: CGFloat]
    let expandedHeights: [PanelWidthTier: CGFloat]

    func height(for tier: PanelWidthTier, sourceExpanded: Bool) -> CGFloat? {
        (sourceExpanded ? expandedHeights : collapsedHeights)[tier]
    }

    var isValid: Bool {
        PanelWidthTier.allCases.allSatisfy { tier in
            guard let collapsed = collapsedHeights[tier],
                  let expanded = expandedHeights[tier] else { return false }
            return collapsed.isFinite && collapsed >= 0
                && expanded.isFinite && expanded >= 0
        }
    }
}

struct PanelContentMeasurement: Equatable, Sendable {
    let chromeHeight: CGFloat
    let collapsedSourceHeight: CGFloat
    let expandedSourceHeight: CGFloat
    let resultHeights: [PanelWidthTier: CGFloat]
    let verticalSpacing: CGFloat

    init(
        chromeHeight: CGFloat,
        collapsedSourceHeight: CGFloat,
        expandedSourceHeight: CGFloat,
        resultHeights: [PanelWidthTier: CGFloat],
        verticalSpacing: CGFloat = 0
    ) {
        self.chromeHeight = chromeHeight
        self.collapsedSourceHeight = collapsedSourceHeight
        self.expandedSourceHeight = expandedSourceHeight
        self.resultHeights = resultHeights
        self.verticalSpacing = verticalSpacing
    }

    func idealHeight(
        for tier: PanelWidthTier,
        sourceExpanded: Bool = false
    ) -> CGFloat? {
        guard let resultHeight = resultHeights[tier],
              resultHeight.isFinite,
              resultHeight >= 0,
              chromeHeight.isFinite,
              chromeHeight >= 0,
              collapsedSourceHeight.isFinite,
              collapsedSourceHeight >= 0,
              expandedSourceHeight.isFinite,
              expandedSourceHeight >= 0,
              verticalSpacing.isFinite,
              verticalSpacing >= 0 else {
            return nil
        }
        let sourceHeight = sourceExpanded
            ? expandedSourceHeight
            : collapsedSourceHeight
        return chromeHeight + sourceHeight + resultHeight + verticalSpacing
    }
}

struct PanelSizingConstraints: Equatable, Sendable {
    let visibleFrame: CGRect
    let availableAnchorSpace: CGFloat

    init(visibleFrame: CGRect, availableAnchorSpace: CGFloat) {
        self.visibleFrame = visibleFrame
        self.availableAnchorSpace = availableAnchorSpace
    }
}

struct PanelSizingDecision: Equatable, Sendable {
    let tier: PanelWidthTier
    let size: CGSize
    let desiredHeight: CGFloat
    let maximumHeight: CGFloat
    let isHeightCapped: Bool
    let usesFallback: Bool
    let actionLayout: PanelActionLayout
    let actionBarAvailableWidth: CGFloat

    init(
        tier: PanelWidthTier,
        size: CGSize,
        desiredHeight: CGFloat,
        maximumHeight: CGFloat,
        isHeightCapped: Bool,
        usesFallback: Bool,
        actionLayout: PanelActionLayout? = nil
    ) {
        self.tier = tier
        self.size = size
        self.desiredHeight = desiredHeight
        self.maximumHeight = maximumHeight
        self.isHeightCapped = isHeightCapped
        self.usesFallback = usesFallback
        actionBarAvailableWidth = PanelSizingPolicy.actionBarAvailableWidth(
            for: size.width
        )
        self.actionLayout = actionLayout
            ?? PanelSizingPolicy.actionLayout(for: size.width)
    }
}

enum PanelSizingPolicy {
    static let initialSize = CGSize(width: 380, height: 190)
    static let fallbackSize = CGSize(width: 420, height: 240)
    static let minimumSize = initialSize
    static let minimumHeight: CGFloat = 190
    static let maximumHeight: CGFloat = 560
    static let visibleHeightFraction: CGFloat = 0.58
    static let widthSafetyMargin: CGFloat = 24
    static let compactHeightThreshold: CGFloat = 320
    static let standardHeightThreshold: CGFloat = 440
    static let horizontalContentPadding: CGFloat = 32
    static let fullActionBarMinimumWidth: CGFloat = 428

    static func targetSize(
        for measurement: PanelContentMeasurement,
        constraints: PanelSizingConstraints,
        sourceExpanded: Bool = false
    ) -> PanelSizingDecision {
        let collapsedHeights = Dictionary(
            uniqueKeysWithValues: PanelWidthTier.allCases.compactMap { tier in
                measurement.idealHeight(for: tier, sourceExpanded: false).map {
                    (tier, $0)
                }
            }
        )
        let expandedHeights = Dictionary(
            uniqueKeysWithValues: PanelWidthTier.allCases.compactMap { tier in
                measurement.idealHeight(for: tier, sourceExpanded: true).map {
                    (tier, $0)
                }
            }
        )
        return targetSize(
            for: PanelRenderedMeasurement(
                collapsedHeights: collapsedHeights,
                expandedHeights: expandedHeights
            ),
            constraints: constraints,
            sourceExpanded: sourceExpanded
        )
    }

    static func targetSize(
        for measurement: PanelRenderedMeasurement,
        constraints: PanelSizingConstraints,
        sourceExpanded: Bool = false
    ) -> PanelSizingDecision {
        guard constraints.visibleFrame.isFiniteAndUsable,
              constraints.availableAnchorSpace.isFinite,
              constraints.availableAnchorSpace > 0,
              measurement.isValid,
              let compactCollapsedHeight = measurement.height(
                  for: .compact,
                  sourceExpanded: false
              ),
              let standardCollapsedHeight = measurement.height(
                  for: .standard,
                  sourceExpanded: false
              ) else {
            return fallbackDecision(for: constraints)
        }

        let tier: PanelWidthTier
        if compactCollapsedHeight <= compactHeightThreshold {
            tier = .compact
        } else if standardCollapsedHeight <= standardHeightThreshold {
            tier = .standard
        } else {
            tier = .reading
        }
        guard let chosenIdealHeight = measurement.height(
            for: tier,
            sourceExpanded: sourceExpanded
        ) else {
            return fallbackDecision(for: constraints)
        }
        let desiredHeight = max(minimumHeight, chosenIdealHeight)
        let maximumHeight = maximumAllowedHeight(
            visibleFrame: constraints.visibleFrame,
            availableAnchorSpace: constraints.availableAnchorSpace
        )
        let height = min(desiredHeight, maximumHeight)
        let width = min(
            tier.width,
            max(1, constraints.visibleFrame.width - widthSafetyMargin)
        )
        return PanelSizingDecision(
            tier: tier,
            size: CGSize(width: width, height: height),
            desiredHeight: desiredHeight,
            maximumHeight: maximumHeight,
            isHeightCapped: height + 0.001 < desiredHeight,
            usesFallback: false
        )
    }

    static func actionBarAvailableWidth(for panelWidth: CGFloat) -> CGFloat {
        max(0, panelWidth - horizontalContentPadding)
    }

    static func actionLayout(for panelWidth: CGFloat) -> PanelActionLayout {
        actionBarAvailableWidth(for: panelWidth) < fullActionBarMinimumWidth
            ? .compactOverflow
            : .full
    }

    private static func fallbackDecision(
        for constraints: PanelSizingConstraints
    ) -> PanelSizingDecision {
        let usableFrame = constraints.visibleFrame.isFiniteAndUsable
            ? constraints.visibleFrame
            : CGRect(x: 0, y: 0, width: fallbackSize.width, height: fallbackSize.height)
        let width = min(
            fallbackSize.width,
            max(1, usableFrame.width - widthSafetyMargin)
        )
        let height = min(
            fallbackSize.height,
            max(1, usableFrame.height),
            max(1, constraints.availableAnchorSpace)
        )
        let maximumHeight = max(
            1,
            min(
                maximumHeight,
                usableFrame.height * visibleHeightFraction,
                max(1, constraints.availableAnchorSpace)
            )
        )
        return PanelSizingDecision(
            tier: .compact,
            size: CGSize(width: width, height: height),
            desiredHeight: fallbackSize.height,
            maximumHeight: maximumHeight,
            isHeightCapped: height + 0.001 < fallbackSize.height,
            usesFallback: true
        )
    }

    private static func maximumAllowedHeight(
        visibleFrame: CGRect,
        availableAnchorSpace: CGFloat
    ) -> CGFloat {
        max(
            1,
            min(
                maximumHeight,
                visibleFrame.height * visibleHeightFraction,
                availableAnchorSpace
            )
        )
    }
}

extension CGRect {
    var isFiniteAndUsable: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}
