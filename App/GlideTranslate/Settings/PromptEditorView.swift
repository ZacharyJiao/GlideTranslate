import SharedSupport
import SwiftUI

struct PromptEditorView: View {
    @Bindable var viewModel: SettingsViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlidePageHeader(
                title: "prompts.editor.title",
                explanation: "prompts.editor.explanationText"
            )
            Form {
                if viewModel.promptDraft != nil {
                    TextField("prompts.editor.name", text: stringBinding(\.name))
                    TextField(
                        "prompts.editor.explanation",
                        text: stringBinding(\.explanation)
                    )
                    Section("prompts.editor.template") {
                        Text("prompts.editor.template.guidance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: stringBinding(\.template))
                            .font(.body.monospaced())
                            .frame(minHeight: 180)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.separator, lineWidth: 1)
                            }
                        LabeledContent("prompts.editor.placeholder.required") {
                            Text(verbatim: "{text}")
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent("prompts.editor.placeholder.optional") {
                            Text(verbatim: "{source_language}  {target_language}")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    Picker("prompts.editor.target", selection: languageBinding) {
                        Text("language.automatic").tag(LanguageChoice.automatic)
                        Text("language.english").tag(LanguageChoice.identified("en"))
                        Text("language.simplifiedChinese")
                            .tag(LanguageChoice.identified("zh-Hans"))
                    }
                    Picker("prompts.editor.action", selection: actionBinding) {
                        Text("prompts.action.translate").tag(PresetAction.translate)
                        Text("prompts.action.explainWord").tag(PresetAction.explainWord)
                        Text("prompts.action.explainSentence")
                            .tag(PresetAction.explainSentence)
                        Text("prompts.action.polish").tag(PresetAction.polish)
                    }
                    if let failure = viewModel.promptValidationFailure {
                        Text(LocalizedStringKey(
                            "prompts.validation.\(failure.rawValue)"
                        ))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("common.cancel") { isPresented = false }
                Spacer()
                Button("common.save") {
                    viewModel.performOwned { model in
                        await model.savePromptDraft()
                        if model.promptDraft == nil { isPresented = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(GlideVisualTokens.actionEmerald)
                .disabled(!viewModel.canSavePromptDraft)
            }
        }
        .padding(GlideVisualTokens.pagePadding)
        .frame(minWidth: 560, minHeight: 500)
        .background(GlideVisualTokens.canvas)
    }

    private func stringBinding(
        _ keyPath: WritableKeyPath<CustomPreset, String>
    ) -> Binding<String> {
        Binding(
            get: { viewModel.promptDraft?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var draft = viewModel.promptDraft else { return }
                draft[keyPath: keyPath] = value
                viewModel.performOwned { await $0.updatePromptDraft(draft) }
            }
        )
    }

    private var languageBinding: Binding<LanguageChoice> {
        Binding(
            get: { viewModel.promptDraft?.targetLanguage ?? .automatic },
            set: { value in
                guard var draft = viewModel.promptDraft else { return }
                draft.targetLanguage = value
                viewModel.performOwned { await $0.updatePromptDraft(draft) }
            }
        )
    }

    private var actionBinding: Binding<PresetAction> {
        Binding(
            get: { viewModel.promptDraft?.action ?? .translate },
            set: { value in
                guard var draft = viewModel.promptDraft else { return }
                draft.action = value
                viewModel.performOwned { await $0.updatePromptDraft(draft) }
            }
        )
    }
}
