import SharedSupport
import SwiftUI

struct ManualInputView: View {
    @Bindable var viewModel: ManualInputViewModel
    var presenter: ManualWindowPresenter?
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: ManualInputViewModel,
        presenter: ManualWindowPresenter? = nil
    ) {
        self.viewModel = viewModel
        self.presenter = presenter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("manual.heading")
                .font(.title2.weight(.semibold))

            TextEditor(text: $viewModel.text)
                .font(.body)
                .frame(minHeight: 160)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityIdentifier("manual.input")

            HStack {
                Text("\(viewModel.characterCount) / \(viewModel.characterLimit)")
                    .monospacedDigit()
                Spacer()
                Text(LocalizedStringKey(viewModel.validationCategory.rawValue))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                languagePicker(
                    "manual.sourceLanguage",
                    selection: $viewModel.selectedSourceLanguage,
                    options: viewModel.sourceOptions
                )
                languagePicker(
                    "manual.targetLanguage",
                    selection: $viewModel.selectedTargetLanguage,
                    options: viewModel.targetOptions
                )
                Picker("manual.preset", selection: $viewModel.selectedPresetID) {
                    ForEach(viewModel.presetOptions) { option in
                        presetName(option)
                            .tag(Optional(option.id))
                    }
                }
            }

            HStack {
                Picker("manual.provider", selection: $viewModel.selectedProviderID) {
                    ForEach(viewModel.providerOptions) { option in
                        providerName(option).tag(Optional(option.id))
                    }
                }
                Spacer()
                if let provider = viewModel.selectedProvider {
                    Label(
                        localityKey(provider.locality),
                        systemImage: provider.locality == .localOnDevice
                            ? "desktopcomputer" : "network"
                    )
                }
            }

            HStack {
                Spacer()
                Button("common.cancel") {
                    performCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("manual.translate") {
                    performPrimaryAction()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    presenter?.requestedPresetID != nil
                        ? viewModel.selectedPresetID == nil
                        : !viewModel.canSubmit
                )
                .accessibilityIdentifier("manual.translate")
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 340)
        .onChange(of: presenter?.requestedPresetID, initial: true) { _, requested in
            if let requested { viewModel.selectedPresetID = requested }
        }
        .onDisappear {
            handleWindowDisappearance()
        }
    }

    func performPrimaryAction() {
        if presenter?.requestedPresetID != nil,
           let presetID = viewModel.selectedPresetID {
            presenter?.selectPreset(presetID)
            dismiss()
        } else {
            Task { await viewModel.submit() }
        }
    }

    func performCancel() {
        presenter?.cancelPresetPicker(sessionID: nil)
        viewModel.cancel()
        dismiss()
    }

    func handleWindowDisappearance() {
        presenter?.cancelPresetPicker(sessionID: nil)
    }

    private func languagePicker(
        _ titleKey: LocalizedStringKey,
        selection: Binding<LanguageChoice?>,
        options: [ManualLanguageOption]
    ) -> some View {
        Picker(titleKey, selection: selection) {
            ForEach(options) { option in
                Text(LocalizedStringKey(option.labelKey))
                    .tag(Optional(option.value))
            }
        }
    }

    private func localityKey(_ locality: DestinationPrivacyClass) -> LocalizedStringKey {
        switch locality {
        case .localOnDevice: "locality.local"
        case .localNetwork: "locality.network"
        case .cloud: "locality.cloud"
        case .unresolvedOrChanged: "locality.unresolved"
        }
    }

    @ViewBuilder
    private func presetName(_ option: ManualPresetOption) -> some View {
        if let labelKey = option.labelKey {
            Text(LocalizedStringKey(labelKey))
        } else {
            Text(verbatim: option.label)
        }
    }

    @ViewBuilder
    private func providerName(_ option: ManualProviderOption) -> some View {
        if let labelKey = option.labelKey {
            Text(LocalizedStringKey(labelKey))
        } else {
            Text(verbatim: option.label)
        }
    }
}
