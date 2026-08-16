import AppKit
import SharedSupport
import SwiftUI

struct MenuPresetOption: Identifiable, Equatable, Sendable {
    let id: PresetID
    let name: String
    let nameLocalizationKey: String?

    init(
        id: PresetID,
        name: String,
        nameLocalizationKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.nameLocalizationKey = nameLocalizationKey
    }
}

struct MenuBarActions: Sendable {
    let translateSelectedText: @MainActor @Sendable () -> Void
    let setAutomaticCapturePaused: @MainActor @Sendable (Bool) -> Void
    let selectPreset: @MainActor @Sendable (PresetID) -> Void

    static let development = Self(
        translateSelectedText: {},
        setAutomaticCapturePaused: { _ in },
        selectPreset: { _ in }
    )
}

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings

    let model: MenuStatusModel
    let presetOptions: [MenuPresetOption]
    let actions: MenuBarActions

    init(
        model: MenuStatusModel,
        presetOptions: [MenuPresetOption] = [],
        actions: MenuBarActions
    ) {
        self.model = model
        self.presetOptions = presetOptions
        self.actions = actions
    }

    var body: some View {
        Label(model.stateTextKey, systemImage: model.stateSymbol)
            .disabled(true)

        Button(action: actions.translateSelectedText) {
            HStack {
                Text("menu.translateSelectedText")
                Spacer()
                Text(model.shortcutText)
            }
        }

        if model.captureToggleEnabled {
            Button {
                actions.setAutomaticCapturePaused(!model.automaticCapturePaused)
            } label: {
                Text(model.automaticCapturePaused
                     ? LocalizedStringKey("menu.resume")
                     : LocalizedStringKey("menu.pause"))
            }
        }
        if let recoveryTextKey = model.recoveryTextKey {
            Button(recoveryTextKey) { openSettings() }
        }

        Menu("menu.preset") {
            if presetOptions.isEmpty {
                presetName(
                    model.presetName,
                    localizationKey: model.presetNameLocalizationKey
                )
            } else {
                ForEach(presetOptions) { option in
                    Button {
                        actions.selectPreset(option.id)
                    } label: {
                        presetName(
                            option.name,
                            localizationKey: option.nameLocalizationKey
                        )
                    }
                }
            }
        }

        Label(model.localityTextKey, systemImage: model.providerLocality.symbolName)
            .disabled(true)

        Divider()

        Button("menu.settings") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button("menu.quit") { NSApplication.shared.terminate(nil) }
    }

    @ViewBuilder
    private func presetName(
        _ name: String,
        localizationKey: String?
    ) -> some View {
        if let localizationKey {
            Text(LocalizedStringKey(localizationKey))
        } else {
            Text(verbatim: name)
        }
    }
}

private extension DestinationPrivacyClass {
    var symbolName: String {
        switch self {
        case .localOnDevice: "desktopcomputer"
        case .localNetwork: "network"
        case .cloud: "cloud"
        case .unresolvedOrChanged: "exclamationmark.triangle"
        }
    }
}
