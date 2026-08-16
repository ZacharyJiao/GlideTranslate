@preconcurrency import ApplicationServices
import AppKit
import Foundation
import ModelProviders
import PrivacyStorage
import SelectionCapture
import ServiceManagement
import SharedSupport
import TranslationCore

enum CompositionComponent: CaseIterable, Equatable, Hashable, Sendable {
    case privacyStorage
    case modelProviders
    case translationEngine
    case selectionAuthorization
    case promptPresetFacade
    case diagnosticExportCoordinator
    case privacyResetService
    case coordinator
}

enum CompositionRow: Equatable, Sendable {
    case constructsOnce(CompositionComponent)
    case startsTriggersFromPreferences(mouse: Bool, keyboard: Bool)
    case routesMouseToCoordinatorExactlyOnce
    case routesKeyboardToCoordinatorExactlyOnce
    case routesShortcutToCoordinatorExactlyOnce
    case schedulesHistoryMaintenanceAtLaunchAndEvery24Hours
    case terminates(
        cancel: Int,
        stopMonitor: Int,
        unregisterShortcut: Int,
        closeStores: Int,
        plaintextCacheCount: Int
    )
}

enum ProductionCompositionFailure: Equatable, Sendable {
    case corruptPreferences
    case providerVaultRecoveryRequired
    case shortcutConflict
    case historyMaintenanceFailure
    case captureUnavailable
    case partialShutdown
}

struct CompositionFailureRow: Equatable, Sendable {
    let failure: ProductionCompositionFailure
    let automaticCaptureStopped: Bool
}

enum ProductionCompositionContract {
    static let rows: [CompositionRow] = [
        .constructsOnce(.privacyStorage),
        .constructsOnce(.modelProviders),
        .constructsOnce(.translationEngine),
        .constructsOnce(.selectionAuthorization),
        .constructsOnce(.promptPresetFacade),
        .constructsOnce(.diagnosticExportCoordinator),
        .constructsOnce(.privacyResetService),
        .constructsOnce(.coordinator),
        .startsTriggersFromPreferences(mouse: false, keyboard: false),
        .routesMouseToCoordinatorExactlyOnce,
        .routesKeyboardToCoordinatorExactlyOnce,
        .routesShortcutToCoordinatorExactlyOnce,
        .schedulesHistoryMaintenanceAtLaunchAndEvery24Hours,
        .terminates(
            cancel: 1,
            stopMonitor: 1,
            unregisterShortcut: 1,
            closeStores: 1,
            plaintextCacheCount: 0
        ),
    ]

    static let failureRows: [CompositionFailureRow] = [
        .init(failure: .corruptPreferences, automaticCaptureStopped: true),
        .init(failure: .providerVaultRecoveryRequired, automaticCaptureStopped: true),
        .init(failure: .shortcutConflict, automaticCaptureStopped: true),
        .init(failure: .historyMaintenanceFailure, automaticCaptureStopped: true),
        .init(failure: .captureUnavailable, automaticCaptureStopped: true),
        .init(failure: .partialShutdown, automaticCaptureStopped: true),
    ]
}

struct ProductionStorageFacades: Sendable {
    let preferences: any PreferencesStore
    let providerManagement: any ProviderManagement
    let history: any TranslationHistory
    let reset: any PrivacyDataResetting
}

struct ProductionCoreServices: Sendable {
    let storage: ProductionStorageFacades
    let providers: ModelProviderServices
    let engine: any TranslationEngine
    let presets: any PromptPresetStore
    let capture: SelectionCaptureServices
    let constructionCounts: [CompositionComponent: Int]
}

@MainActor
struct ProductionDiagnosticAdapters {
    let preview: any DiagnosticPreviewPresenting
    let destination: any DiagnosticDestinationPicking
    let writer: any DiagnosticFileWriting

    static var system: Self {
        Self(
            preview: ProductionDiagnosticPreviewPresenter(),
            destination: NSSavePanelDiagnosticDestinationPicker(),
            writer: AtomicDiagnosticFileWriter()
        )
    }
}

struct ProductionTriggerAdapters {
    let makeMonitor: @Sendable (
        @escaping @Sendable (CaptureTrigger) -> Void
    ) -> any SelectionTriggerMonitoring
    let makeShortcutRegistrar: @Sendable (
        @escaping @Sendable () -> Void
    ) -> any GlobalShortcutRegistering

    static let system = Self(
        makeMonitor: { SelectionCaptureFactory.makeTriggerMonitor(emit: $0) },
        makeShortcutRegistrar: {
            SelectionCaptureFactory.makeShortcutRegistrar(emit: $0)
        }
    )
}

protocol ProductionCoreBuilding: Sendable {
    func build(
        applicationSupportDirectory: URL,
        keychainServicePrefix: String,
        clock: any AppClock,
        diagnostics: any ProviderDiagnosticReporting
    ) async throws -> ProductionCoreServices
}

