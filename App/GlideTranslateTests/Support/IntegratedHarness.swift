import Foundation
import ModelProviders
import PrivacyStorage
@testable import SelectionCapture
@testable import SharedSupport
import TranslationCore

@testable import GlideTranslate

enum IntegratedFailureCase: CaseIterable, Sendable {
    case accessibilityDenied
    case automaticCapturePaused
    case applicationNotAllowed
    case offDeviceApplicationNotAllowed
    case unsupportedApplication
    case noValidSelection
    case unsafeClipboardState
    case ollamaUnavailable
    case modelUnavailable
    case invalidProviderConfiguration
    case invalidCredential
    case destinationChanged
    case connectionTimeout
    case firstTokenTimeout
    case streamIdleTimeout
    case providerProtocolFailure
    case userCancellation
    case historyDisabled
    case applicationExcluded
    case historyUnrecoverable
}

extension IntegratedFailureCase {
    var expectedNextAction: SafeNextAction {
        if isSilentAutomaticCaptureFailure { return .none }
        return switch self {
        case .accessibilityDenied: .openAccessibilitySettingsOrUseManualInput
        case .automaticCapturePaused: .resumeAutomaticOrUseShortcut
        case .applicationNotAllowed: .enableApplicationOrUseShortcut
        case .offDeviceApplicationNotAllowed: .authorizeApplicationOrUseExplicitAction
        case .unsupportedApplication, .noValidSelection: .openManualInput
        case .unsafeClipboardState: .useManualInput
        case .ollamaUnavailable: .showLocalRuntimeGuidance
        case .modelUnavailable: .chooseOrInstallModelManually
        case .invalidProviderConfiguration: .openModelSettings
        case .invalidCredential: .replaceCredential
        case .destinationChanged: .reconfirmDestination
        case .connectionTimeout, .firstTokenTimeout, .streamIdleTimeout:
            .retryOrAdjustTimeout
        case .providerProtocolFailure: .retryOrReviewProvider
        case .userCancellation: .none
        case .historyDisabled: .explainHistoryDisabled
        case .applicationExcluded: .explainApplicationExcluded
        case .historyUnrecoverable: .deleteAndRestartHistory
        }
    }

    var isSilentAutomaticCaptureFailure: Bool {
        switch self {
        case .accessibilityDenied,
             .automaticCapturePaused,
             .applicationNotAllowed,
             .offDeviceApplicationNotAllowed,
             .noValidSelection:
            true
        default:
            false
        }
    }

    var rejectsBeforeSystemRead: Bool {
        switch self {
        case .automaticCapturePaused,
             .applicationNotAllowed,
             .offDeviceApplicationNotAllowed,
             .unsupportedApplication,
             .userCancellation:
            true
        default:
            false
        }
    }

    var rejectsBeforeSend: Bool {
        switch self {
        case .accessibilityDenied,
             .automaticCapturePaused,
             .applicationNotAllowed,
             .offDeviceApplicationNotAllowed,
             .unsupportedApplication,
             .noValidSelection,
             .unsafeClipboardState,
             .invalidProviderConfiguration,
             .destinationChanged,
             .userCancellation:
            true
        default:
            false
        }
    }

    var expectedHistoryWrites: Int { 0 }

    var expectedProviderCalls: Int { rejectsBeforeSend ? 0 : 1 }

    var expectedCredentialReads: Int { self == .invalidCredential ? 1 : 0 }
}

struct IntegratedLogAudit: Sendable {
    let records: [SafeLogRecord]

    var areRuntimeMarkerFree: Bool {
        let marker = ["runtime", "sensitive", "marker"].joined(separator: "-")
        return records.allSatisfy { !String(reflecting: $0).contains(marker) }
    }
}

struct IntegratedDiagnosticPreviewAudit: Sendable {
    let data: Data?

    var wasBuilt: Bool { data?.isEmpty == false }

