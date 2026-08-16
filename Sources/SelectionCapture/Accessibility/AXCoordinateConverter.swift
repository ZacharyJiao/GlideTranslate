import AppKit
import CoreGraphics

package struct AXDisplaySnapshot: Equatable, Sendable {
    package let displayID: UInt32
    package let quartzBounds: CGRect
    package let appKitFrame: CGRect
    package let isMain: Bool
    package let backingScaleFactor: CGFloat
}

package enum AXCoordinateConverter {
    fileprivate static let dimensionTolerance: CGFloat = 0.5

    package static func appKitGlobalRect(
        _ axRect: CGRect,
        displays: [AXDisplaySnapshot]
    ) -> CGRect? {
        guard axRect.isFiniteAndNonnegative,
              displays.count > 0,
              displays.allSatisfy(\.isValidPair),
              displays.filter(\.isMain).count == 1,
              let main = displays.first(where: \.isMain),
              let sourceDisplay = displays.first(where: {
                  $0.quartzBounds.contains(axRect.center)
              }) else {
            return nil
        }

        let converted = CGRect(
            x: main.appKitFrame.minX + (axRect.minX - main.quartzBounds.minX),
            y: main.appKitFrame.maxY - (axRect.maxY - main.quartzBounds.minY),
            width: axRect.width,
            height: axRect.height
        )
        guard converted.isFiniteAndNonnegative,
              sourceDisplay.appKitFrame.contains(converted.center) else {
            return nil
        }
        return converted
    }

    package static func currentDisplays() -> [AXDisplaySnapshot]? {
        let mainID = CGMainDisplayID()
        let displays = NSScreen.screens.compactMap { screen -> AXDisplaySnapshot? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return AXDisplaySnapshot(
                displayID: displayID,
                quartzBounds: CGDisplayBounds(displayID),
                appKitFrame: screen.frame,
                isMain: displayID == mainID,
                backingScaleFactor: screen.backingScaleFactor
            )
        }
        guard displays.count == NSScreen.screens.count else { return nil }
        return displays
    }
}

private extension AXDisplaySnapshot {
    var isValidPair: Bool {
        quartzBounds.isFiniteAndNonnegative
            && appKitFrame.isFiniteAndNonnegative
            && abs(quartzBounds.width - appKitFrame.width)
                <= AXCoordinateConverter.dimensionTolerance
            && abs(quartzBounds.height - appKitFrame.height)
                <= AXCoordinateConverter.dimensionTolerance
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    var isFiniteAndNonnegative: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && size.width >= 0
            && size.height >= 0
    }
}