struct SystemProductionCoreBuilder: ProductionCoreBuilding {
    func build(
        applicationSupportDirectory: URL,
        keychainServicePrefix: String,
        clock: any AppClock,
        diagnostics: any ProviderDiagnosticReporting
    ) async throws -> ProductionCoreServices {
        let storage = try await PrivacyStorageFactory.make(
            configuration: .init(
                applicationSupportDirectory: applicationSupportDirectory,
                keychainServicePrefix: keychainServicePrefix
            ),
            clock: clock
        )
        let providers = ModelProviderFactory.make(
                vault: storage.providerVault,
                diagnostics: diagnostics
            )
            let engine = TranslationCoreFactory.makeEngine(
                provider: providers.service,
                preflight: providers.preflight,
                clock: clock
            )
            let presets = DefaultPromptPresetStore(
                persistence: storage.customPresets,
                validation: DefaultPromptPresetValidationService()
            )
            let capture = SelectionCaptureFactory.makeAuthorizationServices(
                snapshotReader: providers.preflight,
                clock: clock
            )
        return ProductionCoreServices(
                storage: ProductionStorageFacades(
                    preferences: storage.preferences,
                    providerManagement: storage.providerManagement,
                    history: storage.history,
                    reset: storage.reset
                ),
                providers: providers,
                engine: engine,
                presets: presets,
                capture: capture,
                constructionCounts: [
                    .privacyStorage: 1,
                    .modelProviders: 1,
                    .translationEngine: 1,
                    .selectionAuthorization: 1,
                    .promptPresetFacade: 1,
                ]
            )
    }
}

@MainActor
final class ProductionCompositionRoot {
    let sceneState: AppSceneState
    let settingsViewModel: SettingsViewModel
    let onboardingCoordinator: OnboardingCoordinator?
    let lifecycle: AppLifecycleController?
    let initialSnapshot: PreferencesSnapshot?
    let constructionCounts: [CompositionComponent: Int]
    private let lifecycleRelay: ProductionLifecycleRelay?

    private init(
        sceneState: AppSceneState,
        settingsViewModel: SettingsViewModel,
        onboardingCoordinator: OnboardingCoordinator? = nil,
        lifecycle: AppLifecycleController? = nil,
        lifecycleRelay: ProductionLifecycleRelay? = nil,
        initialSnapshot: PreferencesSnapshot? = nil,
        constructionCounts: [CompositionComponent: Int]
    ) {
        self.sceneState = sceneState
        self.settingsViewModel = settingsViewModel
        self.onboardingCoordinator = onboardingCoordinator
        self.lifecycle = lifecycle
        self.lifecycleRelay = lifecycleRelay
        self.initialSnapshot = initialSnapshot
        self.constructionCounts = constructionCounts
    }

    static func developmentFixture() -> ProductionCompositionRoot {
        ProductionCompositionRoot(
            sceneState: .development(),
            settingsViewModel: .development(),
            constructionCounts: Dictionary(
                uniqueKeysWithValues: CompositionComponent.allCases.map { ($0, 1) }
            )
        )
    }

    static func make(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        clock: any AppClock = SystemAppClock(),
        coreBuilder: any ProductionCoreBuilding = SystemProductionCoreBuilder(),
        diagnosticAdapters: ProductionDiagnosticAdapters = .system,
        triggerAdapters: ProductionTriggerAdapters = .system,
        resetOverride: (any SettingsResetting)? = nil,
        applicationSupportDirectoryOverride: URL? = nil,
        initialResetReport: ResetReport? = nil,
        performResetAndReplace:
            @escaping @MainActor @Sendable (
                any SettingsResetting
            ) async throws -> ResetReport
    ) async throws -> ProductionCompositionRoot {
        guard let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            throw ProductionCompositionBuildFailure.invalidBundleIdentifier
        }
        let applicationSupportDirectory: URL
        if let applicationSupportDirectoryOverride {
            applicationSupportDirectory = applicationSupportDirectoryOverride
        } else {
            let supportRoot = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            applicationSupportDirectory = supportRoot.appendingPathComponent(
                bundleIdentifier,
                isDirectory: true
            )
        }