    var isRuntimeMarkerFree: Bool {
        let marker = ["runtime", "sensitive", "marker"].joined(separator: "-")
        guard let data else { return false }
        return !data.contains(Data(marker.utf8))
    }
}

struct IntegratedSafePresentation: Equatable, Sendable {
    let nextAction: SafeNextAction
    let localizationKey: String
}

enum IntegratedSafeFailureMapping {
    static func presentation(
        for failure: SelectionAuthorizationFailure
    ) -> IntegratedSafePresentation {
        let presentation = failure.safeNextActionPresentation
        return .init(
            nextAction: presentation.action,
            localizationKey: presentation.nextActionKey
        )
    }

    static func presentation(
        for failure: SanitizedFailure
    ) -> IntegratedSafePresentation {
        let presentation = failure.safeNextActionPresentation
        return .init(
            nextAction: presentation.action,
            localizationKey: presentation.nextActionKey
        )
    }

}

private final class IntegratedEventSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func fire() { continuation.yield(()) }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private func integratedCompletesWithin(
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await operation()
            return true
        }
        group.addTask {
            try? await ContinuousClock().sleep(for: .seconds(2))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

@MainActor
final class IntegratedHarness {
    let failure: IntegratedFailureCase
    private(set) var presentedNextAction: SafeNextAction?
    private(set) var alternateProviderCalls = 0
    private(set) var axReads = 0
    private(set) var pasteboardReads = 0
    private(set) var providerCalls = 0
    private(set) var credentialReads = 0
    private(set) var historyWrites = 0
    private(set) var feedbackPresentationCount = 0
    private(set) var outcomeObserved = false
    private(set) var logs = IntegratedLogAudit(records: [])
    private(set) var diagnosticPreview = IntegratedDiagnosticPreviewAudit(data: nil)

    init(failure: IntegratedFailureCase) {
        self.failure = failure
    }

    func performTrigger() async {
        let application = ApplicationIdentity(
            bundleIdentifier: "invalid.example.integrated",
            displayName: "Integrated Fixture"
        )
        let context = ForegroundApplicationContext(
            application: application,
            processIdentifier: 42,
            activationSequence: 1
        )
        let providerID = ProviderConfigurationID()
        let presetID = PresetID(rawValue: "accurate-translation")
        let providerClass: DestinationPrivacyClass =
            failure == .offDeviceApplicationNotAllowed ? .cloud : .localOnDevice
        let authorityFixture = CoordinatorFixture(
            providerID: providerID,
            presetID: presetID,
            providerClass: providerClass
        )
        let snapshot = authorityFixture.providerSnapshot
        let validatedPreset = authorityFixture.validatedPreset

        var foregroundResult: Result<
            ForegroundApplicationContext,
            SelectionAuthorizationFailure
        > = .success(context)
        var systemResult: Result<CapturedSelection, SelectionAuthorizationFailure> =
            .success(CapturedSelection(
                text: Self.runtimeMarker,
                displayRect: nil
            ))
        var clipboardResult: Result<CapturedSelection, SelectionAuthorizationFailure> =
            .failure(.noValidSelection)
        var trigger = CaptureTrigger.shortcut
        var providerMode = IntegratedProviderAdapter.Mode.chunks([
            .connected,
            .content("synthetic-result"),
            .done,
        ])
        var preflightResults: [Result<ProviderDestinationSnapshot, SanitizedFailure>] = [
            .success(snapshot),
        ]
        var historyMode = IntegratedHistoryAdapter.Mode.disabled

        switch failure {
        case .accessibilityDenied:
            trigger = .mouse
            systemResult = .failure(.accessibilityPermissionMissing)
        case .automaticCapturePaused:
            trigger = .mouse
        case .applicationNotAllowed:
            trigger = .mouse
        case .offDeviceApplicationNotAllowed:
            trigger = .mouse
        case .unsupportedApplication:
            foregroundResult = .failure(.unsupportedApplication)
        case .noValidSelection:
            trigger = .mouse
            systemResult = .success(CapturedSelection(text: "!", displayRect: nil))
        case .unsafeClipboardState:
            systemResult = .failure(.noValidSelection)
            clipboardResult = .failure(.unsafeFallbackState)
        case .ollamaUnavailable:
            providerMode = .failure(.ollamaUnavailable, requiresCredential: false)
        case .modelUnavailable:
            providerMode = .failure(.modelUnavailable, requiresCredential: false)
        case .invalidProviderConfiguration:
            preflightResults = [.failure(.invalidProviderConfiguration)]
        case .invalidCredential:
            providerMode = .failure(.invalidCredential, requiresCredential: true)
        case .destinationChanged:
            preflightResults = [
                .success(snapshot),
                .failure(.destinationReconfirmationRequired),
            ]
        case .connectionTimeout, .firstTokenTimeout, .streamIdleTimeout:
            providerMode = .suspended
        case .providerProtocolFailure:
            providerMode = .chunks([.connected])
        case .userCancellation:
            foregroundResult = .failure(.cancelled)
        case .historyDisabled:
            historyMode = .disabled
        case .applicationExcluded:
            historyMode = .excludedApplication
        case .historyUnrecoverable:
            historyMode = .unrecoverable
        }

        let foreground = IntegratedForegroundAdapter(result: foregroundResult)
        let system = IntegratedAXAdapter(result: systemResult)
        let clipboard = IntegratedPasteboardAdapter(result: clipboardResult)
        let snapshotReader = IntegratedSnapshotAdapter(snapshot: snapshot)
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: foreground,
            systemReader: system,
            clipboardReader: clipboard,
            snapshotReader: snapshotReader,
            selectionFilter: SelectionFilter(limit: 2_000),
            duplicateChecker: DuplicateSuppressor()
        )
        let clock = IntegratedManualClock()
        let pipeline = SystemSelectionPipeline(
            foregroundReader: foreground,
            gate: gate,
            debouncer: SelectionDebouncer(delay: .zero, clock: clock)
        )
        let systemProbe = IntegratedSystemProcessorProbe(base: pipeline)
        let preflight = IntegratedPreflightAdapter(results: preflightResults)
        let vault = IntegratedVaultAdapter()
        let provider = IntegratedProviderAdapter(
            expectedDestination: snapshot,
            mode: providerMode,
            vault: vault
        )
        let engine = TranslationCoreFactory.makeEngine(
            provider: provider,
            preflight: preflight,
            clock: clock
        )
        let history = IntegratedHistoryAdapter(mode: historyMode)
        let panel = IntegratedPanelAdapter()
        let manualInput = CoordinatorManualPresenter()
        let feedback = IntegratedFeedbackAdapter()
        let logEmitter = IntegratedLogEmitter()
        let preferences = CoordinatorPreferencesStore(
            .appFixture(providerID: providerID)
        )
        var preferenceValue = preferences.value
        preferenceValue.selectionDebounceMilliseconds = 0
        preferenceValue.connectionTimeoutSeconds = 1
        preferenceValue.firstTokenTimeoutSeconds = 1
        preferenceValue.streamIdleTimeoutSeconds = 1
        preferenceValue.generalAutomaticApplications =
            failure == .applicationNotAllowed ? [] : [application]
        preferenceValue.automaticCaptureEnabled = failure != .automaticCapturePaused
        preferenceValue.clipboardFallbackEnabled = failure == .unsafeClipboardState
        preferences.value = preferenceValue

        let providerManagement = CoordinatorProviderManagement()
        if failure != .offDeviceApplicationNotAllowed {
            providerManagement.automaticApplicationsValue = [application]
        }
        let presets = CoordinatorPromptPresetStore(preset: validatedPreset)
        let environment = AppEnvironment(
            systemSelectionProcessor: systemProbe,
            authorizationGate: gate,
            translationEngine: engine,
            preferences: preferences,
            providerManagement: providerManagement,
            providerPreflight: preflight,
            providerInspection: CoordinatorProviderInspection(),
            providerConfirmation: CoordinatorProviderConfirmation(),
            promptPresets: presets,
            history: history,
            logger: SafeLogger(emitter: logEmitter)
        )
        let coordinator = AppCoordinator(
            environment: environment,
            panelPresenter: panel,
            manualInputPresenter: manualInput,
            feedbackPresenter: feedback,
            resultCopyWriter: CoordinatorCopyWriter()
        )

        await coordinator.handleSystemTrigger(
            trigger,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: presetID
        )

        var prerequisiteObserved = true
        switch failure {
        case .connectionTimeout:
            prerequisiteObserved = await integratedCompletesWithin {
                await provider.waitUntilGenerated()
            }
            let connectingObserved = await integratedCompletesWithin {
                await panel.wait(for: .connecting)
            }
            prerequisiteObserved = prerequisiteObserved && connectingObserved
            await clock.advance(by: .seconds(1))
        case .firstTokenTimeout:
            prerequisiteObserved = await integratedCompletesWithin {
                await provider.waitUntilGenerated()
            }
            provider.yield(.connected)
            let firstTokenWaitObserved = await integratedCompletesWithin {
                await panel.wait(for: .waitingForFirstToken)
            }
            prerequisiteObserved = prerequisiteObserved && firstTokenWaitObserved
            await clock.advance(by: .seconds(1))
        case .streamIdleTimeout:
            prerequisiteObserved = await integratedCompletesWithin {
                await provider.waitUntilGenerated()
            }
            provider.yield(.connected)
            let firstTokenWaitObserved = await integratedCompletesWithin {
                await panel.wait(for: .waitingForFirstToken)
            }
            prerequisiteObserved = prerequisiteObserved && firstTokenWaitObserved
            provider.yield(.content("synthetic-part"))
            let streamingObserved = await integratedCompletesWithin {
                await panel.wait(for: .streaming)
            }
            prerequisiteObserved = prerequisiteObserved && streamingObserved
            await clock.advance(by: .seconds(1))
        default:
            break
        }

        let integratedOutcomeObserved = await waitForIntegratedOutcome(
            systemProbe: systemProbe,
            manualInput: manualInput,
            feedback: feedback,
            history: history
        )
        outcomeObserved = prerequisiteObserved && integratedOutcomeObserved

        axReads = system.readCount
        pasteboardReads = clipboard.readCount
        providerCalls = provider.generateCount
        credentialReads = vault.credentialReadCount
        historyWrites = history.successfulWriteCount
        alternateProviderCalls = provider.alternateGenerateCount
        feedbackPresentationCount = feedback.presentations.count
        let records = logEmitter.recordsSnapshot
        logs = IntegratedLogAudit(records: records)
        diagnosticPreview = IntegratedDiagnosticPreviewAudit(
            data: Self.diagnosticPreview(from: records)
        )

        if let presentation = feedback.presentations.last {
            presentedNextAction = presentation.action
        } else if manualInput.openCount > 0 {
            presentedNextAction = .useManualInput
        } else {
            presentedNextAction = SafeNextAction.none
        }
    }

    private func waitForIntegratedOutcome(
        systemProbe: IntegratedSystemProcessorProbe,
        manualInput: CoordinatorManualPresenter,
        feedback: IntegratedFeedbackAdapter,
        history: IntegratedHistoryAdapter
    ) async -> Bool {
        switch failure {
        case .historyDisabled, .applicationExcluded, .historyUnrecoverable:
            let recorded = await integratedCompletesWithin {
                await history.waitUntilRecorded()
            }
            guard recorded else { return false }
            return await integratedCompletesWithin {
                await feedback.waitUntilPresented()
            }
        case .userCancellation:
            guard let outcome = await systemProbe.capturedOutcome,
                  case .rejected(.cancelled) = outcome else { return false }
            return feedback.presentations.isEmpty
        case _ where failure.isSilentAutomaticCaptureFailure:
            guard let outcome = await systemProbe.capturedOutcome,
                  case .rejected = outcome else { return false }
            return feedback.presentations.isEmpty
        case .unsafeClipboardState:
            guard let outcome = await systemProbe.capturedOutcome,
                  case .manualInputRequired = outcome else { return false }
            return manualInput.openCount == 1 && feedback.presentations.isEmpty
        default:
            return await integratedCompletesWithin {
                await feedback.waitUntilPresented()
            }
        }
    }

    private static func diagnosticPreview(from records: [SafeLogRecord]) -> Data? {
        var counts: [OutcomeCategory: Int] = [:]
        var health: Set<ComponentHealthCategory> = []
        for record in records {
            switch record {
            case .captureTrigger, .shortcutReceived:
                break
            case let .capture(outcome):
                counts[.captureRejected, default: 0] += outcome == .succeeded ? 0 : 1
                health.insert(outcome == .succeeded ? .captureOperational : .permissionLimited)
            case .captureFailure:
                break
            case .selectionAX:
                break
            case .providerHealth, .providerDiagnostic:
                health.insert(.providerOperational)
            case let .translation(failure, _):
                counts[failure == nil ? .translationSucceeded : .translationFailed, default: 0] += 1
                health.insert(failure == nil ? .providerOperational : .providerUnavailable)
            case let .history(outcome):
                let failed = outcome == .unrecoverable
                counts[failed ? .historyFailed : .historyStored, default: 0] += 1
                health.insert(failed ? .storageUnrecoverable : .storageOperational)
            case let .permission(permission):
                health.insert(permission == .granted ? .captureOperational : .permissionLimited)
            }
        }
        let builder = try? DiagnosticReportBuilder(
            appVersion: "1.0.0",
            osMajorVersion: 26,
            architecture: .current,
            accessibilityPermission: .denied,
            defaultProviderClass: .localOnDevice,
            componentHealth: Array(health),
            recentOutcomeCounts: counts
        )
        return try? builder?.encodedPreview()
    }

    private static var runtimeMarker: String {
        ["runtime", "sensitive", "marker"].joined(separator: "-")
    }
}

