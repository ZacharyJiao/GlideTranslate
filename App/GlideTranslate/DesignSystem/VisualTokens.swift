import AppKit
import SwiftUI

enum GlideVisualTokens {
    static let canvas = adaptive(
        light: NSColor(calibratedWhite: 0.969, alpha: 1),
        dark: NSColor(calibratedRed: 0.082, green: 0.094, blue: 0.090, alpha: 1)
    )
    static let elevatedSurface = adaptive(
        light: .white,
        dark: NSColor(calibratedRed: 0.125, green: 0.141, blue: 0.133, alpha: 1)
    )
    static let primaryInk = adaptive(
        light: NSColor(calibratedRed: 0.122, green: 0.137, blue: 0.157, alpha: 1),
        dark: NSColor(calibratedRed: 0.957, green: 0.969, blue: 0.961, alpha: 1)
    )
    static let actionEmerald = adaptive(
        light: NSColor(calibratedRed: 0.031, green: 0.478, blue: 0.275, alpha: 1),
        dark: NSColor(calibratedRed: 0.208, green: 0.839, blue: 0.478, alpha: 1)
    )
    static let vividEmerald = adaptive(
        light: NSColor(calibratedRed: 0, green: 0.784, blue: 0.325, alpha: 1),
        dark: NSColor(calibratedRed: 0.208, green: 0.839, blue: 0.478, alpha: 1)
    )
    static let mintSupport = adaptive(
        light: NSColor(calibratedRed: 0.655, green: 0.953, blue: 0.816, alpha: 1),
        dark: NSColor(calibratedRed: 0.494, green: 0.906, blue: 0.757, alpha: 1)
    )

    static let compactSpacing: CGFloat = 8
    static let panelSpacing: CGFloat = 12
    static let panelPadding: CGFloat = 16
    static let panelCornerRadius: CGFloat = 16
    static let outputAdditionalLineSpacing: CGFloat = 4
    static let sectionCornerRadius: CGFloat = 12
    static let pagePadding: CGFloat = 24
    static let readableDetailWidth: CGFloat = 640

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
        })
    }
}

enum GlideMotionTokens {
    static let pressDuration = 0.10
    static let hoverDuration = 0.12
    static let surfaceDuration = 0.16
    static let resizeDuration = 0.20
    static let contentCrossfadeDuration = 0.14
}

enum PanelSurfaceStyle: Equatable, Sendable {
    case standard
    case reducedTransparency
    case increasedContrast

    static func resolve(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Self {
        if increaseContrast { return .increasedContrast }
        if reduceTransparency { return .reducedTransparency }
        return .standard
    }
}