        let safeLogger = SafeLogger()
        let core = try await coreBuilder.build(
            applicationSupportDirectory: applicationSupportDirectory,
            keychainServicePrefix: bundleIdentifier,
            clock: clock,
            diagnostics: AppProviderDiagnosticReporter(logger: safeLogger)
        )
        let storage = core.storage
        do {
        let snapshot = try await storage.preferences.snapshot()
        let providers = core.providers
        let engine = core.engine
        let presets = core.presets
        let capture = core.capture
        let descriptors = try await storage.providerManagement.descriptors()
        let customPresets = try await presets.customPresets()
        let builtIns = await presets.builtIns()
        let defaultProvider = descriptors.first { $0.id == snapshot.defaultProviderID }
        let accessibilityGranted = AXIsProcessTrusted()
        let providerOperational = defaultProvider.map {
            $0.privacyClass != .unresolvedOrChanged
        } ?? false

        let triggerRelay = ProductionTriggerRelay()
        let routingGate = ShortcutRoutingGate(enabled: true)
        let monitor = triggerAdapters.makeMonitor { trigger in
            triggerRelay.emit(trigger)
        }
        let shortcutRegistrar = triggerAdapters.makeShortcutRegistrar {
            routingGate.routeIfEnabled { triggerRelay.emit(.shortcut) }
        }
        let shortcutModel = ShortcutSettingsModel(
            registrar: shortcutRegistrar,
            currentDescriptor: snapshot.onboardingCompleted ? snapshot.shortcut : nil
        )
        let runtimeOperations = CompositionRuntimeOperationOwner()

        let panelController = ResultPanelController()
        let manualPresenter = ManualWindowPresenter()
        let settingsPresenter = SettingsWindowPresenter()
        let onboardingPresenter = OnboardingWindowPresenter()
        let feedbackPresenter = ProductionCoordinatorFeedbackPresenter(
            router: ProductionSafeNextActionRouter(
                manualInputPresenter: manualPresenter,
                settingsPresenter: settingsPresenter
            )
        )
        let lifecycleRelay = ProductionLifecycleRelay()
        let presentationRelay = ProductionPresentationRelay(
            lifecycle: lifecycleRelay,
            providerManagement: storage.providerManagement,
            promptStore: presets
        )
        let runtimeProjection = ProductionRuntimeProjectionRelay(
            preferences: storage.preferences,
            presentation: presentationRelay
        )
        let environment = AppEnvironment(
            systemSelectionProcessor: capture.systemSelectionProcessor,
            authorizationGate: capture.authorizationGate,
            translationEngine: engine,
            preferences: storage.preferences,
            providerManagement: storage.providerManagement,
            providerPreflight: providers.preflight,
            providerInspection: providers.inspection,
            providerConfirmation: providers.confirmation,
            promptPresets: presets,
            history: storage.history,
            logger: safeLogger
        )
        let coordinator = AppCoordinator(
            environment: environment,
            panelPresenter: panelController,
            manualInputPresenter: manualPresenter,
            feedbackPresenter: feedbackPresenter,
            resultCopyWriter: SystemTranslationResultCopyWriter(),
            foregroundApplicationDisabledChanged: { disabled in
                presentationRelay.setForegroundApplicationDisabled(disabled)
            },
            preferencesChanged: { _ in
                await runtimeProjection.refresh()
            }
        )

        let historyManager = ProductionSettingsHistoryManager(
            history: storage.history,
            promptPresets: presets
        )
        let diagnostics = DiagnosticExportCoordinator(
            reportBuilder: try makeDiagnosticReport(
                bundle: bundle,
                accessibilityGranted: accessibilityGranted,
                defaultProviderClass: defaultProvider?.privacyClass
                    ?? .unresolvedOrChanged,
                providerOperational: providerOperational
            ),
            previewPresenter: diagnosticAdapters.preview,
            destinationPicker: diagnosticAdapters.destination,
            writer: diagnosticAdapters.writer
        )
        let cacheController = ProductionTransientCacheController(
            panels: panelController,
            manualInput: coordinator.manualInputViewModel
        )
        let lifecycle = AppLifecycleController(
            monitor: monitor,
            shortcutRegistrar: shortcutRegistrar,
            shortcutModel: shortcutModel,
            history: historyManager,
            requests: coordinator,
            storageReset: storage.reset,
            caches: cacheController,
            clock: clock,
            safeStateChanged: { state in
                lifecycleRelay.publish(state)
            },
            route: { trigger in
                do {
                    let current = try await storage.preferences.snapshot()
                    await coordinator.handleSystemTrigger(
                        trigger,
                        sourceLanguage: .automatic,
                        targetLanguage: current.defaultTargetLanguage,
                        presetID: current.defaultPresetID
                    )
                } catch {
                    feedbackPresenter.presentSafeNextAction(
                        ((error as? SanitizedFailure) ?? .preferencesUnrecoverable)
                            .safeNextActionPresentation
                    )
                }
            }
        )
        lifecycleRelay.install(lifecycle)
        triggerRelay.install(lifecycle)
        let resetEffects = ProductionResetEffects(
            capture: ProductionCaptureResetController(lifecycle: lifecycle),
            requests: ProductionRequestResetController(coordinator: coordinator),
            routingGate: routingGate,
            shortcutRegistrar: ProductionShortcutResetController(
                registrar: shortcutRegistrar
            ),
            launchAtLogin: ProductionLaunchAtLoginResetController(),
            caches: cacheController
        )
        let reset: any SettingsResetting = resetOverride ?? PrivacyResetService(
            effects: resetEffects,
            storageReset: storage.reset
        )
        let selectionController = ProductionSettingsSelectionController(
            lifecycle: lifecycle,
            preferences: storage.preferences,
            initialSnapshot: snapshot
        )
        let settings = SettingsViewModel(
            initialSnapshot: snapshot,
            preferences: storage.preferences,
            shortcut: shortcutModel,
            launchAtLogin: SystemSettingsLaunchAtLoginController(),
            selection: selectionController,
            provider: ProductionSettingsProviderManager(
                management: storage.providerManagement
            ),
            inspection: ProductionSettingsProviderInspector(
                inspection: providers.inspection
            ),
            confirmation: ProductionSettingsProviderConfirmation(
                service: providers.confirmation
            ),
            promptStore: presets,
            history: historyManager,
            diagnostics: diagnostics,
            reset: reset,
            runtimeRefresh: ClosureSettingsRuntimeRefresh(
                operation: performResetAndReplace
            ),
            runtimeOperations: runtimeOperations,
            initialAccessibilityStatus: accessibilityGranted ? .granted : .denied,
            initialProviders: descriptors.map(ProductionSettingsProviderManager.map),
            initialResetReport: initialResetReport,
            snapshotChanged: { _ in
                await runtimeProjection.refresh()
            }
        )
        runtimeProjection.install(settings: settings)
        cacheController.install(settings: settings)

        configureManualInput(
            coordinator.manualInputViewModel,
            snapshot: snapshot,
            descriptors: descriptors,
            builtIns: builtIns,
            customPresets: customPresets
        )
        let presetPresentation = defaultPresetPresentation(
            snapshot.defaultPresetID,
            builtIns: builtIns,
            customPresets: customPresets
        )
        let sceneState = AppSceneState(
            coordinator: coordinator,
            manualPresenter: manualPresenter,
            settingsPresenter: settingsPresenter,
            onboardingPresenter: onboardingPresenter,
            shortcutSettingsModel: shortcutModel,
            captureState: captureMenuState(
                snapshot: snapshot,
                hasDefaultProvider: providerOperational
            ),
            automaticCapturePaused: !snapshot.automaticCaptureEnabled,
            presetName: presetPresentation.name,
            presetNameLocalizationKey: presetPresentation.localizationKey,
            providerLocality: defaultProvider?.privacyClass ?? .unresolvedOrChanged,
            presetOptions: menuPresetOptions(
                builtIns: builtIns,
                customPresets: customPresets
            )
        )
        presentationRelay.install(
            sceneState: sceneState,
            manualInput: coordinator.manualInputViewModel,
            shortcutModel: shortcutModel,
            builtIns: builtIns,
            customPresets: customPresets,
            providers: descriptors,
            initialSnapshot: snapshot
        )
        lifecycleRelay.install(presentation: presentationRelay)
        let onboarding: OnboardingCoordinator? = if snapshot.onboardingCompleted {
            nil
        } else {
            OnboardingCoordinator(
                preferences: storage.preferences,
                provider: ProductionOnboardingProviderService(
                    providerManagement: storage.providerManagement,
                    inspection: providers.inspection
                ),
                shortcut: shortcutModel,
                clipboard: SystemOnboardingClipboardWriter(),
                accessibility: SystemOnboardingAccessibilityPrompter(),
                onReplacementRequired: {},
                onFinished: { onboardingPresenter.dismiss() },
                shortcutStateChanged: {
                    await runtimeProjection.refresh()
                },
                preferencesChanged: { _ in
                    await runtimeProjection.refresh()
                },
                runtimeOperations: runtimeOperations
            )
        }
        return ProductionCompositionRoot(
            sceneState: sceneState,
            settingsViewModel: settings,
            onboardingCoordinator: onboarding,
            lifecycle: lifecycle,
            lifecycleRelay: lifecycleRelay,
            initialSnapshot: snapshot,
            constructionCounts: core.constructionCounts.merging([
                .diagnosticExportCoordinator: 1,
                .privacyResetService: 1,
                .coordinator: 1,
            ]) { current, added in current + added }
        )
        } catch {
            try? await storage.reset.closeStores()
            throw error
        }
    }

    func start() async {
        guard let lifecycle, let initialSnapshot else { return }
        await lifecycle.start(
            onboardingCompleted: initialSnapshot.onboardingCompleted,
            automaticCaptureEnabled: initialSnapshot.onboardingCompleted
                && initialSnapshot.automaticCaptureEnabled,
            mouseSelectionEnabled: initialSnapshot.mouseSelectionEnabled,
            keyboardSelectionEnabled: initialSnapshot.keyboardSelectionEnabled,
            shortcut: initialSnapshot.shortcut
        )
        if !initialSnapshot.onboardingCompleted {
            sceneState.onboardingPresenter.open()
        }
    }

    func observeLifecycleSafeState(
        _ observer: @escaping @MainActor @Sendable (AppLifecycleSafeState) -> Void
    ) {
        lifecycleRelay?.observe(observer)
    }

    func terminate() async {
        await settingsViewModel.retireExternalEffects()
        await lifecycle?.terminate()
    }

    func retireAfterReset() async {
        await settingsViewModel.retireExternalEffects()
        await lifecycle?.retireAfterReset()
    }

    private static func makeDiagnosticReport(
        bundle: Bundle,
        accessibilityGranted: Bool,
        defaultProviderClass: DestinationPrivacyClass,
        providerOperational: Bool
    ) throws -> DiagnosticReportBuilder {
        var health: [ComponentHealthCategory] = [.storageOperational]
        health.append(accessibilityGranted ? .captureOperational : .permissionLimited)
        health.append(providerOperational ? .providerOperational : .providerUnavailable)
        return try DiagnosticReportBuilder(
            appVersion: (bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String) ?? "1.0",
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: .current,
            accessibilityPermission: accessibilityGranted ? .granted : .denied,
            defaultProviderClass: defaultProviderClass,
            componentHealth: health,
            recentOutcomeCounts: [:]
        )
    }

    fileprivate static func configureManualInput(
        _ model: ManualInputViewModel,
        snapshot: PreferencesSnapshot,
        descriptors: [SanitizedProviderDescriptor],
        builtIns: [PromptPresetDescriptor],
        customPresets: [CustomPreset],
        preserveCurrentSelection: Bool = false
    ) {
        let currentSource = model.selectedSourceLanguage
        let currentTarget = model.selectedTargetLanguage
        let currentPreset = model.selectedPresetID
        let currentProvider = model.selectedProvider?.configurationID
        let source = [
            ManualLanguageOption(
                id: "automatic",
                labelKey: "language.automatic",
                value: .automatic
            ),
        ]
        let target = [
            ManualLanguageOption(
                id: "en",
                labelKey: "language.english",
                value: .identified("en")
            ),
            ManualLanguageOption(
                id: "zh-Hans",
                labelKey: "language.simplifiedChinese",
                value: .identified("zh-Hans")
            ),
        ]
        let manualPresets = builtIns.map {
            ManualPresetOption(id: $0.id, labelKey: $0.nameLocalizationKey)
        } + customPresets.map {
            ManualPresetOption(id: $0.id, label: $0.name)
        }
        let manualProviders = descriptors.map {
            ManualProviderOption(
                id: $0.id.rawValue.uuidString,
                configurationID: $0.id,
                label: $0.protocolKind.rawValue,
                labelKey: $0.protocolKind.localizationKey,
                locality: $0.privacyClass
            )
        }
        model.updateCharacterLimit(snapshot.selectionCharacterLimit)
        model.replaceOptions(
            source: source,
            target: target,
            presets: manualPresets,
            providers: manualProviders,
            preferredSource: preserveCurrentSelection ? currentSource : .automatic,
            preferredTarget: preserveCurrentSelection
                ? currentTarget : snapshot.defaultTargetLanguage,
            preferredPresetID: preserveCurrentSelection
                ? currentPreset : snapshot.defaultPresetID,
            preferredProviderID: preserveCurrentSelection
                ? currentProvider : snapshot.defaultProviderID
        )
    }

    private static func defaultPresetPresentation(
        _ id: PresetID,
        builtIns: [PromptPresetDescriptor],
        customPresets: [CustomPreset]
    ) -> (name: String, localizationKey: String?) {
        if let builtIn = builtIns.first(where: { $0.id == id }) {
            return (builtIn.nameLocalizationKey, builtIn.nameLocalizationKey)
        }
        if let custom = customPresets.first(where: { $0.id == id }) {
            return (custom.name, nil)
        }
        return ("—", nil)
    }

    private static func menuPresetOptions(
        builtIns: [PromptPresetDescriptor],
        customPresets: [CustomPreset]
    ) -> [MenuPresetOption] {
        builtIns.map {
            MenuPresetOption(
                id: $0.id,
                name: $0.nameLocalizationKey,
                nameLocalizationKey: $0.nameLocalizationKey
            )
        } + customPresets.map {
            MenuPresetOption(id: $0.id, name: $0.name)
        }
    }

    private static func captureMenuState(
        snapshot: PreferencesSnapshot,
        hasDefaultProvider: Bool
    ) -> CaptureMenuState {
        guard snapshot.onboardingCompleted,
              snapshot.automaticCaptureEnabled else { return .paused }
        guard AXIsProcessTrusted() else { return .permissionMissing }
        guard hasDefaultProvider else { return .providerUnavailable }
        return .running
    }
}