private final class IntegratedForegroundAdapter:
    ForegroundApplicationReading,
    @unchecked Sendable {
    private let result: Result<ForegroundApplicationContext, SelectionAuthorizationFailure>

    init(result: Result<ForegroundApplicationContext, SelectionAuthorizationFailure>) {
        self.result = result
    }

    func current() async
        -> Result<ForegroundApplicationContext, SelectionAuthorizationFailure> {
        result
    }
}

private final class IntegratedAXAdapter: SystemSelectionReading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<CapturedSelection, SelectionAuthorizationFailure>
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }

    init(result: Result<CapturedSelection, SelectionAuthorizationFailure>) {
        self.result = result
    }

    func readSelection(
        from context: ForegroundApplicationContext
    ) async -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        lock.withLock { reads += 1 }
        return result
    }
}

private final class IntegratedPasteboardAdapter:
    ShortcutClipboardReading,
    @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<CapturedSelection, SelectionAuthorizationFailure>
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    var lastFailure: SelectionAuthorizationFailure? {
        if case let .failure(failure) = result { return failure }
        return nil
    }

    init(result: Result<CapturedSelection, SelectionAuthorizationFailure>) {
        self.result = result
    }

    func readShortcutSelection() async
        -> Result<CapturedSelection, SelectionAuthorizationFailure> {
        lock.withLock { reads += 1 }
        return result
    }
}

