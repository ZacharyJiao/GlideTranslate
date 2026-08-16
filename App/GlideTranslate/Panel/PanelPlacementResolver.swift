import CoreGraphics

enum PanelPlacementReason: Equatable, Sendable {
    case below
    case above
    case pointer
    case clamped
}

struct PanelPlacement: Equatable, Sendable {
    let frame: CGRect
    let displayIndex: Int
    let reason: PanelPlacementReason

    init(frame: CGRect, displayIndex: Int, reason: PanelPlacementReason) {
        self.frame = frame
        self.displayIndex = displayIndex
        self.reason = reason
    }
}

enum PanelPlacementResolver {
    static let defaultPanelSize = CGSize(width: 420, height: 240)
    static let defaultGap: CGFloat = 12

    static func resolve(
        selection: CGRect?,
        pointer: CGPoint,
        visibleFrames: [CGRect],
        panelSize: CGSize = defaultPanelSize,
        gap: CGFloat = defaultGap
    ) -> PanelPlacement? {
        let usableDisplays = visibleFrames.enumerated().filter {
            $0.element.isUsableVisibleFrame
        }
        guard let firstDisplay = usableDisplays.first else { return nil }

        let usableSelection = selection.flatMap { candidate in
            candidate.isFiniteAndNonnegative ? candidate : nil
        }
        let usablePointer = pointer.isFinite ? pointer : nil
        let fallbackCenter = CGPoint(
            x: firstDisplay.element.midX,
            y: firstDisplay.element.midY
        )
        let anchor = usableSelection.map {
            CGPoint(x: $0.midX, y: $0.midY)
        } ?? usablePointer ?? fallbackCenter

        let chosenDisplay = usableDisplays.first(where: {
            $0.element.contains(anchor)
        }) ?? usableDisplays.min(by: {
            $0.element.distanceSquared(to: anchor)
                < $1.element.distanceSquared(to: anchor)
        }) ?? firstDisplay
        let visibleFrame = chosenDisplay.element

        let requestedSize = panelSize.isFiniteAndPositive
            ? panelSize
            : defaultPanelSize
        let fittedSize = CGSize(
            width: min(requestedSize.width, visibleFrame.width),
            height: min(requestedSize.height, visibleFrame.height)
        )
        let sizeWasClamped = fittedSize != requestedSize
        let effectiveGap = gap.isFinite && gap >= 0 ? gap : defaultGap

        if let selection = usableSelection {
            let candidateX = clamp(
                selection.minX,
                lower: visibleFrame.minX,
                upper: visibleFrame.maxX - fittedSize.width
            )
            let xWasClamped = candidateX != selection.minX
            let below = CGRect(
                x: candidateX,
                y: selection.minY - effectiveGap - fittedSize.height,
                width: fittedSize.width,
                height: fittedSize.height
            )
            if visibleFrame.contains(below), !below.intersects(selection) {
                return PanelPlacement(
                    frame: below,
                    displayIndex: chosenDisplay.offset,
                    reason: sizeWasClamped || xWasClamped ? .clamped : .below
                )
            }

            let above = CGRect(
                x: candidateX,
                y: selection.maxY + effectiveGap,
                width: fittedSize.width,
                height: fittedSize.height
            )
            if visibleFrame.contains(above), !above.intersects(selection) {
                return PanelPlacement(
                    frame: above,
                    displayIndex: chosenDisplay.offset,
                    reason: sizeWasClamped || xWasClamped ? .clamped : .above
                )
            }
        }

        let pointerAnchor = usablePointer ?? CGPoint(
            x: visibleFrame.midX,
            y: visibleFrame.midY
        )
        let pointerFrame = CGRect(
            x: pointerAnchor.x + effectiveGap,
            y: pointerAnchor.y - fittedSize.height - effectiveGap,
            width: fittedSize.width,
            height: fittedSize.height
        )
        let finalFrame = pointerFrame.clamped(to: visibleFrame)
        return PanelPlacement(
            frame: finalFrame,
            displayIndex: chosenDisplay.offset,
            reason: sizeWasClamped || finalFrame != pointerFrame ? .clamped : .pointer
        )
    }

    private static func clamp(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        min(max(value, lower), upper)
    }
}

private extension CGPoint {
    var isFinite: Bool { x.isFinite && y.isFinite }
}

private extension CGSize {
    var isFiniteAndPositive: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

private extension CGRect {
    var isFiniteAndNonnegative: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && size.width >= 0
            && size.height >= 0
    }

    var isUsableVisibleFrame: Bool {
        isFiniteAndNonnegative && width > 0 && height > 0
    }

    func distanceSquared(to point: CGPoint) -> CGFloat {
        let nearestX = min(max(point.x, minX), maxX)
        let nearestY = min(max(point.y, minY), maxY)
        let deltaX = point.x - nearestX
        let deltaY = point.y - nearestY
        return deltaX * deltaX + deltaY * deltaY
    }

    func clamped(to visibleFrame: CGRect) -> CGRect {
        let fittedWidth = min(width, visibleFrame.width)
        let fittedHeight = min(height, visibleFrame.height)
        return CGRect(
            x: min(
                max(minX, visibleFrame.minX),
                visibleFrame.maxX - fittedWidth
            ),
            y: min(
                max(minY, visibleFrame.minY),
                visibleFrame.maxY - fittedHeight
            ),
            width: fittedWidth,
            height: fittedHeight
        )
    }
}