enum ProductionCompositionBuildFailure: Error, Equatable, Sendable {
    case invalidBundleIdentifier
}

private final class ProductionTriggerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var lifecycle: AppLifecycleController?

    @MainActor
    func install(_ lifecycle: AppLifecycleController) {
        lock.withLock { self.lifecycle = lifecycle }
    }

    func emit(_ trigger: CaptureTrigger) {
        Task { @MainActor [weak self] in
            let lifecycle = self?.lock.withLock { self?.lifecycle }
            await lifecycle?.route(trigger)
        }
    }
}

@MainActor
private final class ProductionLifecycleRelay: @unchecked Sendable {
    private weak var lifecycle: AppLifecycleController?
    private weak var presentation: ProductionPresentationRelay?
    private var observer:
        (@MainActor @Sendable (AppLifecycleSafeState) -> Void)?
    private(set) var transitionFailure: AppLifecycleTransitionFailure?

    func install(_ lifecycle: AppLifecycleController) {
        self.lifecycle = lifecycle
    }

    func install(presentation: ProductionPresentationRelay) {
        self.presentation = presentation
    }

    func observe(
        _ observer: @escaping @MainActor @Sendable (AppLifecycleSafeState) -> Void
    ) {
        self.observer = observer
    }

    func publish(_ state: AppLifecycleSafeState) {
        presentation?.applyLifecycleSafeState(state)
        observer?(state)
    }