private final class IntegratedSnapshotAdapter:
    ProviderSnapshotReading,
    @unchecked Sendable {
    private let snapshot: ProviderDestinationSnapshot
    init(snapshot: ProviderDestinationSnapshot) { self.snapshot = snapshot }
    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        .success(snapshot)
    }
}

private actor IntegratedSystemProcessorProbe: SystemSelectionProcessing {
    private let base: any SystemSelectionProcessing
    private(set) var capturedOutcome: SelectionAuthorizationOutcome?

    init(base: any SystemSelectionProcessing) { self.base = base }

    func process(
        trigger: CaptureTrigger,
        options: TranslationOptionsSnapshot,
        policy: CapturePolicySnapshot,
        provider: ProviderDestinationSnapshot
    ) async -> SelectionAuthorizationOutcome {
        let outcome = await base.process(
            trigger: trigger,
            options: options,
            policy: policy,
            provider: provider
        )
        capturedOutcome = outcome
        return outcome
    }
}

private final class IntegratedPreflightAdapter: ProviderPreflight, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ProviderDestinationSnapshot, SanitizedFailure>]

    init(results: [Result<ProviderDestinationSnapshot, SanitizedFailure>]) {
        self.results = results
    }

    func resolveDestination(
        for configurationID: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        lock.withLock {
            results.count > 1 ? results.removeFirst() : results[0]
        }
    }

    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        await resolveDestination(for: id)
    }
}

