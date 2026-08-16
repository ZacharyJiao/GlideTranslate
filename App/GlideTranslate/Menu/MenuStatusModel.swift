import SharedSupport
import SwiftUI

enum CaptureMenuState: Equatable, Sendable {
    case running
    case paused
    case permissionMissing
    case providerUnavailable
    case foregroundAppDisabled
    case shortcutUnavailable
    case historyUnavailable
    case captureUnavailable
    case resetting
}

enum MenuSurfaceItem: Equatable, Sendable {
    case state(textKey: String, symbol: String, enabled: Bool)
    case translateSelectedText(shortcut: String)
    case automaticCaptureToggle(textKey: String)
    case recovery(textKey: String)
    case preset(name: String)
    case providerLocality(textKey: String, enabled: Bool)
    case separator
    case settings
    case quit
}

struct MenuStatusModel: Equatable {
    let state: CaptureMenuState
    let stateSymbol: String
    let stateTextKey: LocalizedStringKey
    let shortcutText: String
    let presetName: String
    let presetNameLocalizationKey: String?
    let providerLocality: DestinationPrivacyClass
    let automaticCapturePaused: Bool

    let stateTextKeyName: String
    let localityTextKeyName: String

    init(
        state: CaptureMenuState,
        shortcutText: String,
        presetName: String,
        presetNameLocalizationKey: String? = nil,
        providerLocality: DestinationPrivacyClass,
        automaticCapturePaused: Bool = false
    ) {
        self.state = state
        self.shortcutText = shortcutText
        self.presetName = presetName
        self.presetNameLocalizationKey = presetNameLocalizationKey
        self.providerLocality = providerLocality
        self.automaticCapturePaused = automaticCapturePaused
        let statePresentation = state.presentation
        stateSymbol = statePresentation.symbol
        stateTextKeyName = statePresentation.textKey
        stateTextKey = LocalizedStringKey(statePresentation.textKey)
        localityTextKeyName = providerLocality.menuTextKey
    }

    var localityTextKey: LocalizedStringKey {
        LocalizedStringKey(localityTextKeyName)
    }

    var captureToggleEnabled: Bool {
        state != .resetting
    }

    var recoveryTextKeyName: String? {
        switch state {
        case .permissionMissing, .providerUnavailable, .foregroundAppDisabled,
             .shortcutUnavailable, .historyUnavailable, .captureUnavailable:
            "menu.resolveInSettings"
        case .running, .paused, .resetting:
            nil
        }
    }

    var recoveryTextKey: LocalizedStringKey? {
        recoveryTextKeyName.map { LocalizedStringKey($0) }
    }

    var surfaceItems: [MenuSurfaceItem] {
        var items: [MenuSurfaceItem] = [
            .state(
                textKey: stateTextKeyName,
                symbol: stateSymbol,
                enabled: false
            ),
            .translateSelectedText(shortcut: shortcutText),
        ]
        if captureToggleEnabled {
            items.append(.automaticCaptureToggle(
                textKey: automaticCapturePaused ? "menu.resume" : "menu.pause"
            ))
        }
        if let recoveryTextKeyName {
            items.append(.recovery(textKey: recoveryTextKeyName))
        }
        items.append(contentsOf: [
            .preset(name: presetName),
            .providerLocality(textKey: localityTextKeyName, enabled: false),
            .separator,
            .settings,
            .quit,
        ])
        return items
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
            && lhs.stateSymbol == rhs.stateSymbol
            && lhs.stateTextKeyName == rhs.stateTextKeyName
            && lhs.shortcutText == rhs.shortcutText
            && lhs.presetName == rhs.presetName
            && lhs.presetNameLocalizationKey == rhs.presetNameLocalizationKey
            && lhs.providerLocality == rhs.providerLocality
            && lhs.localityTextKeyName == rhs.localityTextKeyName
            && lhs.automaticCapturePaused == rhs.automaticCapturePaused
    }

    @MainActor static let development = Self(
        state: .paused,
        shortcutText: "⌥⇧D",
        presetName: "Accurate Translation",
        presetNameLocalizationKey: "preset.accurate.name",
        providerLocality: .unresolvedOrChanged,
        automaticCapturePaused: true
    )
}

private extension CaptureMenuState {
    var presentation: (symbol: String, textKey: String) {
        switch self {
        case .running:
            ("checkmark.circle", "menu.state.running")
        case .paused:
            ("pause.circle", "menu.state.paused")
        case .permissionMissing:
            ("exclamationmark.triangle", "menu.state.permission")
        case .providerUnavailable:
            ("bolt.slash", "menu.state.provider")
        case .foregroundAppDisabled:
            ("nosign", "menu.state.appDisabled")
        case .shortcutUnavailable:
            ("keyboard.badge.ellipsis", "menu.state.shortcut")
        case .historyUnavailable:
            ("clock.badge.exclamationmark", "menu.state.history")
        case .captureUnavailable:
            ("exclamationmark.triangle", "menu.state.capture")
        case .resetting:
            ("arrow.triangle.2.circlepath", "menu.state.resetting")
        }
    }
}

private extension DestinationPrivacyClass {
    var menuTextKey: String {
        switch self {
        case .localOnDevice: "locality.local"
        case .localNetwork: "locality.network"
        case .cloud: "locality.cloud"
        case .unresolvedOrChanged: "locality.unresolved"
        }
    }
}