    func apply(
        _ snapshot: PreferencesSnapshot,
        shortcutState: ShortcutRegistrationState
    ) async {
        guard let lifecycle else {
            transitionFailure = .inactive
            return
        }
        do {
            try await lifecycle.applyRuntimeState(
                snapshot,
                shortcutState: shortcutState
            )
            transitionFailure = nil
        } catch let failure as AppLifecycleTransitionFailure {
            transitionFailure = failure
        } catch {
            transitionFailure = .inactive
        }
    }
}

@MainActor
private final class ProductionRuntimeProjectionRelay: @unchecked Sendable {
    private let preferences: any PreferencesStore
    private let presentation: ProductionPresentationRelay
    private weak var settings: SettingsViewModel?
    private var generation: UInt = 0

    init(
        preferences: any PreferencesStore,
        presentation: ProductionPresentationRelay
    ) {
        self.preferences = preferences
        self.presentation = presentation
    }

    func install(settings: SettingsViewModel) {
        self.settings = settings
    }

    func refresh() async {
        generation &+= 1
        let currentGeneration = generation
        guard let stored = try? await preferences.snapshot() else { return }
        guard currentGeneration == generation else { return }
        settings?.applyExternalSnapshot(stored)
        await presentation.apply(stored)
    }
}

@MainActor
private final class ProductionPresentationRelay: @unchecked Sendable {
    private let lifecycle: ProductionLifecycleRelay
    private let providerManagement: any ProviderManagement
    private let promptStore: any PromptPresetStore
    private weak var sceneState: AppSceneState?
    private weak var manualInput: ManualInputViewModel?
    private weak var shortcutModel: ShortcutSettingsModel?
    private var builtIns: [PromptPresetDescriptor] = []
    private var providers: [SanitizedProviderDescriptor] = []
    private var customPresets: [CustomPreset] = []
    private var builtInNames: [PresetID: String] = [:]
    private var customNames: [PresetID: String] = [:]
    private var providerClasses: [ProviderConfigurationID: DestinationPrivacyClass] = [:]
    private var refreshGeneration: UInt = 0
    private var lifecycleSafeState: AppLifecycleSafeState = .ready
    private var latestSnapshot: PreferencesSnapshot?
    private var foregroundApplicationDisabled = false

