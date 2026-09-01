import SharedSupport
import SwiftUI

enum ManualInputLayout {
    enum Presentation: Equatable, Sendable {
        case stacked
        case wide
    }

    static func presentation(availableWidth: CGFloat) -> Presentation {
        availableWidth < 760 ? .stacked : .wide
    }
}

struct ManualInputView: View {
    @Bindable var viewModel: ManualInputViewModel
    var presenter: ManualWindowPresenter?
    let defaultProviderID: ProviderConfigurationID?
    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: ManualInputViewModel,
        presenter: ManualWindowPresenter? = nil,
        defaultProviderID: ProviderConfigurationID? = nil
    ) {
        self.viewModel = viewModel
        self.presenter = presenter
        self.defaultProviderID = defaultProviderID
    }

    var body: some View {
        GeometryReader { geometry in
            let presentation = ManualInputLayout.presentation(
                availableWidth: geometry.size.width
            )
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlidePageHeader(
                            title: "manual.heading",
                            explanation: "manual.explanation"
                        )

                        TextEditor(text: $viewModel.text)
                            .font(.body)
                            .frame(height: presentation == .stacked ? 190 : 260)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                GlideVisualTokens.elevatedSurface,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.separator, lineWidth: 1)
                            }
                            .accessibilityIdentifier("manual.input")

                        HStack {
                            Text(
                                "\(viewModel.characterCount) / \(viewModel.characterLimit)"
                            )
                            .monospacedDigit()
                            Spacer()
                            Text(LocalizedStringKey(viewModel.validationCategory.rawValue))
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        routingControls(presentation: presentation)

                        if let provider = viewModel.selectedProvider {
                            providerSummary(provider)
                        }
                    }
                    .padding(.horizontal, GlideVisualTokens.pagePadding)
                    .padding(.top, GlideVisualTokens.pagePadding)
                    .padding(.bottom, 16)
                }

                Divider()
                actionBar
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(GlideVisualTokens.canvas)
        .background {
            GlideWindowChrome(minimumSize: CGSize(width: 520, height: 380))
        }
        .onChange(of: presenter?.requestedPresetID, initial: true) { _, requested in
            if let requested { viewModel.selectedPresetID = requested }
        }
        .onAppear {
            viewModel.prepareForOrdinarySession(defaultProviderID: defaultProviderID)
        }
        .onDisappear {
            handleWindowDisappearance()
        }
    }

    @ViewBuilder
    private func routingControls(
        presentation: ManualInputLayout.Presentation
    ) -> some View {
        if presentation == .wide {
            HStack(alignment: .bottom, spacing: 12) {
                sourceLanguageControl
                targetLanguageControl
                presetControl
                providerControl
            }
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                alignment: .leading,
                spacing: 12
            ) {
                sourceLanguageControl
                targetLanguageControl
                presetControl
                providerControl
            }
        }
    }

    private var sourceLanguageControl: some View {
        compactControl("manual.sourceLanguage") {
            languagePicker(
                "manual.sourceLanguage",
                selection: $viewModel.selectedSourceLanguage,
                options: viewModel.sourceOptions
            )
        }
    }

    private var targetLanguageControl: some View {
        compactControl("manual.targetLanguage") {
            languagePicker(
                "manual.targetLanguage",
                selection: $viewModel.selectedTargetLanguage,
                options: viewModel.targetOptions
            )
        }
    }

    private var presetControl: some View {
        compactControl("manual.preset") {
            Picker("manual.preset", selection: $viewModel.selectedPresetID) {
                ForEach(viewModel.presetOptions) { option in
                    presetName(option)
                        .tag(Optional(option.id))
                }
            }
            .labelsHidden()
        }
    }

    private var providerControl: some View {
        compactControl("manual.provider") {
            Picker("manual.provider", selection: $viewModel.selectedProviderID) {
                ForEach(viewModel.providerOptions) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        providerName(option)
                        Text(verbatim: option.model.isEmpty ? "—" : option.model)
                            .font(.caption)
                        Text(LocalizedStringKey(option.readiness.localizationKey))
                            .font(.caption)
                    }
                    .tag(Optional(option.id))
                }
            }
            .labelsHidden()
        }
    }

    private func providerSummary(_ provider: ManualProviderOption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("manual.provider")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    providerIdentity(provider)
                    Spacer(minLength: 8)
                    providerHealth(provider)
                }
                VStack(alignment: .leading, spacing: 8) {
                    providerIdentity(provider)
                    providerHealth(provider)
                }
            }

            Text(LocalizedStringKey(
                provider.isDefault
                    ? "manual.provider.defaultRoute"
                    : "manual.provider.override.explanation"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GlideVisualTokens.elevatedSurface,
            in: RoundedRectangle(cornerRadius: GlideVisualTokens.sectionCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GlideVisualTokens.sectionCornerRadius)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .accessibilityIdentifier("provider-status")
    }

    private func providerIdentity(_ provider: ManualProviderOption) -> some View {
        HStack(spacing: 8) {
            Label(
                LocalizedStringKey(provider.locality.localizationKey),
                systemImage: providerSymbol(provider.locality)
            )
            Text(verbatim: provider.model.isEmpty ? "—" : provider.model)
                .fontWeight(.medium)
                .lineLimit(1)
        }
    }

    private func providerHealth(_ provider: ManualProviderOption) -> some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(provider.readiness.localizationKey))
            Text(LocalizedStringKey(
                provider.hasCredential
                    ? "models.credential.present"
                    : "models.credential.missing"
            ))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func providerSymbol(_ locality: DestinationPrivacyClass) -> String {
        switch locality {
        case .localOnDevice: "desktopcomputer"
        case .localNetwork: "network"
        case .cloud: "cloud"
        case .unresolvedOrChanged: "exclamationmark.triangle"
        }
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            Button("common.cancel") {
                performCancel()
            }
            .keyboardShortcut(.cancelAction)
            Button("manual.translate") {
                performPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(GlideVisualTokens.actionEmerald)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
                presenter?.requestedPresetID != nil
                    ? viewModel.selectedPresetID == nil
                    : !viewModel.canSubmit
            )
            .accessibilityIdentifier("manual.translate")
        }
        .padding(.horizontal, GlideVisualTokens.pagePadding)
        .padding(.vertical, 12)
        .background(.bar)
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
        .labelsHidden()
    }

    private func compactControl<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
