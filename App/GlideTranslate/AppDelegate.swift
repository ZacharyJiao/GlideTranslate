import AppKit
import Combine
import CoreGraphics
import SharedSupport

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private enum UITestingSignal {
        static let showPanel = Notification.Name(
            "com.zaryolabs.GlideTranslate.ui-testing.show-passive-panel"
        )
        static let passivePanelReady = Notification.Name(
            "com.zaryolabs.GlideTranslate.ui-testing.passive-panel-ready"
        )
        static let copyCompleted = Notification.Name(
            "com.zaryolabs.GlideTranslate.ui-testing.copy-completed"
        )
    }

    private var uiTestingPanelController: ResultPanelController?
    private var uiTestingFeedbackPresenter: ProductionCoordinatorFeedbackPresenter?
    private var observesUITestingSignals = false
    private var startupTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private let transitionGate = ApplicationRuntimeTransitionGate()
    private let productionRootFactory:
        (@MainActor @Sendable (ResetReport?) async throws -> ProductionCompositionRoot)?

    @Published private(set) var composition: ProductionCompositionRoot?
    @Published private(set) var startupState: ProductionStartupSafeState = .idle
    @Published private(set) var lastResetReport: ResetReport?
    @Published private(set) var resetFailurePresentation:
        ProductionResetFailurePresentation?

    override init() {
        productionRootFactory = nil
        super.init()
        // UI automation must have a stable, effect-free graph before SwiftUI
        // evaluates the MenuBarExtra label and installs its window bridge.
        if UITestingMode.isEnabled {
            composition = .developmentFixture()
            startupState = .ready
        }
    }

    init(
        productionRootFactory:
            @escaping @MainActor @Sendable (
                ResetReport?
            ) async throws -> ProductionCompositionRoot
    ) {
        self.productionRootFactory = productionRootFactory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if UITestingMode.isEnabled {
            installUITestingFixtureIfRequested()
            return
        }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }

        startupState = .loading
        startupTask = Task { [weak self] in
            await self?.constructProductionRuntime()
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if UITestingMode.isEnabled { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        transitionGate.beginTermination()
        startupTask?.cancel()
        terminationTask = Task { [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await self.startupTask?.value
            await self.transitionGate.waitForReplacementToFinish()
            let current = self.composition
            self.composition = nil
            await current?.terminate()
            self.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        uiTestingPanelController?.dismissAll()
        if observesUITestingSignals {
            DistributedNotificationCenter.default().removeObserver(self)
        }
    }

    private func constructProductionRuntime(initialResetReport: ResetReport? = nil) async {
        guard let generation = transitionGate.startupToken() else { return }
        do {
            let root = try await makeProductionRoot(
                initialResetReport: initialResetReport
            )
            guard transitionGate.isCurrent(generation) else {
                await root.terminate()
                return
            }
            composition = root
            resetFailurePresentation = nil
            observeLifecycle(of: root)
            await root.start()
        } catch {
            composition = nil
            startupState = .failed(Self.safeFailure(for: error))
        }
    }

    private func makeProductionRoot(
        initialResetReport: ResetReport?
    ) async throws -> ProductionCompositionRoot {
        if let productionRootFactory {
            return try await productionRootFactory(initialResetReport)
        }
        return try await ProductionCompositionRoot.make(
            initialResetReport: initialResetReport,
            performResetAndReplace: { [weak self] reset in
                guard let self else {
                    throw ProductionRuntimeReplacementFailure.ownerUnavailable
                }
                return try await self.performResetAndReplace(using: reset)
            }
        )
    }

    func performResetAndReplace(
        using reset: any SettingsResetting
    ) async throws -> ResetReport {
        try await transitionGate.withReplacementTransaction { generation in
            self.startupState = .loading
            self.resetFailurePresentation = nil
            let report = await reset.resetAll()
            self.lastResetReport = report
            do {
                try await self.replaceRuntime(after: report, generation: generation)
            } catch {
                self.publishResetReplacementFailure(report, underlying: error)
                throw SettingsRuntimeRefreshFailure.replacementFailed(report: report)
            }
            return report
        }
    }

    private func replaceRuntime(
        after report: ResetReport,
        generation: UInt
    ) async throws {
        let previous = composition
        composition = nil
        await previous?.retireAfterReset()
        guard transitionGate.isCurrent(generation) else {
            throw ProductionRuntimeReplacementFailure.transitionUnavailable
        }
        do {
            let replacement = try await makeProductionRoot(
                initialResetReport: report
            )
            guard transitionGate.isCurrent(generation) else {
                await replacement.terminate()
                throw ProductionRuntimeReplacementFailure.transitionUnavailable
            }
            composition = replacement
            observeLifecycle(of: replacement)
            await replacement.start()
        } catch {
            startupState = .failed(Self.safeFailure(for: error))
            throw error
        }
    }

    private func observeLifecycle(of root: ProductionCompositionRoot) {
        root.observeLifecycleSafeState { [weak self, weak root] state in
            guard let self, let root, self.composition === root else { return }
            self.startupState = ProductionStartupSafeState(lifecycleState: state)
        }
    }

    func publishResetReplacementFailure(
        _ report: ResetReport,
        underlying error: Error
    ) {
        let failure = Self.safeFailure(for: error)
        composition = nil
        lastResetReport = report
        resetFailurePresentation = ProductionResetFailurePresentation(
            runtimeFailure: failure,
            report: report
        )
        startupState = .failed(failure)
    }

    private func installUITestingFixtureIfRequested() {
        if UITestingMode.includes("--ui-testing-passive-panel") {
            uiTestingPanelController = ResultPanelController()
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(showSyntheticResultPanel),
                name: UITestingSignal.showPanel,
                object: nil
            )
            observesUITestingSignals = true
            DistributedNotificationCenter.default().post(
                name: UITestingSignal.passivePanelReady,
                object: nil,
                userInfo: nil
            )
        }

        guard let fixture = Self.safeNextActionFixture,
              fixture.action != .none,
              let sceneState = composition?.sceneState
        else { return }
        let presenter = ProductionCoordinatorFeedbackPresenter(
            router: ProductionSafeNextActionRouter(
                manualInputPresenter: sceneState.manualPresenter,
                settingsPresenter: sceneState.settingsPresenter
            )
        )
        uiTestingFeedbackPresenter = presenter
        DispatchQueue.main.async {
            presenter.presentSafeNextAction(fixture)
        }
    }

    private static var safeNextActionFixture: SafeNextActionPresentation? {
        let prefix = "--ui-testing-safe-next-action="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix(prefix)
        }) else { return nil }
        switch String(argument.dropFirst(prefix.count)) {
        case "settings":
            return SanitizedFailure.invalidProviderConfiguration
                .safeNextActionPresentation
        case "manual":
            return SanitizedFailure.noValidSelection.safeNextActionPresentation
        case "local-guidance":
            return SanitizedFailure.ollamaUnavailable.safeNextActionPresentation
        case "reconfirmation":
            return SanitizedFailure.destinationReconfirmationRequired
                .safeNextActionPresentation
        case "storage-recovery":
            return SanitizedFailure.historyUnrecoverable.safeNextActionPresentation
        case "cancelled":
            return SanitizedFailure.cancelled.safeNextActionPresentation
        default:
            return nil
        }
    }

    private static func safeFailure(for error: Error) -> ProductionCompositionFailure {
        switch error as? SanitizedFailure {
        case .providerRecoveryRequired, .credentialStoreUnavailable:
            .providerVaultRecoveryRequired
        case .preferencesUnrecoverable:
            .corruptPreferences
        default:
            .corruptPreferences
        }
    }

    @objc private func showSyntheticResultPanel() {
        guard let controller = uiTestingPanelController else { return }
        let resultText = UITestingMode.includes("--ui-testing-long-result")
            ? String(repeating: "synthetic result line ", count: 200)
            : "focus-fixture-result"
        let presentation = TranslationPresentation(
            sourceText: "focus-fixture-source",
            resultText: resultText,
            presetID: PresetID(rawValue: "translate"),
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .localOnDevice,
            displayRect: nil,
            phase: .completed
        )
        controller.showTemporary(
            TranslationPresentation(
                sourceText: presentation.sourceText,
                resultText: "",
                presetID: presentation.presetID,
                sourceLanguage: presentation.sourceLanguage,
                targetLanguage: presentation.targetLanguage,
                providerClass: presentation.providerClass,
                displayRect: presentation.displayRect,
                phase: .preparing
            ),
            actions: ResultPanelActions(
                copy: {
                    DistributedNotificationCenter.default().post(
                        name: UITestingSignal.copyCompleted,
                        object: nil,
                        userInfo: nil
                    )
                },
                retry: {},
                changePreset: {},
                close: { [weak controller] in controller?.dismissTemporary() }
            )
        )
        controller.updateTemporary(presentation)
    }
}

