import AppKit
import SharedSupport
import SwiftUI

enum MenuBarCommandCenterContract {
    static let contentWidth: CGFloat = 344
    static let maximumHeight: CGFloat = 420
    static let presetDisplayLimit = 30
}

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
    let openManualInput: @MainActor @Sendable () -> Void
    let openSettings: @MainActor @Sendable () -> Void

    static let development = Self(
        translateSelectedText: {},
        setAutomaticCapturePaused: { _ in },
        selectPreset: { _ in },
        openManualInput: {},
        openSettings: {}
    )
}

struct MenuBarContent: View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.stateSymbol)
                    .font(.title3)
                    .foregroundStyle(GlideVisualTokens.actionEmerald)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.stateTextKey)
                        .font(.headline)
                    if let recoveryTextKey = model.recoveryTextKey {
                        Button(recoveryTextKey, action: actions.openSettings)
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("menu-command-status")

            Button(action: actions.translateSelectedText) {
                HStack {
                    Label("menu.translateSelectedText", systemImage: "character.cursor.ibeam")
                    Spacer()
                    Text(model.shortcutText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(GlideVisualTokens.actionEmerald)
            .controlSize(.large)
            .accessibilityIdentifier("menu-command-translate")

            if model.captureToggleEnabled {
                Button {
                    actions.setAutomaticCapturePaused(!model.automaticCapturePaused)
                } label: {
                    Label(
                        model.automaticCapturePaused
                            ? "menu.resume"
                            : "menu.pause",
                        systemImage: model.automaticCapturePaused
                            ? "play.fill"
                            : "pause.fill"
                    )
                }
                .accessibilityIdentifier("menu-command-capture-toggle")
            }

            Divider()

            Menu {
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
            } label: {
                LabeledContent("menu.preset") {
                    presetName(
                        model.presetName,
                        localizationKey: model.presetNameLocalizationKey
                    )
                    .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("menu-command-preset")

            LabeledContent("menu.provider") {
                Label(
                    model.localityTextKey,
                    systemImage: model.providerLocality.symbolName
                )
            }
            .font(.callout)
            .accessibilityIdentifier("menu-command-locality")

            Divider()

            HStack {
                Button("menu.manualInput", action: actions.openManualInput)
                    .accessibilityIdentifier("menu-command-manual")
                Spacer()
                Button("menu.settings", action: actions.openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityIdentifier("menu-command-settings")
            }

            Divider()

            Button("menu.quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("menu-command-quit")
        }
        .padding(16)
        .frame(width: MenuBarCommandCenterContract.contentWidth)
        .frame(
            maxHeight: MenuBarCommandCenterContract.maximumHeight,
            alignment: .top
        )
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-command-center")
    }

    @ViewBuilder
    private func presetName(
        _ name: String,
        localizationKey: String?
    ) -> some View {
        if let localizationKey {
            Text(LocalizedStringKey(localizationKey))
        } else {
            Text(verbatim: Self.cappedDisplayName(name))
        }
    }

    static func cappedDisplayName(_ name: String) -> String {
        let limit = MenuBarCommandCenterContract.presetDisplayLimit
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)) + "…"
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