private final class IntegratedVaultAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var credentialReads = 0
    var credentialReadCount: Int { lock.withLock { credentialReads } }

    func readCredential(for destination: ProviderDestinationSnapshot) {
        lock.withLock { credentialReads += 1 }
    }
}

private final class IntegratedProviderAdapter: ProviderService, @unchecked Sendable {
    enum Mode: Sendable {
        case chunks([TranslationChunk])
        case failure(SanitizedFailure, requiresCredential: Bool)
        case suspended
    }

    private let lock = NSLock()
    private let expectedDestination: ProviderDestinationSnapshot
    private let mode: Mode
    private let vault: IntegratedVaultAdapter
    private let generatedSignal = IntegratedEventSignal()
    private var continuations: [AsyncThrowingStream<TranslationChunk, Error>.Continuation] = []
    private var primaryGenerates = 0
    private var alternateGenerates = 0
    var generateCount: Int { lock.withLock { primaryGenerates + alternateGenerates } }
    var alternateGenerateCount: Int { lock.withLock { alternateGenerates } }

    init(
        expectedDestination: ProviderDestinationSnapshot,
        mode: Mode,
        vault: IntegratedVaultAdapter
    ) {
        self.expectedDestination = expectedDestination
        self.mode = mode
        self.vault = vault
    }

