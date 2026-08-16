import SharedSupport
import SwiftUI
import TranslationCore

enum PromptPreviewSampleSource: Equatable, Sendable {
    case bundledOnly
}

enum PromptUIRow: Equatable, Sendable {
    case builtInEditAttempt(editable: Bool)
    case builtInDeleteAttempt(deletable: Bool)
    case duplicateBuiltIn(newCustomID: Bool)
    case newCustom(editorOpens: Bool)
    case invalidCustom(saveEnabled: Bool)
    case validCustom(saveEnabled: Bool)
    case preview(sampleSource: PromptPreviewSampleSource)
    case setDefault(persists: Bool)
    case deleteCurrentDefault(requiresReplacement: Bool)
}

enum PromptSettingsContract {
    static let rows: [PromptUIRow] = [
        .builtInEditAttempt(editable: false),
        .builtInDeleteAttempt(deletable: false),
        .duplicateBuiltIn(newCustomID: true),
        .newCustom(editorOpens: true),
        .invalidCustom(saveEnabled: false),
        .validCustom(saveEnabled: true),
        .preview(sampleSource: .bundledOnly),
        .setDefault(persists: true),
        .deleteCurrentDefault(requiresReplacement: true),
    ]
}

struct PromptSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var editorPresented = false
    @State private var replacementID: PresetID?

    var body: some View {
        Form {
            Section("prompts.builtIns") {
                ForEach(viewModel.builtInPrompts) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(LocalizedStringKey(preset.nameLocalizationKey))
                            Text(LocalizedStringKey(preset.explanationLocalizationKey))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("prompts.duplicate") {
                            viewModel.performOwned { model in
                                await model.duplicateBuiltInPrompt(preset.id)
                                editorPresented = model.promptDraft != nil
                            }
                        }
                        .disabled(viewModel.promptMutationInFlight)
                        Button("prompts.preview") {
                            viewModel.performOwned { await $0.previewPrompt(preset.id) }
                        }
                        Button("prompts.setDefault") {
                            viewModel.performOwned { await $0.setDefaultPreset(preset.id) }
                        }
                        .disabled(viewModel.promptMutationInFlight)
                    }
                }
            }
            .accessibilityIdentifier("prompts.builtIns")

            Section("prompts.custom") {
                ForEach(viewModel.customPrompts) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name)
                            Text(preset.explanation).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("prompts.edit") {
                            viewModel.editCustomPrompt(preset)
                            editorPresented = true
                        }
                        .disabled(viewModel.promptMutationInFlight)
                        Button("prompts.preview") {
                            viewModel.performOwned { await $0.previewPrompt(preset.id) }
                        }
                        Button("prompts.setDefault") {
                            viewModel.performOwned { await $0.setDefaultPreset(preset.id) }
                        }
                        .disabled(viewModel.promptMutationInFlight)
                        Button("prompts.delete", role: .destructive) {
                            viewModel.performOwned { await $0.deletePrompt(preset.id) }
                        }
                        .accessibilityHint("prompts.delete.hint")
                        .disabled(viewModel.promptMutationInFlight)
                    }
                }
                Button("prompts.new") {
                    viewModel.beginNewPrompt()
                    editorPresented = true
                }
                .disabled(viewModel.promptMutationInFlight)
            }
            .accessibilityIdentifier("prompts.custom")

            if let preview = viewModel.promptPreview {
                Section("prompts.preview") {
                    Text("prompts.preview.untrustedExplanation")
                    LabeledContent("prompts.preview.instruction", value: preview.instruction)
                    LabeledContent(
                        "prompts.preview.sampleUserContent",
                        value: preview.sampleUserContent
                    )
                }
                .accessibilityIdentifier("prompts.preview")
            } else {
                Color.clear.frame(height: 0).accessibilityIdentifier("prompts.preview")
            }

            if let deleting = viewModel.promptReplacementRequiredID {
                Section("prompts.deleteDefault.replacement") {
                    Picker("prompts.default", selection: $replacementID) {
                        Text("prompts.default.choose").tag(PresetID?.none)
                        ForEach(viewModel.availablePromptIDs.filter { $0 != deleting }, id: \.rawValue) { id in
                            promptName(id).tag(Optional(id))
                        }
                    }
                    Button("prompts.deleteDefault.confirm", role: .destructive) {
                        guard let replacementID else { return }
                        viewModel.performOwned {
                            await $0.deletePrompt(deleting, replacement: replacementID)
                        }
                    }
                    .accessibilityHint("prompts.deleteDefault.confirm.hint")
                    .disabled(replacementID == nil || viewModel.promptMutationInFlight)
                }
            }
            Color.clear.frame(height: 0).accessibilityIdentifier("prompts.default")
        }
        .formStyle(.grouped)
        .task {
            await viewModel.performOwnedAndWait { await $0.loadPromptPresets() }
        }
        .sheet(isPresented: $editorPresented) {
            PromptEditorView(viewModel: viewModel, isPresented: $editorPresented)
                .frame(minWidth: 560, minHeight: 500)
        }
    }

    @ViewBuilder
    private func promptName(_ id: PresetID) -> some View {
        if let builtIn = viewModel.builtInPrompts.first(where: { $0.id == id }) {
            Text(LocalizedStringKey(builtIn.nameLocalizationKey))
        } else if let custom = viewModel.customPrompts.first(where: { $0.id == id }) {
            Text(verbatim: custom.name)
        } else {
            Text("preset.custom.name")
        }
    }
}

struct UnavailablePromptPresetStore: PromptPresetStore {
    func builtIns() async -> [PromptPresetDescriptor] { [] }
    func customPresets() async throws -> [CustomPreset] { [] }
    func duplicateBuiltIn(_ id: PresetID) async throws -> CustomPreset {
        throw PromptPresetFailure.presetNotFound
    }
    func validate(_ preset: CustomPreset) async throws -> ValidatedPromptPreset {
        throw PromptPresetFailure.presetNotFound
    }
    func preview(_ id: PresetID) async throws -> PromptPresetPreview {
        throw PromptPresetFailure.presetNotFound
    }
    func validatedPreset(_ id: PresetID) async throws -> ValidatedPromptPreset {
        throw PromptPresetFailure.presetNotFound
    }
    func save(_ preset: CustomPreset) async throws {
        throw PromptPresetFailure.presetNotFound
    }
    func delete(_ id: PresetID) async throws {
        throw PromptPresetFailure.presetNotFound
    }
}