    init(
        lifecycle: ProductionLifecycleRelay,
        providerManagement: any ProviderManagement,
        promptStore: any PromptPresetStore
    ) {
        self.lifecycle = lifecycle
        self.providerManagement = providerManagement
        self.promptStore = promptStore
    }

    func install(
        sceneState: AppSceneState,
        manualInput: ManualInputViewModel,
        shortcutModel: ShortcutSettingsModel,
        builtIns: [PromptPresetDescriptor],
        customPresets: [CustomPreset],
        providers: [SanitizedProviderDescriptor],
        initialSnapshot: PreferencesSnapshot
    ) {
        self.sceneState = sceneState
        self.manualInput = manualInput
        self.shortcutModel = shortcutModel
        self.builtIns = builtIns
        self.providers = providers
        self.customPresets = customPresets
        latestSnapshot = initialSnapshot
        builtInNames = Dictionary(
            uniqueKeysWithValues: builtIns.map { ($0.id, $0.nameLocalizationKey) }
        )
        customNames = Dictionary(
            uniqueKeysWithValues: customPresets.map { ($0.id, $0.name) }
        )
        providerClasses = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.id, $0.privacyClass) }
        )
    }

    func applyLifecycleSafeState(_ state: AppLifecycleSafeState) {
        lifecycleSafeState = state
        if let snapshot = latestSnapshot {
            updateCaptureState(snapshot)
        }
    }

    func setForegroundApplicationDisabled(_ disabled: Bool) {
        foregroundApplicationDisabled = disabled
        if let snapshot = latestSnapshot {
            updateCaptureState(snapshot)
        }
    }

    func apply(_ snapshot: PreferencesSnapshot) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        latestSnapshot = snapshot
        await lifecycle.apply(
            snapshot,
            shortcutState: shortcutModel?.state ?? .unavailable
        )
        async let providerLoad = providerManagement.descriptors()
        async let customLoad = promptStore.customPresets()
        let providers = try? await providerLoad
        let customPresets = try? await customLoad
        guard generation == refreshGeneration else { return }
        if let providers {
            self.providers = providers
            providerClasses = Dictionary(
                uniqueKeysWithValues: providers.map { ($0.id, $0.privacyClass) }
            )
        }
        if let customPresets {
            self.customPresets = customPresets
            customNames = Dictionary(
                uniqueKeysWithValues: customPresets.map { ($0.id, $0.name) }
            )
        }
        if let manualInput {
            ProductionCompositionRoot.configureManualInput(
                manualInput,
                snapshot: snapshot,
                descriptors: self.providers,
                builtIns: builtIns,
                customPresets: self.customPresets,
                preserveCurrentSelection: true
            )
        }
        guard let sceneState else { return }
        sceneState.presetOptions = builtIns.map {
            MenuPresetOption(
                id: $0.id,
                name: $0.nameLocalizationKey,
                nameLocalizationKey: $0.nameLocalizationKey
            )
        } + customNames.map {
            MenuPresetOption(id: $0.key, name: $0.value)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        updateCaptureState(snapshot)
        if let localizationKey = builtInNames[snapshot.defaultPresetID] {
            sceneState.presetName = localizationKey
            sceneState.presetNameLocalizationKey = localizationKey
        } else if let name = customNames[snapshot.defaultPresetID] {
            sceneState.presetName = name
            sceneState.presetNameLocalizationKey = nil
        }
        sceneState.providerLocality = snapshot.defaultProviderID
            .flatMap { providerClasses[$0] } ?? .unresolvedOrChanged
    }

    private func updateCaptureState(_ snapshot: PreferencesSnapshot) {
        guard let sceneState else { return }
        sceneState.automaticCapturePaused = !snapshot.automaticCaptureEnabled
        switch lifecycleSafeState {
        case .ready:
            break
        case .shortcutReplacementRequired, .shortcutUnavailable:
            sceneState.captureState = .shortcutUnavailable
            return
        case .historyMaintenanceUnavailable:
            sceneState.captureState = .historyUnavailable
            return
        case .captureUnavailable:
            sceneState.captureState = .captureUnavailable
            return
        case .resetting:
            sceneState.captureState = .resetting
            return
        case .partialShutdown, .terminated:
            sceneState.captureState = .captureUnavailable
            return
        }
        if !snapshot.onboardingCompleted || !snapshot.automaticCaptureEnabled {
            sceneState.captureState = .paused
        } else if foregroundApplicationDisabled {
            sceneState.captureState = .foregroundAppDisabled
        } else if !AXIsProcessTrusted() {
            sceneState.captureState = .permissionMissing
        } else if snapshot.defaultProviderID.flatMap({ providerClasses[$0] })
            .map({ $0 == .unresolvedOrChanged }) ?? true {
            sceneState.captureState = .providerUnavailable
        } else {
            sceneState.captureState = .running
        }
    }
}

