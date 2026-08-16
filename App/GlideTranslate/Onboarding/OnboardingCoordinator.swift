import Foundation
import ModelProviders
import Observation
import PrivacyStorage
import SelectionCapture
import SharedSupport

protocol OnboardingProviderServicing: Sendable {
    func ensureDefaultOllama() async throws -> ProviderConfigurationID
    func discoverModels(for id: ProviderConfigurationID) async throws -> [String]
    func selectModel(_ model: String, for id: ProviderConfigurationID) async throws
}

protocol OnboardingProviderManaging: Sendable {
    func ensureDefaultOllama() async throws -> ProviderConfigurationID
    func updateOllamaModel(_ model: String, for id: ProviderConfigurationID) async throws
}

@MainActor
protocol OnboardingClipboardWriting: Sendable {
    func copy(_ text: String)
}

@MainActor
protocol AccessibilityPrompting: Sendable {
    func requestSelectionAccess() -> Bool
}

enum OllamaDetectionState: Equatable, Sendable {
    case notChecked
    case checking
    case available(models: [String])
    case modelsEmpty
    case unavailable
}

enum OnboardingSafeError: CaseIterable, Equatable, Sendable {
    case explanationRequired
    case providerUnavailable
    case shortcutUnavailable
    case persistenceFailed
    case invalidModel
}

enum OnboardingShortcutChoice: String, CaseIterable, Identifiable, Sendable {
    case optionShiftF
    case optionShiftG
    case optionShiftT

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionShiftF: "⌥⇧F"
        case .optionShiftG: "⌥⇧G"
        case .optionShiftT: "⌥⇧T"
        }
    }

    var descriptor: ShortcutDescriptor {
        let keyCode: UInt32 = switch self {
        case .optionShiftF: 3
        case .optionShiftG: 5
        case .optionShiftT: 17
        }
        return ShortcutDescriptor(
            keyCode: keyCode,
            modifiers: ShortcutDescriptor.defaultOptionShiftD.modifiers
        )
    }
}

@MainActor
@Observable
final class OnboardingCoordinator {
    static let installGuidance = """
    brew install ollama
    ollama serve
    ollama pull <model>
    """

    private(set) var step: OnboardingStep
    private(set) var ollamaState: OllamaDetectionState = .notChecked
    private(set) var safeError: OnboardingSafeError?
    private(set) var accessibilityExplanationRenderCount = 0
    private(set) var accessibilityGranted = false
    var manualModelName = ""

    private let preferences: any PreferencesStore
    private let provider: any OnboardingProviderServicing
    private let shortcut: ShortcutSettingsModel
    private let clipboard: any OnboardingClipboardWriting
    private let accessibility: any AccessibilityPrompting
    private let onReplacementRequired: @MainActor @Sendable () -> Void
    private let onFinished: @MainActor @Sendable () -> Void
    private let shortcutStateChanged:
        (@MainActor @Sendable () async -> Void)?
    private let preferencesChanged:
        (@MainActor @Sendable (PreferencesSnapshot) async -> Void)?
    private let runtimeOperations: CompositionRuntimeOperationOwner
    private var detectedProviderID: ProviderConfigurationID?
    private var committedModelSelection:
        (providerID: ProviderConfigurationID, model: String)?

    var requiresShortcutReplacement: Bool { shortcut.requiresReplacement }

    var canSelectManualModel: Bool {
        let model = manualModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.isEmpty && model.count <= 256
    }

    init(
        initialStep: OnboardingStep = .privacyModel,
        preferences: any PreferencesStore,
        provider: any OnboardingProviderServicing,
        shortcut: ShortcutSettingsModel,
        clipboard: any OnboardingClipboardWriting,
        accessibility: any AccessibilityPrompting,
        onReplacementRequired: @escaping @MainActor @Sendable () -> Void,
        onFinished: @escaping @MainActor @Sendable () -> Void = {},
        shortcutStateChanged:
            (@MainActor @Sendable () async -> Void)? = nil,
        preferencesChanged:
            (@MainActor @Sendable (PreferencesSnapshot) async -> Void)? = nil,
        runtimeOperations: CompositionRuntimeOperationOwner = .init()
    ) {
        step = initialStep
        self.preferences = preferences
        self.provider = provider
        self.shortcut = shortcut
        self.clipboard = clipboard
        self.accessibility = accessibility
        self.onReplacementRequired = onReplacementRequired
        self.onFinished = onFinished
        self.shortcutStateChanged = shortcutStateChanged
        self.preferencesChanged = preferencesChanged
        self.runtimeOperations = runtimeOperations
    }

    func performOwned(
        _ operation: @escaping @MainActor @Sendable (OnboardingCoordinator) async -> Void
    ) {
        runtimeOperations.submit { [weak self] in
            guard let self else { return }
            await operation(self)
        }
    }

    func skip() {
        guard step != .complete else { return }
        safeError = nil
        step = step.next
    }

