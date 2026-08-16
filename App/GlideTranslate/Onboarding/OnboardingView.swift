import SwiftUI

enum OnboardingShortcutPresentation: Equatable, Sendable {
    case defaultAttempt
    case replacement
}

struct OnboardingView: View {
    @Bindable var coordinator: OnboardingCoordinator
    @State private var replacementChoice = OnboardingShortcutChoice.optionShiftF

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                switch coordinator.step {
                case .privacyModel: privacyStep
                case .localOllama: ollamaStep
                case .shortcut: shortcutStep
                case .accessibility: accessibilityStep
                case .complete: completeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let error = coordinator.safeError {
                let localization = error.localization
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        LocalizedStringKey(localization.messageKey),
                        systemImage: "exclamationmark.triangle"
                    )
                    Text(LocalizedStringKey(localization.nextActionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("onboarding-safe-error")
            }

            if coordinator.step != .complete {
                HStack {
                    Button("onboarding.skip") { coordinator.skip() }
                    Spacer()
                    if coordinator.step != .shortcut
                        || shortcutPresentation == .defaultAttempt {
                        Button("onboarding.continue") {
                            coordinator.performOwned {
                                await $0.continueCurrentStep()
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.privacy.title").font(.title)
            Text("onboarding.privacy.localFirst")
            Text("onboarding.privacy.noAutomaticReading")
            Text("onboarding.privacy.manualAvailable")
        }
    }

    private var ollamaStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.ollama.title").font(.title)
            Button("onboarding.ollama.detect") {
                coordinator.performOwned { await $0.detectOllama() }
            }
            switch coordinator.ollamaState {
            case .notChecked:
                Text("onboarding.ollama.notChecked")
            case .checking:
                ProgressView("onboarding.ollama.checking")
            case let .available(models):
                ForEach(models, id: \.self) { model in
                    Button(model) {
                        coordinator.performOwned { await $0.selectModel(model) }
                    }
                }
            case .modelsEmpty, .unavailable:
                Text(OnboardingCoordinator.installGuidance)
                    .font(.system(.body, design: .monospaced))
                Button("onboarding.ollama.copyGuidance") {
                    coordinator.copyInstallGuidance()
                }
            }
            TextField("onboarding.ollama.manualModel", text: $coordinator.manualModelName)
                .textFieldStyle(.roundedBorder)
            Button("onboarding.ollama.useManualModel") {
                coordinator.performOwned { await $0.selectManualModel() }
            }
            .disabled(!coordinator.canSelectManualModel)
        }
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.shortcut.title").font(.title)
            Text("onboarding.shortcut.defaultOptionShiftD")
            Text("onboarding.shortcut.conflictGuidance")
            if shortcutPresentation == .replacement {
                Picker("onboarding.shortcut.replacement", selection: $replacementChoice) {
                    ForEach(OnboardingShortcutChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Button("onboarding.shortcut.registerReplacement") {
                    coordinator.performOwned {
                        await $0.registerReplacement(replacementChoice)
                    }
                }
            }
        }
    }

    var shortcutPresentation: OnboardingShortcutPresentation {
        coordinator.requiresShortcutReplacement ? .replacement : .defaultAttempt
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.accessibility.title").font(.title)
            Text("onboarding.accessibility.scope")
            Text("onboarding.accessibility.neverAutomatic")
            Text("onboarding.accessibility.perAppDefaults")
            Text("onboarding.accessibility.manualAlternative")
            Button("onboarding.accessibility.enable") {
                coordinator.enableSelectionCapture()
            }
            .accessibilityHint("onboarding.accessibility.enable.hint")
        }
        .onAppear { coordinator.noteAccessibilityExplanationRendered() }
    }

    private var completeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("onboarding.complete.title").font(.title)
            Text("onboarding.complete.manualReady")
            Button("onboarding.finish") {
                coordinator.performOwned { await $0.finish() }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