    func generate(
        _ request: TranslationRequest,
        authorizedDestination: ProviderDestinationSnapshot
    ) async -> AsyncThrowingStream<TranslationChunk, Error> {
        let pair = AsyncThrowingStream<TranslationChunk, Error>.makeStream()
        let requiresCredential: Bool = if case let .failure(_, required) = mode {
            required
        } else {
            false
        }
        lock.withLock {
            if authorizedDestination == expectedDestination {
                primaryGenerates += 1
            } else {
                alternateGenerates += 1
            }
            continuations.append(pair.continuation)
        }
        if requiresCredential { vault.readCredential(for: authorizedDestination) }
        generatedSignal.fire()
        switch mode {
        case let .chunks(chunks):
            chunks.forEach { pair.continuation.yield($0) }
            pair.continuation.finish()
        case let .failure(failure, _):
            pair.continuation.finish(throwing: failure)
        case .suspended:
            break
        }
        return pair.stream
    }

    func waitUntilGenerated() async {
        if generateCount > 0 { return }
        await generatedSignal.wait()
    }

    func yield(_ chunk: TranslationChunk) {
        guard let continuation = lock.withLock({ continuations.last }) else {
            return
        }
        continuation.yield(chunk)
    }
}

private final class IntegratedManualClock: AppClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var elapsed = Duration.zero
    private var waiters: [UUID: Waiter] = [:]
    var now: ContinuousClock.Instant { lock.withLock { base.advanced(by: elapsed) } }
    var date: Date { Date(timeIntervalSince1970: 0) }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let deadline = now.advanced(by: duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock {
                    if base.advanced(by: elapsed) >= deadline { return true }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return false
                }
                if immediate { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) async {
        let due: [Waiter] = lock.withLock {
            elapsed += duration
            let current = base.advanced(by: elapsed)
            let ids = waiters.compactMap { key, waiter in
                waiter.deadline <= current ? key : nil
            }
            return ids.compactMap { waiters.removeValue(forKey: $0) }
        }
        due.forEach { $0.continuation.resume() }
        await Task.yield()
    }
}