    func continueCurrentStep() async {
        safeError = nil
        switch step {
        case .privacyModel, .localOllama, .accessibility:
            step = step.next
        case .shortcut:
            await registerShortcut(.defaultOptionShiftD)
        case .complete:
            await finish()
        }
    }

    func detectOllama() async {
        safeError = nil
        ollamaState = .checking
        do {
            let id = try await provider.ensureDefaultOllama()
            if detectedProviderID != id {
                committedModelSelection = nil
            }
            detectedProviderID = id
            let models = try await provider.discoverModels(for: id)
            ollamaState = models.isEmpty ? .modelsEmpty : .available(models: models)
        } catch {
            detectedProviderID = nil
            ollamaState = .unavailable
            safeError = .providerUnavailable
        }
    }

    func selectModel(_ model: String) async {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 256 else {
            safeError = .invalidModel
            return
        }
        guard let detectedProviderID else {
            safeError = .providerUnavailable
            return
        }
        if committedModelSelection?.providerID != detectedProviderID
            || committedModelSelection?.model != model {
            do {
                try await provider.selectModel(model, for: detectedProviderID)
                committedModelSelection = (detectedProviderID, model)
            } catch {
                safeError = .providerUnavailable
                return
            }
        }
        do {
            try await preferences.update {
                $0.defaultProviderID = detectedProviderID
            }
            let snapshot = try await preferences.snapshot()
            await preferencesChanged?(snapshot)
            committedModelSelection = nil
            step = .shortcut
            safeError = nil
        } catch {
            safeError = .persistenceFailed
        }
    }

    func selectManualModel() async {
        guard canSelectManualModel else {
            safeError = .invalidModel
            return
        }
        await selectModel(manualModelName)
    }

    func registerReplacement(_ choice: OnboardingShortcutChoice) async {
        await registerShortcut(choice.descriptor)
    }

    func copyInstallGuidance() {
        clipboard.copy(Self.installGuidance)
    }

    func noteAccessibilityExplanationRendered() {
        accessibilityExplanationRenderCount &+= 1
    }

    func enableSelectionCapture() {
        guard accessibilityExplanationRenderCount > 0 else {
            safeError = .explanationRequired
            return
        }
        accessibilityGranted = accessibility.requestSelectionAccess()
        safeError = nil
    }

    func finish() async {
        do {
            try await preferences.update { $0.onboardingCompleted = true }
            let snapshot = try await preferences.snapshot()
            await preferencesChanged?(snapshot)
            safeError = nil
            onFinished()
        } catch {
            safeError = .persistenceFailed
        }
    }

    private func registerShortcut(_ descriptor: ShortcutDescriptor) async {
        await shortcut.register(descriptor)
        await shortcutStateChanged?()
        switch shortcut.state {
        case .unregistered:
            safeError = .shortcutUnavailable
        case .registered:
            do {
                try await preferences.update { $0.shortcut = descriptor }
                let snapshot = try await preferences.snapshot()
                await preferencesChanged?(snapshot)
                step = .accessibility
                safeError = nil
            } catch {
                safeError = .persistenceFailed
            }
        case .replacementRequired:
            onReplacementRequired()
        case .unavailable:
            safeError = .shortcutUnavailable
        }
    }
}

struct ProductionOnboardingProviderService: OnboardingProviderServicing {
    private let management: any OnboardingProviderManaging
    private let inspection: any ProviderInspection

    init(
        management: any OnboardingProviderManaging,
        inspection: any ProviderInspection
    ) {
        self.management = management
        self.inspection = inspection
    }

    init(
        providerManagement: any ProviderManagement,
        inspection: any ProviderInspection
    ) {
        management = StorageOnboardingProviderManager(
            management: providerManagement
        )
        self.inspection = inspection
    }

    func ensureDefaultOllama() async throws -> ProviderConfigurationID {
        try await management.ensureDefaultOllama()
    }

    func discoverModels(for id: ProviderConfigurationID) async throws -> [String] {
        do {
            return try await inspection.discoverModels(for: id)
        } catch let failure as SanitizedFailure where failure == .modelUnavailable {
            return []
        }
    }

    func selectModel(_ model: String, for id: ProviderConfigurationID) async throws {
        try await management.updateOllamaModel(model, for: id)
    }
}

private struct StorageOnboardingProviderManager: OnboardingProviderManaging {
    let management: any ProviderManagement

    func ensureDefaultOllama() async throws -> ProviderConfigurationID {
        try await management.ensureDefaultOllamaConfiguration().id
    }

    func updateOllamaModel(
        _ model: String,
        for id: ProviderConfigurationID
    ) async throws {
        let endpoint = URL(string: "http://127.0.0.1:11434")!
        _ = try await management.update(
            id,
            draft: ProviderConfigurationDraft(
                protocolKind: .ollamaNative,
                endpoint: endpoint,
                model: model
            ),
            credential: .preserve
        )
    }
}
