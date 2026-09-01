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

    var explanationKey: LocalizedStringKey {
        switch self {
        case .general: "settings.general.explanation"
        case .selection: "settings.selection.explanation"
        case .models: "settings.models.explanation"
        case .prompts: "settings.prompts.explanation"
        case .privacyHistory: "settings.privacyHistory.explanation"
        case .about: "settings.about.explanation"
        }
    }

    var usesAdaptiveSplitContent: Bool {
        self == .models || self == .prompts
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
        "models.connect", "models.activateModel", "models.timeouts",
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
            SettingsSidebar(selectedSection: $selectedSection)
            .navigationSplitViewColumnWidth(min: 188, ideal: 200, max: 216)
        } detail: {
            VStack(spacing: 0) {
                if let error = viewModel.safeError {
                    let localization = error.localization
                    GlideStatusSurface(
                        message: LocalizedStringKey(localization.messageKey),
                        nextAction: LocalizedStringKey(localization.nextActionKey)
                    )
                    .padding([.horizontal, .top], GlideVisualTokens.pagePadding)
                    .accessibilityIdentifier("settings-safe-error")
                }
                VStack(alignment: .leading, spacing: 16) {
                    GlidePageHeader(
                        title: selectedSection.labelKey,
                        explanation: selectedSection.explanationKey
                    )
                    detail
                        .id(selectedSection)
                        .transition(.opacity)
                }
                .frame(
                    maxWidth: selectedSection.usesAdaptiveSplitContent
                        ? .infinity
                        : GlideVisualTokens.readableDetailWidth,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .padding([.horizontal, .top], GlideVisualTokens.pagePadding)
                .padding(.bottom, 12)
                .animation(
                    .easeOut(duration: GlideMotionTokens.contentCrossfadeDuration),
                    value: selectedSection
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GlideVisualTokens.canvas)
        }
        .tint(GlideVisualTokens.actionEmerald)
        .frame(
            minWidth: 760,
            idealWidth: 820,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 620,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background {
            GlideWindowChrome(minimumSize: CGSize(width: 760, height: 560))
        }
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

struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsSection

    var body: some View {
        VStack(spacing: 0) {
            SettingsBrandHeader()
            Divider()
            List(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.labelKey, systemImage: section.symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(
                            selectedSection == section
                                ? Color.white
                                : GlideVisualTokens.primaryInk
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            if selectedSection == section {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(GlideVisualTokens.actionEmerald)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    selectedSection == section ? .isSelected : []
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowBackground(Color.clear)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .background(GlideVisualTokens.actionEmerald.opacity(0.085))
    }
}

struct SettingsBrandHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            Text("app.name")
                .font(.title3.weight(.semibold))
                .foregroundStyle(GlideVisualTokens.primaryInk)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 34)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(GlideVisualTokens.actionEmerald.opacity(0.085))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("app.name")
        .accessibilityIdentifier("settings.brand")
    }
}