private final class IntegratedHistoryAdapter: TranslationHistory, @unchecked Sendable {
    enum Mode: Sendable {
        case disabled
        case excludedApplication
        case unrecoverable
    }

    private let lock = NSLock()
    private let mode: Mode
    private let recordedSignal = IntegratedEventSignal()
    private var writes = 0
    private var outcome: HistoryWriteOutcome?
    private var failure: SanitizedFailure?
    var successfulWriteCount: Int { lock.withLock { writes } }
    var observedOutcome: HistoryWriteOutcome? { lock.withLock { outcome } }
    var observedFailure: SanitizedFailure? { lock.withLock { failure } }

    init(mode: Mode) { self.mode = mode }

    func recordCompleted(
        _ completion: CompletedTranslation,
        sourceApplication: ApplicationIdentity?
    ) async throws -> HistoryWriteOutcome {
        defer { recordedSignal.fire() }
        switch mode {
        case .disabled:
            let result = HistoryWriteOutcome.skipped(.disabled)
            lock.withLock { outcome = result }
            return result
        case .excludedApplication:
            let result = HistoryWriteOutcome.skipped(.excludedApplication)
            lock.withLock { outcome = result }
            return result
        case .unrecoverable:
            let result = SanitizedFailure.historyUnrecoverable
            lock.withLock { failure = result }
            throw result
        }
    }

    func waitUntilRecorded() async {
        if observedOutcome != nil || observedFailure != nil { return }
        await recordedSignal.wait()
    }

    func search(_ query: HistoryQuery) async throws -> [HistorySummary] { [] }
    func performMaintenance() async throws {}
    func delete(_ id: TranslationRecordID) async throws {}
    func clearAll() async throws {}
}

@MainActor
private final class IntegratedPanelAdapter: ResultPanelPresenting {
    private(set) var phase: TranslationPresentationPhase?
    private let phaseStream: AsyncStream<TranslationPresentationPhase>
    private let phaseContinuation: AsyncStream<TranslationPresentationPhase>.Continuation

    init() {
        let pair = AsyncStream<TranslationPresentationPhase>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        phaseStream = pair.stream
        phaseContinuation = pair.continuation
    }

    func showTemporary(_ presentation: TranslationPresentation, actions: ResultPanelActions) {
        phase = presentation.phase
        phaseContinuation.yield(presentation.phase)
    }
    func updateTemporary(_ presentation: TranslationPresentation) {
        phase = presentation.phase
        phaseContinuation.yield(presentation.phase)
    }
    @discardableResult
    func dismissTemporary() -> Bool {
        let hadTemporary = phase != nil
        phase = nil
        return hadTemporary
    }
    func pinTemporary() {}
    func dismissPinned() {}
    func wait(for expected: TranslationPresentationPhase) async {
        if phase == expected { return }
        for await observed in phaseStream where observed == expected { return }
    }
}

@MainActor
private final class IntegratedFeedbackAdapter: CoordinatorFeedbackPresenting {
    private let presentedSignal = IntegratedEventSignal()
    private(set) var presentations: [SafeNextActionPresentation] = []
    func presentSafeNextAction(_ presentation: SafeNextActionPresentation) {
        presentations.append(presentation)
        presentedSignal.fire()
    }
    func waitUntilPresented() async {
        if !presentations.isEmpty { return }
        await presentedSignal.wait()
    }
}

private final class IntegratedLogEmitter: SafeLogEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SafeLogRecord] = []
    var recordsSnapshot: [SafeLogRecord] { lock.withLock { records } }
    func emit(_ record: SafeLogRecord) { lock.withLock { records.append(record) } }
}
