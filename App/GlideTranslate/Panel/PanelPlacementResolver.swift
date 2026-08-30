import CoreGraphics

enum PanelPlacementReason: Equatable, Sendable {
    case below
    case above
    case pointer
    case clamped
}

enum PanelAnchorSide: Equatable, Sendable {
    case below
    case above
    case pointer
}

enum PanelPointerCorner: Equatable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct PanelDisplay: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
}

struct PanelPlacement: Equatable, Sendable {
    let frame: CGRect
    let displayIndex: Int
    let displayID: String
    let reason: PanelPlacementReason
    let side: PanelAnchorSide
    let pointerCorner: PanelPointerCorner?

    init(
        frame: CGRect,
        displayIndex: Int,
        displayID: String? = nil,
        reason: PanelPlacementReason,
        side: PanelAnchorSide,
        pointerCorner: PanelPointerCorner? = nil
    ) {
        self.frame = frame
        self.displayIndex = displayIndex
        self.displayID = displayID ?? "display-\(displayIndex)"
        self.reason = reason
        self.side = side
        self.pointerCorner = pointerCorner
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
        gap: CGFloat = defaultGap,
        preferredSide: PanelAnchorSide? = nil,
        preferredPointerCorner: PanelPointerCorner? = nil
    ) -> PanelPlacement? {
        resolve(
            selection: selection,
            pointer: pointer,
            displays: visibleFrames.enumerated().map {
                PanelDisplay(id: "display-\($0.offset)", visibleFrame: $0.element)
            },
            panelSize: panelSize,
            gap: gap,
            preferredSide: preferredSide,
            preferredPointerCorner: preferredPointerCorner
        )
    }

    static func resolve(
        selection: CGRect?,
        pointer: CGPoint,
        displays: [PanelDisplay],
        panelSize: CGSize = defaultPanelSize,
        gap: CGFloat = defaultGap,
        preferredSide: PanelAnchorSide? = nil,
        preferredPointerCorner: PanelPointerCorner? = nil
    ) -> PanelPlacement? {
        let usableDisplays = displays.enumerated().filter {
            $0.element.visibleFrame.isUsableVisibleFrame
        }
        guard let firstDisplay = usableDisplays.first else { return nil }

        let usableSelection = selection.flatMap { candidate in
            candidate.isFiniteAndNonnegative ? candidate : nil
        }
        let usablePointer = pointer.isFinite ? pointer : nil
        let fallbackCenter = CGPoint(
            x: firstDisplay.element.visibleFrame.midX,
            y: firstDisplay.element.visibleFrame.midY
        )
        let anchor = usableSelection.map {
            CGPoint(x: $0.midX, y: $0.midY)
        } ?? usablePointer ?? fallbackCenter

        let chosenDisplay = usableDisplays.first(where: {
            $0.element.visibleFrame.contains(anchor)
        }) ?? usableDisplays.min(by: {
            $0.element.visibleFrame.distanceSquared(to: anchor)
                < $1.element.visibleFrame.distanceSquared(to: anchor)
        }) ?? firstDisplay
        let visibleFrame = chosenDisplay.element.visibleFrame

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
            let above = CGRect(
                x: candidateX,
                y: selection.maxY + effectiveGap,
                width: fittedSize.width,
                height: fittedSize.height
            )
            let belowFits = visibleFrame.contains(below)
                && !below.intersects(selection)
            let aboveFits = visibleFrame.contains(above)
                && !above.intersects(selection)
            let belowSpace = max(
                0,
                selection.minY - visibleFrame.minY - effectiveGap
            )
            let aboveSpace = max(
                0,
                visibleFrame.maxY - selection.maxY - effectiveGap
            )

            let preferred = preferredSide ?? {
                if belowFits && aboveFits {
                    return belowSpace >= aboveSpace ? PanelAnchorSide.below : .above
                }
                if belowFits { return .below }
                if aboveFits { return .above }
                return belowSpace >= aboveSpace ? .below : .above
            }()

            switch preferred {
            case .below where belowFits:
                return PanelPlacement(
                    frame: below,
                    displayIndex: chosenDisplay.offset,
                    displayID: chosenDisplay.element.id,
                    reason: sizeWasClamped || xWasClamped ? .clamped : .below,
                    side: .below
                )
            case .above where aboveFits:
                return PanelPlacement(
                    frame: above,
                    displayIndex: chosenDisplay.offset,
                    displayID: chosenDisplay.element.id,
                    reason: sizeWasClamped || xWasClamped ? .clamped : .above,
                    side: .above
                )
            case .below, .above:
                // A capped size should normally fit the chosen side. Keep the
                // side stable if an external frame changed between measures.
                let candidate = preferred == .below ? below : above
                let clamped = candidate.clamped(to: visibleFrame)
                return PanelPlacement(
                    frame: clamped,
                    displayIndex: chosenDisplay.offset,
                    displayID: chosenDisplay.element.id,
                    reason: .clamped,
                    side: preferred
                )
            case .pointer:
                break
            }
        }

        let pointerAnchor = usablePointer ?? CGPoint(
            x: visibleFrame.midX,
            y: visibleFrame.midY
        )
        let pointerCorner = preferredPointerCorner ?? preferredCorner(
            pointer: pointerAnchor,
            visibleFrame: visibleFrame,
            gap: effectiveGap
        )
        let pointerFrame = frame(
            size: fittedSize,
            pointer: pointerAnchor,
            gap: effectiveGap,
            corner: pointerCorner
        )
        let finalFrame = pointerFrame.clamped(to: visibleFrame)
        return PanelPlacement(
            frame: finalFrame,
            displayIndex: chosenDisplay.offset,
            displayID: chosenDisplay.element.id,
            reason: sizeWasClamped || finalFrame != pointerFrame ? .clamped : .pointer,
            side: .pointer,
            pointerCorner: pointerCorner
        )
    }

    static func frame(
        size: CGSize,
        pointer: CGPoint,
        gap: CGFloat = defaultGap,
        corner: PanelPointerCorner
    ) -> CGRect {
        let x: CGFloat = switch corner {
        case .topLeft, .bottomLeft: pointer.x + gap
        case .topRight, .bottomRight: pointer.x - gap - size.width
        }
        let y: CGFloat = switch corner {
        case .topLeft, .topRight: pointer.y - gap - size.height
        case .bottomLeft, .bottomRight: pointer.y + gap
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func preferredCorner(
        pointer: CGPoint,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> PanelPointerCorner {
        let useRight = visibleFrame.maxX - pointer.x - gap
            >= pointer.x - visibleFrame.minX - gap
        let useBelow = pointer.y - visibleFrame.minY - gap
            >= visibleFrame.maxY - pointer.y - gap
        return switch (useRight, useBelow) {
        case (true, true): .topLeft
        case (false, true): .topRight
        case (true, false): .bottomLeft
        case (false, false): .bottomRight
        }
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

extension CGRect {
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
