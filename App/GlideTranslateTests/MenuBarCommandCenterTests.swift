import AppKit
import SharedSupport
import SwiftUI
import XCTest

@testable import GlideTranslate

@MainActor
final class MenuBarCommandCenterTests: XCTestCase {
    func testCommandCenterGeometryAndPresetCapMatchApprovedContract() {
        XCTAssertEqual(MenuBarCommandCenterContract.contentWidth, 344)
        XCTAssertEqual(MenuBarCommandCenterContract.maximumHeight, 420)
        XCTAssertEqual(MenuBarCommandCenterContract.presetDisplayLimit, 30)

        let longName = String(repeating: "a", count: 31)
        let displayed = MenuBarContent.cappedDisplayName(longName)
        XCTAssertEqual(displayed.count, 30)
        XCTAssertTrue(displayed.hasSuffix("…"))
    }

    func testRenderingCommandCenterPerformsNoAction() {
        var effects: [String] = []
        let actions = MenuBarActions(
            translateSelectedText: { effects.append("translate") },
            setAutomaticCapturePaused: { _ in effects.append("capture") },
            selectPreset: { _ in effects.append("preset") },
            openManualInput: { effects.append("manual") },
            openSettings: { effects.append("settings") }
        )
        let model = MenuStatusModel(
            state: .running,
            shortcutText: "⌥⇧D",
            presetName: "Synthetic Preset",
            providerLocality: .localOnDevice
        )

        let host = NSHostingView(
            rootView: MenuBarContent(model: model, actions: actions)
        )
        host.frame = CGRect(x: 0, y: 0, width: 344, height: 420)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(model.surfaceItems.suffix(3), [
            .manualInput,
            .settings,
            .quit,
        ])
    }
}