extension ProductionStartupSafeState {
    init(lifecycleState: AppLifecycleSafeState) {
        switch lifecycleState {
        case .ready:
            self = .ready
        case .shortcutReplacementRequired, .shortcutUnavailable:
            self = .failed(.shortcutConflict)
        case .historyMaintenanceUnavailable:
            self = .failed(.historyMaintenanceFailure)
        case .captureUnavailable:
            self = .failed(.captureUnavailable)
        case .resetting:
            self = .loading
        case .partialShutdown, .terminated:
            self = .failed(.partialShutdown)
        }
    }
}

enum ProductionStartupSafeState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(ProductionCompositionFailure)
}

enum ProductionRuntimeReplacementFailure: Error, Equatable, Sendable {
    case ownerUnavailable
    case transitionUnavailable
}

struct ProductionResetFailurePresentation: Equatable, Sendable {
    let runtimeFailure: ProductionCompositionFailure
    let report: ResetReport

    var failedStageLocalizationKeys: [String] {
        report.failedStages
            .sorted { $0.rawValue < $1.rawValue }
            .map { "privacyHistory.reset.stage.\($0.rawValue)" }
    }
}

@MainActor
final class ApplicationRuntimeTransitionGate {
    private var generation: UInt = 0
    private var terminating = false
    private var replacementInFlight = false
    private var replacementWaiters: [CheckedContinuation<Void, Never>] = []

    func startupToken() -> UInt? {
        terminating ? nil : generation
    }

    func beginReplacement() -> UInt? {
        guard !terminating, !replacementInFlight else { return nil }
        replacementInFlight = true
        generation &+= 1
        return generation
    }

    func withReplacementTransaction<T>(
        _ operation: @MainActor (UInt) async throws -> T
    ) async throws -> T {
        guard let token = beginReplacement() else {
            throw ProductionRuntimeReplacementFailure.transitionUnavailable
        }
        defer { finishReplacement() }
        return try await operation(token)
    }

    func beginTermination() {
        guard !terminating else { return }
        terminating = true
        generation &+= 1
    }

    func isCurrent(_ token: UInt) -> Bool {
        !terminating && token == generation
    }

    func finishReplacement() {
        guard replacementInFlight else { return }
        replacementInFlight = false
        let waiters = replacementWaiters
        replacementWaiters = []
        waiters.forEach { $0.resume() }
    }

    func waitForReplacementToFinish() async {
        guard replacementInFlight else { return }
        await withCheckedContinuation { continuation in
            replacementWaiters.append(continuation)
        }
    }
}
