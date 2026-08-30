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
                TextField("prompts.editor.explanation", text: stringBinding(\.explanation))
                TextEditor(text: stringBinding(\.template))
                    .frame(minHeight: 180)
                Picker("prompts.editor.target", selection: languageBinding) {
                    Text("language.automatic").tag(LanguageChoice.automatic)
                    Text("language.english").tag(LanguageChoice.identified("en"))
                    Text("language.simplifiedChinese").tag(LanguageChoice.identified("zh-Hans"))
                }
                Picker("prompts.editor.action", selection: actionBinding) {
                    Text("prompts.action.translate").tag(PresetAction.translate)
                    Text("prompts.action.explainWord").tag(PresetAction.explainWord)
                    Text("prompts.action.explainSentence").tag(PresetAction.explainSentence)
                    Text("prompts.action.polish").tag(PresetAction.polish)
                }
                if let failure = viewModel.promptValidationFailure {
                    Text(LocalizedStringKey("prompts.validation.\(failure.rawValue)"))
                }
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
            }
            .formStyle(.grouped)
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
