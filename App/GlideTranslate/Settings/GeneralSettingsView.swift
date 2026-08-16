import PrivacyStorage
import SharedSupport
import SwiftUI

enum GeneralShortcutPresentation: Equatable, Sendable {
    case ready
    case replacementRequired
    case unavailable
    case persistenceFailed
}

struct GeneralSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Picker("general.uiLanguage", selection: uiLanguage) {
                Text("language.english").tag(ApplicationLanguage.english)
                Text("language.simplifiedChinese").tag(ApplicationLanguage.simplifiedChinese)
            }
            .accessibilityIdentifier("general.uiLanguage")

            Picker("general.targetLanguage", selection: targetLanguage) {
                Text("language.automatic").tag(LanguageChoice.automatic)
                Text("language.english").tag(LanguageChoice.identified("en"))
                Text("language.simplifiedChinese").tag(LanguageChoice.identified("zh-Hans"))
            }
            .accessibilityIdentifier("general.targetLanguage")

            LabeledContent("general.shortcut") {
                HStack {
                    ShortcutRecorderField(descriptor: shortcutCandidate)
                        .frame(width: 120)
                    Button("general.shortcut.apply") {
                        let descriptor = viewModel.shortcutCandidate
                        viewModel.performOwned { await $0.setShortcut(descriptor) }
                    }
                }
            }
            .accessibilityIdentifier("general.shortcut")
            if shortcutPresentation != .ready {
                Text(shortcutPresentationKey)
            }

            Toggle("general.launchAtLogin", isOn: launchAtLogin)
                .accessibilityIdentifier("general.launchAtLogin")

            Picker("general.defaultPreset", selection: defaultPreset) {
                ForEach(defaultPresetOptions, id: \.rawValue) { id in
                    defaultPresetName(id).tag(id)
                }
            }
                .accessibilityIdentifier("general.defaultPreset")

            Picker("general.defaultProvider", selection: defaultProvider) {
                Text("general.defaultProvider.none").tag(ProviderConfigurationID?.none)
                if let current = viewModel.snapshot.defaultProviderID,
                   !viewModel.providers.contains(where: { $0.id == current }) {
                    Text("general.defaultProvider.unavailable").tag(Optional(current))
                }
                ForEach(viewModel.providers) { provider in
                    Text(LocalizedStringKey(provider.protocolKind.localizationKey))
                        .tag(Optional(provider.id))
                }
            }
            .accessibilityIdentifier("general.defaultProvider")

            Toggle("general.automaticCapture", isOn: automaticCapture)
                .accessibilityIdentifier("general.automaticCapture")
        }
        .formStyle(.grouped)
    }

    var shortcutPresentation: GeneralShortcutPresentation {
        if viewModel.shortcutError == .persistenceFailed { return .persistenceFailed }
        switch viewModel.shortcutRegistrationState {
        case .replacementRequired: return .replacementRequired
        case .unavailable: return .unavailable
        case .unregistered, .registered: return .ready
        }
    }

    private var shortcutPresentationKey: LocalizedStringKey {
        switch shortcutPresentation {
        case .ready: "general.shortcut.ready"
        case .replacementRequired: "shortcut.conflict.nextAction"
        case .unavailable: "shortcut.unavailable.nextAction"
        case .persistenceFailed: "general.shortcut.persistenceFailed"
        }
    }

    private var uiLanguage: Binding<ApplicationLanguage> {
        Binding(
            get: { viewModel.snapshot.uiLanguage },
            set: { value in
                viewModel.performOwned { await $0.setUILanguage(value) }
            }
        )
    }

    private var shortcutCandidate: Binding<ShortcutDescriptor> {
        Binding(
            get: { viewModel.shortcutCandidate },
            set: { viewModel.recordShortcutCandidate($0) }
        )
    }

    private var targetLanguage: Binding<LanguageChoice> {
        Binding(
            get: { viewModel.snapshot.defaultTargetLanguage },
            set: { value in
                viewModel.performOwned { await $0.setTargetLanguage(value) }
            }
        )
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.launchAtLogin },
            set: { value in
                viewModel.performOwned { await $0.setLaunchAtLogin(value) }
            }
        )
    }

    private var defaultPreset: Binding<PresetID> {
        Binding(
            get: { viewModel.snapshot.defaultPresetID },
            set: { value in
                viewModel.performOwned { await $0.setDefaultPreset(value) }
            }
        )
    }

    private var defaultPresetOptions: [PresetID] {
        var seen: Set<PresetID> = []
        return ([viewModel.snapshot.defaultPresetID]
            + PresetID.builtInDisplayIDs
            + viewModel.availablePromptIDs).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private func defaultPresetName(_ id: PresetID) -> some View {
        if let custom = viewModel.customPrompts.first(where: { $0.id == id }) {
            Text(verbatim: custom.name)
        } else {
            Text(LocalizedStringKey(id.safeDisplayLocalizationKey))
        }
    }

    private var defaultProvider: Binding<ProviderConfigurationID?> {
        Binding(
            get: { viewModel.snapshot.defaultProviderID },
            set: { value in
                viewModel.performOwned { await $0.setDefaultProvider(value) }
            }
        )
    }

    private var automaticCapture: Binding<Bool> {
        Binding(
            get: { viewModel.snapshot.automaticCaptureEnabled },
            set: { value in
                viewModel.performOwned { await $0.setAutomaticCaptureEnabled(value) }
            }
        )
    }
}