@MainActor
protocol SafeNextActionRouting: AnyObject {
    func route(_ action: SafeNextAction)
}

enum SafeNextActionDestination: Equatable, Sendable {
    case settings
    case manualInput
    case accessibilitySettings
}

extension SafeNextAction {
    var explicitDestination: SafeNextActionDestination? {
        switch self {
        case .openAccessibilitySettingsOrUseManualInput:
            .accessibilitySettings
        case .openManualInput, .useManualInput:
            .manualInput
        case .none:
            nil
        case .resumeAutomaticOrUseShortcut,
             .enableApplicationOrUseShortcut,
             .authorizeApplicationOrUseExplicitAction,
             .showLocalRuntimeGuidance,
             .chooseOrInstallModelManually,
             .openModelSettings,
             .replaceCredential,
             .reconfirmDestination,
             .retryOrAdjustTimeout,
             .retryOrReviewProvider,
             .explainHistoryDisabled,
             .explainApplicationExcluded,
             .deleteAndRestartHistory:
            .settings
        }
    }

    var actionButtonLocalizationKey: String? {
        switch explicitDestination {
        case .settings: "menu.settings"
        case .manualInput: "manual.title"
        case .accessibilitySettings: "selection.accessibility.openSettings"
        case nil: nil
        }
    }
}

@MainActor
final class ProductionSafeNextActionRouter: SafeNextActionRouting {
    typealias Route = @MainActor () -> Void

    private let openSettings: Route
    private let openManualInput: Route
    private let openAccessibilitySettings: Route

    init(
        openSettings: @escaping Route,
        openManualInput: @escaping Route,
        openAccessibilitySettings: @escaping Route
    ) {
        self.openSettings = openSettings
        self.openManualInput = openManualInput
        self.openAccessibilitySettings = openAccessibilitySettings
    }

    convenience init(
        manualInputPresenter: ManualWindowPresenter,
        settingsPresenter: SettingsWindowPresenter
    ) {
        self.init(
            openSettings: { settingsPresenter.open() },
            openManualInput: { manualInputPresenter.open() },
            openAccessibilitySettings: {
                SystemSettingsAccessibilityClient().openSystemSettings()
            }
        )
    }

    func route(_ action: SafeNextAction) {
        switch action.explicitDestination {
        case .settings: openSettings()
        case .manualInput: openManualInput()
        case .accessibilitySettings: openAccessibilitySettings()
        case nil: break
        }
    }
}

