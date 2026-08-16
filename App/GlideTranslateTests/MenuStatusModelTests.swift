import SharedSupport
import SwiftUI
import XCTest

@testable import GlideTranslate

@MainActor
final class MenuStatusModelTests: XCTestCase {
    private enum MenuRow: Equatable {
        case state(CaptureMenuState, symbol: String, textKey: String)
        case locality(DestinationPrivacyClass, textKey: String)
    }

    private let rows: [MenuRow] = [
        .state(.running, symbol: "checkmark.circle", textKey: "menu.state.running"),
        .state(.paused, symbol: "pause.circle", textKey: "menu.state.paused"),
        .state(.permissionMissing, symbol: "exclamationmark.triangle", textKey: "menu.state.permission"),
        .state(.providerUnavailable, symbol: "bolt.slash", textKey: "menu.state.provider"),
        .state(.foregroundAppDisabled, symbol: "nosign", textKey: "menu.state.appDisabled"),
        .state(.shortcutUnavailable, symbol: "keyboard.badge.ellipsis", textKey: "menu.state.shortcut"),
        .state(.historyUnavailable, symbol: "clock.badge.exclamationmark", textKey: "menu.state.history"),
        .state(.captureUnavailable, symbol: "exclamationmark.triangle", textKey: "menu.state.capture"),
        .state(.resetting, symbol: "arrow.triangle.2.circlepath", textKey: "menu.state.resetting"),
        .locality(.localOnDevice, textKey: "locality.local"),
        .locality(.localNetwork, textKey: "locality.network"),
        .locality(.cloud, textKey: "locality.cloud"),
        .locality(.unresolvedOrChanged, textKey: "locality.unresolved"),
    ]

    func testEveryStateAndLocalityRowHasExactClosedPresentation() {
        for row in rows {
            switch row {
            case let .state(state, symbol, textKey):
                let model = menuModel(state: state)
                XCTAssertEqual(model.stateSymbol, symbol)
                XCTAssertEqual(model.stateTextKeyName, textKey)
            case let .locality(locality, textKey):
                let model = menuModel(locality: locality)
                XCTAssertEqual(model.localityTextKeyName, textKey)
            }
        }
        let symbols = rows.compactMap { row -> String? in
            guard case let .state(_, symbol, _) = row else { return nil }
            return symbol
        }
        XCTAssertEqual(Set(symbols).count, 8)
    }

    func testMenuSurfaceHasExactOrderedItemsAndNoClutter() {
        let running = menuModel(state: .running)
        XCTAssertEqual(running.surfaceItems, [
            .state(textKey: "menu.state.running", symbol: "checkmark.circle", enabled: false),
            .translateSelectedText(shortcut: "⌥⇧D"),
            .automaticCaptureToggle(textKey: "menu.pause"),
            .preset(name: "Accurate Translation"),
            .providerLocality(textKey: "locality.local", enabled: false),
            .separator,
            .settings,
            .quit,
        ])
        let paused = menuModel(state: .paused)
        XCTAssertEqual(paused.surfaceItems[2], .automaticCaptureToggle(textKey: "menu.resume"))
        let shortcutFailure = menuModel(state: .shortcutUnavailable)
        XCTAssertEqual(
            shortcutFailure.surfaceItems[3],
            .recovery(textKey: "menu.resolveInSettings")
        )
        XCTAssertFalse(menuModel(state: .resetting).captureToggleEnabled)
        let description = String(describing: running.surfaceItems).lowercased()
        XCTAssertFalse(description.contains("history"))
        XCTAssertFalse(description.contains("diagnostic"))
        XCTAssertFalse(description.contains("endpoint"))
        XCTAssertFalse(description.contains("model parameter"))
    }

    func testRecoverableFailureStatesKeepMasterPauseControlAndSettingsRoute() {
        for state in [
            CaptureMenuState.permissionMissing,
            .providerUnavailable,
            .foregroundAppDisabled,
            .shortcutUnavailable,
            .historyUnavailable,
            .captureUnavailable,
        ] {
            let model = MenuStatusModel(
                state: state,
                shortcutText: "⌥⇧D",
                presetName: "Accurate Translation",
                providerLocality: .cloud,
                automaticCapturePaused: false
            )
            XCTAssertEqual(
                Array(model.surfaceItems.prefix(4)).suffix(2),
                [
                    .automaticCaptureToggle(textKey: "menu.pause"),
                    .recovery(textKey: "menu.resolveInSettings"),
                ],
                "state: \(state)"
            )
        }
    }

    func testMenuTranslateUsesShortcutRouteAndPauseMutatesOnlyMaster() async {
        let fixture = CoordinatorFixture(systemOutcome: .rejected(.noValidSelection))
        let before = fixture.preferences.value
        await fixture.coordinator.setAutomaticCapturePaused(true)
        let paused = fixture.preferences.value
        XCTAssertFalse(paused.automaticCaptureEnabled)
        XCTAssertEqual(paused.mouseSelectionEnabled, before.mouseSelectionEnabled)
        XCTAssertEqual(paused.keyboardSelectionEnabled, before.keyboardSelectionEnabled)
        XCTAssertEqual(paused.clipboardFallbackEnabled, before.clipboardFallbackEnabled)

        await fixture.coordinator.handleMenuTranslateSelectedText()
        XCTAssertEqual(fixture.systemProcessor.calls.map(\.trigger), [.shortcut])

        await fixture.coordinator.setAutomaticCapturePaused(false)
        XCTAssertTrue(fixture.preferences.value.automaticCaptureEnabled)
    }

    func testPresetSelectionChangesOnlyFutureDefault() async {
        let fixture = CoordinatorFixture()
        let replacement = PresetID(rawValue: "polish-expression")
        let before = fixture.preferences.value
        await fixture.coordinator.selectDefaultPreset(replacement)
        let after = fixture.preferences.value
        XCTAssertEqual(after.defaultPresetID, replacement)
        XCTAssertEqual(after.automaticCaptureEnabled, before.automaticCaptureEnabled)
        XCTAssertTrue(fixture.engine.translateCalls.isEmpty)
        XCTAssertTrue(fixture.systemProcessor.calls.isEmpty)
    }

    private func menuModel(
        state: CaptureMenuState = .running,
        locality: DestinationPrivacyClass = .localOnDevice
    ) -> MenuStatusModel {
        MenuStatusModel(
            state: state,
            shortcutText: "⌥⇧D",
            presetName: "Accurate Translation",
            providerLocality: locality,
            automaticCapturePaused: state == .paused
        )
    }
}
