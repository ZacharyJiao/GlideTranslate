import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case selection
    case models
    case prompts
    case privacyHistory
    case about

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .general: "settings.general"
        case .selection: "settings.selection"
        case .models: "settings.models"
        case .prompts: "settings.prompts"
        case .privacyHistory: "settings.privacyHistory"
        case .about: "settings.about"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .selection: "selection.pin.in.out"
        case .models: "cpu"
        case .prompts: "text.quote"
        case .privacyHistory: "hand.raised"
        case .about: "info.circle"
        }
    }
}

enum SettingsInventory {
    static let allSectionIDs = SettingsSection.allCases.map(\.rawValue)
    static let allControlIDs = [
        "general.uiLanguage", "general.targetLanguage", "general.shortcut",
        "general.launchAtLogin", "general.defaultPreset", "general.defaultProvider",
        "general.automaticCapture",
        "selection.accessibility", "selection.applications", "selection.mouse",
        "selection.keyboard", "selection.debounce", "selection.limit",
        "selection.clipboardFallback",
        "models.ollama", "models.openAICompatible", "models.model",
        "models.connectionTest", "models.timeouts", "models.confirmDestination",
        "models.automaticApplications",
        "prompts.builtIns", "prompts.custom", "prompts.preview", "prompts.default",
        "privacyHistory.enabled", "privacyHistory.retention",
        "privacyHistory.maximumCount", "privacyHistory.search",
        "privacyHistory.exclusions", "privacyHistory.delete", "privacyHistory.clear",
        "privacyHistory.reset", "privacyHistory.diagnostics",
        "about.version", "about.licenses", "about.privacy", "about.source",
        "about.releases",
    ]
}

struct SettingsRootView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var selectedSection: SettingsSection

    init(
        viewModel: SettingsViewModel,
        initialSection: SettingsSection = .general
    ) {
        self.viewModel = viewModel
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.labelKey, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let error = viewModel.safeError {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.orange.opacity(0.12))
                    .accessibilityIdentifier("settings-safe-error")
                }
                detail
            }
        }
        .id(viewModel.snapshot.uiLanguage)
        .frame(minWidth: 760, minHeight: 560)
        .environment(\.locale, viewModel.uiLocale)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView(viewModel: viewModel)
        case .selection:
            SelectionSettingsView(viewModel: viewModel)
        case .models:
            ModelsSettingsView(viewModel: viewModel)
        case .prompts:
            PromptSettingsView(viewModel: viewModel)
        case .privacyHistory:
            PrivacyHistorySettingsView(viewModel: viewModel)
        case .about:
            AboutSettingsView()
        }
    }
}