@MainActor
final class ProductionCoordinatorFeedbackPresenter:
    CoordinatorFeedbackPresenting,
    @unchecked Sendable
{
    typealias AlertRunner = @MainActor (
        _ presentation: SafeNextActionPresentation,
        _ actionButtonTitle: String?,
        _ locale: Locale
    ) -> Bool

    private let router: any SafeNextActionRouting
    private let alertRunner: AlertRunner

    init(
        router: any SafeNextActionRouting,
        alertRunner: @escaping AlertRunner = ProductionCoordinatorFeedbackPresenter
            .runSystemAlert
    ) {
        self.router = router
        self.alertRunner = alertRunner
    }

    func presentSafeNextAction(_ presentation: SafeNextActionPresentation) {
        let locale = AppUILocaleState.shared.current
        let actionButtonTitle = presentation.action.actionButtonLocalizationKey.map {
            String(localized: String.LocalizationValue($0), locale: locale)
        }
        guard alertRunner(presentation, actionButtonTitle, locale),
              presentation.action.explicitDestination != nil else { return }
        router.route(presentation.action)
    }

    private static func runSystemAlert(
        _ presentation: SafeNextActionPresentation,
        actionButtonTitle: String?,
        locale: Locale
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: String.LocalizationValue(presentation.messageKey),
            locale: locale
        )
        alert.informativeText = String(
            localized: String.LocalizationValue(presentation.nextActionKey),
            locale: locale
        )
        if let actionButtonTitle {
            alert.addButton(withTitle: actionButtonTitle)
            alert.addButton(
                withTitle: String(localized: "common.cancel", locale: locale)
            )
        } else {
            alert.addButton(withTitle: Self.okButtonTitle(locale: locale))
        }
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn && actionButtonTitle != nil
    }

    static func okButtonTitle(locale: Locale) -> String {
        let fallback = String(localized: "common.ok", locale: locale)
        let localization = locale.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
        guard
            let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return fallback
        }
        return bundle.localizedString(
            forKey: "common.ok",
            value: fallback,
            table: nil
        )
    }
}

@MainActor
private final class ProductionDiagnosticPreviewPresenter: DiagnosticPreviewPresenting {
    func show(_ preview: DiagnosticPreview) async -> Bool {
        let locale = AppUILocaleState.shared.current
        let alert = NSAlert()
        alert.messageText = String(
            localized: "privacyHistory.diagnostics.preview.title",
            locale: locale
        )
        alert.informativeText = String(data: preview.reportData, encoding: .utf8) ?? "{}"
        alert.addButton(withTitle: String(localized: "common.save", locale: locale))
        alert.addButton(withTitle: String(localized: "common.cancel", locale: locale))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
private struct ClosureSettingsRuntimeRefresh: SettingsRuntimeRefreshing {
    let operation: @MainActor @Sendable (
        any SettingsResetting
    ) async throws -> ResetReport

    func resetAndReplace(using reset: any SettingsResetting) async throws -> ResetReport {
        try await operation(reset)
    }
}

@MainActor
private final class ProductionCaptureResetController: CaptureResetControlling {
    let lifecycle: AppLifecycleController
    init(lifecycle: AppLifecycleController) { self.lifecycle = lifecycle }
    func pauseForReset() async throws { await lifecycle.prepareForReset() }
}

@MainActor
private final class ProductionRequestResetController: RequestResetControlling {
    weak var coordinator: AppCoordinator?
    init(coordinator: AppCoordinator) { self.coordinator = coordinator }
    func cancelForReset() async throws { await coordinator?.terminate() }
}

@MainActor
private final class ProductionShortcutResetController: ShortcutResetRegistering {
    let registrar: any GlobalShortcutRegistering
    init(registrar: any GlobalShortcutRegistering) { self.registrar = registrar }
    func unregisterForReset() async throws { await registrar.unregister() }
}

@MainActor
private final class ProductionLaunchAtLoginResetController:
    LaunchAtLoginResetControlling
{
    func unregisterForReset() async throws {
        if SMAppService.mainApp.status == .enabled {
            try await SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
private final class ProductionTransientCacheController:
    CacheResetControlling,
    LifecycleCacheControlling,
    @unchecked Sendable
{
    private let panels: ResultPanelController
    private weak var manualInput: ManualInputViewModel?
    private weak var settings: SettingsViewModel?

    init(
        panels: ResultPanelController,
        manualInput: ManualInputViewModel
    ) {
        self.panels = panels
        self.manualInput = manualInput
    }
    func install(settings: SettingsViewModel) { self.settings = settings }

    func clearForReset() async throws { await clearTransientState() }

    func clearTransientState() async {
        panels.dismissAll()
        settings?.clearHistoryViewCache()
        manualInput?.clearTransientState()
    }

    var plaintextCount: Int {
        get async {
            panels.plaintextPresentationCount
                + (settings?.historyRecords.count ?? 0)
                + ((manualInput?.text.isEmpty == false) ? 1 : 0)
        }
    }
}

@MainActor
private struct SystemOnboardingClipboardWriter: OnboardingClipboardWriting {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
private struct SystemTranslationResultCopyWriter: TranslationResultCopying {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
private struct SystemOnboardingAccessibilityPrompter: AccessibilityPrompting {
    func requestSelectionAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
