import Foundation
import Observation
import SharedSupport

struct ManualLanguageOption: Identifiable, Equatable, Sendable {
    let id: String
    let labelKey: String
    let value: LanguageChoice
}

struct ManualPresetOption: Identifiable, Equatable, Sendable {
    let id: PresetID
    let label: String
    let labelKey: String?

    init(id: PresetID, labelKey: String) {
        self.id = id
        label = labelKey
        self.labelKey = labelKey
    }

    init(id: PresetID, label: String) {
        self.id = id
        self.label = label
        labelKey = nil
    }
}

struct ManualProviderOption: Identifiable, Equatable, Sendable {
    let id: String
    let configurationID: ProviderConfigurationID?
    let label: String
    let labelKey: String?
    let model: String
    let locality: DestinationPrivacyClass
    let hasCredential: Bool
    let isDefault: Bool

    init(
        id: String,
        configurationID: ProviderConfigurationID?,
        label: String,
        labelKey: String? = nil,
        model: String = "",
        locality: DestinationPrivacyClass,
        hasCredential: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.configurationID = configurationID
        self.label = label
        self.labelKey = labelKey
        self.model = model
        self.locality = locality
        self.hasCredential = hasCredential
        self.isDefault = isDefault
    }

    var readiness: ProviderReadiness {
        ProviderReadiness.resolve(model: model, privacyClass: locality)
    }
}

enum ManualInputValidationCategory: String, Equatable, Sendable {
    case ready = "manual.validation.ready"
    case emptyText = "manual.validation.empty"
    case tooLong = "manual.validation.tooLong"
    case missingSelection = "manual.validation.missingSelection"
}

@MainActor
@Observable
final class ManualInputViewModel {
    var text: String
    var selectedSourceLanguage: LanguageChoice?
    var selectedTargetLanguage: LanguageChoice?
    var selectedPresetID: PresetID?
    var selectedProviderID: String?
    private(set) var isSubmitting = false

    private(set) var sourceOptions: [ManualLanguageOption]
    private(set) var targetOptions: [ManualLanguageOption]
    private(set) var presetOptions: [ManualPresetOption]
    private(set) var providerOptions: [ManualProviderOption]
    private(set) var characterLimit: Int

    private let onCancel: @MainActor @Sendable () -> Void
    private let onSubmit: @MainActor @Sendable (ManualTranslationDraft) async -> Void

    init(
        text: String = "",
        sourceOptions: [ManualLanguageOption],
        targetOptions: [ManualLanguageOption],
        presetOptions: [ManualPresetOption],
        providerOptions: [ManualProviderOption],
        characterLimit: Int,
        onCancel: @escaping @MainActor @Sendable () -> Void,
        onSubmit: @escaping @MainActor @Sendable (ManualTranslationDraft) async -> Void
    ) {
        self.text = text
        self.sourceOptions = sourceOptions
        self.targetOptions = targetOptions
        self.presetOptions = presetOptions
        self.providerOptions = providerOptions
        self.characterLimit = characterLimit
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        selectedSourceLanguage = sourceOptions.first?.value
        selectedTargetLanguage = targetOptions.first?.value
        selectedPresetID = presetOptions.first?.id
        selectedProviderID = providerOptions.first?.id
    }

    var characterCount: Int { text.count }

    var selectedProvider: ManualProviderOption? {
        providerOptions.first { $0.id == selectedProviderID }
    }

    var validationCategory: ManualInputValidationCategory {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }
        guard trimmed.count <= characterLimit else { return .tooLong }
        guard selectedSourceLanguage != nil,
              selectedTargetLanguage != nil,
              selectedPresetID != nil,
              selectedProvider != nil else {
            return .missingSelection
        }
        return .ready
    }

    var canSubmit: Bool {
        validationCategory == .ready && !isSubmitting
    }

    func updateCharacterLimit(_ limit: Int) {
        characterLimit = limit
    }

    func prepareForOrdinarySession(defaultProviderID: ProviderConfigurationID?) {
        guard let defaultProviderID else {
            selectedProviderID = nil
            return
        }
        selectedProviderID = providerOptions.first {
            $0.configurationID == defaultProviderID
        }?.id
    }

    func replaceOptions(
        source: [ManualLanguageOption],
        target: [ManualLanguageOption],
        presets: [ManualPresetOption],
        providers: [ManualProviderOption],
        preferredSource: LanguageChoice?,
        preferredTarget: LanguageChoice?,
        preferredPresetID: PresetID?,
        preferredProviderID: ProviderConfigurationID?
    ) {
        sourceOptions = source
        targetOptions = target
        presetOptions = presets
        providerOptions = providers
        selectedSourceLanguage = source.first(where: { $0.value == preferredSource })?.value
            ?? source.first?.value
        selectedTargetLanguage = target.first(where: { $0.value == preferredTarget })?.value
            ?? target.first?.value
        selectedPresetID = presets.first(where: { $0.id == preferredPresetID })?.id
            ?? presets.first?.id
        selectedProviderID = providers.first(where: {
            $0.configurationID == preferredProviderID
        })?.id
    }

    func cancel() {
        onCancel()
    }

    func clearTransientState() {
        text = ""
    }

    func submit() async {
        guard canSubmit,
              let sourceLanguage = selectedSourceLanguage,
              let targetLanguage = selectedTargetLanguage,
              let presetID = selectedPresetID,
              let provider = selectedProvider else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        defer { isSubmitting = false }
        await onSubmit(ManualTranslationDraft(
            text: trimmed,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            presetID: presetID,
            providerID: provider.configurationID
        ))
    }

    static func development(
        onSubmit: @escaping @MainActor @Sendable (ManualTranslationDraft) async -> Void = { _ in }
    ) -> Self {
        Self(
            sourceOptions: [
                .init(id: "automatic", labelKey: "language.automatic", value: .automatic),
            ],
            targetOptions: [
                .init(id: "en", labelKey: "language.english", value: .identified("en")),
                .init(id: "zh-Hans", labelKey: "language.simplifiedChinese", value: .identified("zh-Hans")),
            ],
            presetOptions: [
                .init(
                    id: PresetID(rawValue: "accurate-translation"),
                    labelKey: "preset.accurate.name"
                ),
            ],
            providerOptions: [
                .init(
                    id: "default",
                    configurationID: DevelopmentCompositionFixture.providerID,
                    label: "Default",
                    labelKey: "manual.provider.default",
                    locality: .unresolvedOrChanged
                ),
            ],
            characterLimit: 20_000,
            onCancel: {},
            onSubmit: onSubmit
        )
    }
}
