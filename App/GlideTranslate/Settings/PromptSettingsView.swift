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
    @State private var selectedPresetID: PresetID?

    var body: some View {
        HSplitView {
            promptList
            promptForm
                .frame(minWidth: 280)
        }
        .task {
            await viewModel.performOwnedAndWait { await $0.loadPromptPresets() }
            if selectedPresetID == nil {
                selectedPresetID = viewModel.builtInPrompts.first?.id
                    ?? viewModel.customPrompts.first?.id
            }
        }
        .task(id: selectedPresetID) {
            guard let selectedPresetID else { return }
            await viewModel.performOwnedAndWait {
                await $0.previewPrompt(selectedPresetID)
            }
        }
        .sheet(isPresented: $editorPresented) {
            PromptEditorView(viewModel: viewModel, isPresented: $editorPresented)
                .frame(
                    minWidth: 560,
                    idealWidth: 640,
                    minHeight: 500,
                    idealHeight: 540
                )
        }
    }

    private var promptList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedPresetID) {
                Section("prompts.builtIns") {
                    ForEach(viewModel.builtInPrompts) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(preset.nameLocalizationKey))
                            Text(LocalizedStringKey(preset.explanationLocalizationKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(Optional(preset.id))
                    }
                }
                .accessibilityIdentifier("prompts.builtIns")
                Section("prompts.custom") {
                    ForEach(viewModel.customPrompts) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(preset.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(Optional(preset.id))
                    }
                }
                .accessibilityIdentifier("prompts.custom")
            }
            HStack {
                Button("prompts.new") {
                    viewModel.beginNewPrompt()
                    editorPresented = true
                }
                .disabled(viewModel.promptMutationInFlight)
                Spacer()
            }
            .padding(8)
        }
        .frame(
            minWidth: 170,
            idealWidth: 190,
            maxWidth: 220
        )
    }

    private var promptForm: some View {
        Form {
            if let builtIn = selectedBuiltIn {
                Section {
                    Text(LocalizedStringKey(builtIn.explanationLocalizationKey))
                        .foregroundStyle(.secondary)
                    promptActions {
                        Button("prompts.duplicate") {
                            viewModel.performOwned { model in
                                await model.duplicateBuiltInPrompt(builtIn.id)
                                editorPresented = model.promptDraft != nil
                            }
                        }
                        .disabled(viewModel.promptMutationInFlight)
                        Button("prompts.setDefault") {
                            viewModel.performOwned { await $0.setDefaultPreset(builtIn.id) }
                        }
                        .disabled(viewModel.promptMutationInFlight)
                    }
                } header: {
                    Text(LocalizedStringKey(builtIn.nameLocalizationKey))
                }
            } else if let custom = selectedCustom {
                Section(custom.name) {
                    Text(custom.explanation)
                        .foregroundStyle(.secondary)
                    promptActions {
                        Button("prompts.edit") {
                            viewModel.editCustomPrompt(custom)
                            editorPresented = true
                        }
                        Button("prompts.setDefault") {
                            viewModel.performOwned { await $0.setDefaultPreset(custom.id) }
                        }
                        Button("prompts.delete", role: .destructive) {
                            viewModel.performOwned { await $0.deletePrompt(custom.id) }
                        }
                        .accessibilityHint("prompts.delete.hint")
                    }
                    .disabled(viewModel.promptMutationInFlight)
                }
            } else {
                ContentUnavailableView(
                    "prompts.selection.empty",
                    systemImage: "text.quote"
                )
            }

            if let preview = viewModel.promptPreview {
                Section("prompts.request.title") {
                    Text("prompts.request.explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("prompts.request.systemMessage")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: preview.instruction)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("prompts.request.userMessage")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: preview.userContentTemplate)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("prompts.preview")
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
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func promptActions<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content() }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }

    private var selectedBuiltIn: PromptPresetDescriptor? {
        guard let selectedPresetID else { return nil }
        return viewModel.builtInPrompts.first { $0.id == selectedPresetID }
    }

    private var selectedCustom: CustomPreset? {
        guard let selectedPresetID else { return nil }
        return viewModel.customPrompts.first { $0.id == selectedPresetID }
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
