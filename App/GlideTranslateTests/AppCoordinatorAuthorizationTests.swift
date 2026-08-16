import CoreGraphics
import Foundation
import ModelProviders
import PrivacyStorage
@testable import SelectionCapture
@testable import SharedSupport
import TranslationCore
import XCTest

@testable import GlideTranslate

@MainActor
final class AppCoordinatorAuthorizationTests: XCTestCase {
    private enum CoordinatorRow: Equatable {
        case rejected(CaptureTrigger, expectedReads: Int, providerCalls: Int, panelShows: Int)
        case shortcutNoSelection(manualWindowOpens: Int, providerCalls: Int)
        case authorizedAutomatic(providerCalls: Int, temporaryPanels: Int)
        case authorizedShortcut(providerCalls: Int, temporaryPanels: Int)
        case manualAuthorized(providerCalls: Int, systemReads: Int)
        case manualRejected(providerCalls: Int, systemReads: Int)
        case providerChangedAfterRead(providerCalls: Int)
    }

    private let rows: [CoordinatorRow] = [
        .rejected(.mouse, expectedReads: 0, providerCalls: 0, panelShows: 0),
        .rejected(.keyboardSelection, expectedReads: 0, providerCalls: 0, panelShows: 0),
        .shortcutNoSelection(manualWindowOpens: 1, providerCalls: 0),
        .authorizedAutomatic(providerCalls: 1, temporaryPanels: 1),
        .authorizedShortcut(providerCalls: 1, temporaryPanels: 1),
        .manualAuthorized(providerCalls: 1, systemReads: 0),
        .manualRejected(providerCalls: 0, systemReads: 0),
        .providerChangedAfterRead(providerCalls: 0),
    ]

    func testAuthorizationRowsDriveExpectedEffects() async {
        for row in rows {
            switch row {
            case let .rejected(trigger, expectedReads, providerCalls, panelShows):
                let fixture = CoordinatorFixture(
                    systemOutcome: .rejected(.applicationNotAllowed)
                )
                fixture.systemProcessor.simulatedSystemReadsPerCall = 0
                await fixture.coordinator.handleSystemTrigger(
                    trigger,
                    sourceLanguage: .automatic,
                    targetLanguage: .identified("en"),
                    presetID: fixture.presetID
                )
                XCTAssertEqual(fixture.systemProcessor.systemReads, expectedReads)
                XCTAssertEqual(fixture.engine.translateCalls.count, providerCalls)
                XCTAssertEqual(fixture.panel.temporaryShows, panelShows)

            case let .shortcutNoSelection(manualWindowOpens, providerCalls):
                let fixture = CoordinatorFixture(systemOutcome: .manualInputRequired)
                await fixture.coordinator.handleSystemTrigger(
                    .shortcut,
                    sourceLanguage: .automatic,
                    targetLanguage: .identified("en"),
                    presetID: fixture.presetID
                )
                XCTAssertEqual(fixture.manual.openCount, manualWindowOpens)
                XCTAssertEqual(fixture.engine.translateCalls.count, providerCalls)

            case let .authorizedAutomatic(providerCalls, temporaryPanels):
                let fixture = CoordinatorFixture()
                fixture.systemProcessor.outcome = .authorized(
                    fixture.intent(), fixture.context()
                )
                fixture.engine.updates = [.preparing]
                await fixture.coordinator.handleSystemTrigger(
                    .mouse,
                    sourceLanguage: .automatic,
                    targetLanguage: .identified("en"),
                    presetID: fixture.presetID
                )
                await fixture.waitForEngineCalls(providerCalls)
                XCTAssertEqual(fixture.engine.translateCalls.count, providerCalls)
                XCTAssertEqual(fixture.panel.temporaryShows, temporaryPanels)

            case let .authorizedShortcut(providerCalls, temporaryPanels):
                let fixture = CoordinatorFixture()
                fixture.systemProcessor.outcome = .authorized(
                    fixture.intent(), fixture.context()
                )
                fixture.engine.updates = [.preparing]
                await fixture.coordinator.handleSystemTrigger(
                    .shortcut,
                    sourceLanguage: .automatic,
                    targetLanguage: .identified("en"),
                    presetID: fixture.presetID
                )
                await fixture.waitForEngineCalls(providerCalls)
                XCTAssertEqual(fixture.engine.translateCalls.count, providerCalls)
                XCTAssertEqual(fixture.panel.temporaryShows, temporaryPanels)

            case let .manualAuthorized(providerCalls, systemReads):
                let fixture = CoordinatorFixture()
                fixture.gate.manualOutcome = .authorized(
                    fixture.intent(), fixture.context()
                )
                fixture.engine.updates = [.preparing]
                await fixture.coordinator.submitManual(fixture.manualDraft())
                await fixture.waitForEngineCalls(providerCalls)
                XCTAssertEqual(fixture.systemProcessor.systemReads, systemReads)
                XCTAssertEqual(fixture.engine.translateCalls.count, providerCalls)
                XCTAssertEqual(fixture.gate.manualSubmissions.count, 1)

            case let .manualRejected(providerCalls, systemReads):
                let fixture = CoordinatorFixture()
                fixture.gate.manualOutcome = .rejected(.applicationNotAllowed)
                await fixture.coordinator.submitManual(fixture.manualDraft())
                XCTAssertEqual(fixture.systemProcessor.systemReads, systemReads)
                XCTAssertEqual(fixture.engine.translateCalls.count, providerCalls)
                XCTAssertEqual(fixture.gate.manualSubmissions.count, 1)

            case let .providerChangedAfterRead(providerCalls):
                let fixture = CoordinatorFixture(
                    systemOutcome: .rejected(.providerChanged)
                )
                fixture.systemProcessor.simulatedSystemReadsPerCall = 1
                await fixture.coordinator.handleSystemTrigger(
                    .shortcut,
                    sourceLanguage: .automatic,
                    targetLanguage: .identified("en"),
                    presetID: fixture.presetID
                )
                XCTAssertEqual(fixture.systemProcessor.systemReads, 1)
                XCTAssertEqual(fixture.engine.translateCalls.count, providerCalls)
                XCTAssertEqual(fixture.panel.temporaryShows, 0)
            }
        }
    }

    func testRejectedAutomaticTriggersNeverReachEngineOrPanel() async {
        for trigger in [CaptureTrigger.mouse, .keyboardSelection] {
            let fixture = CoordinatorFixture(systemOutcome: .rejected(.applicationNotAllowed))
            await fixture.coordinator.handleSystemTrigger(
                trigger,
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID
            )
            XCTAssertEqual(fixture.engine.translateCalls.count, 0)
            XCTAssertEqual(fixture.panel.temporaryShows, 0)
        }
    }

    func testDistinctSelectionFailuresAreNotCollapsedToApplicationNotAllowed() async {
        let rows: [(SelectionAuthorizationFailure, SafeNextAction)] = [
            (.automaticCapturePaused, .resumeAutomaticOrUseShortcut),
            (.offDeviceApplicationNotAllowed, .authorizeApplicationOrUseExplicitAction),
        ]
        for (failure, expectedAction) in rows {
            let fixture = CoordinatorFixture(systemOutcome: .rejected(failure))

            await fixture.coordinator.handleSystemTrigger(
                .mouse,
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID
            )

            XCTAssertEqual(
                fixture.feedback.presentations.map(\.action),
                [expectedAction]
            )
        }
    }

    func testProviderFailurePresentsItsSafeNextAction() async {
        let fixture = CoordinatorFixture()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(), fixture.context()
        )
        fixture.engine.updates = [.failed(.ollamaUnavailable)]

        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        for _ in 0..<100 where fixture.feedback.presentations.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(
            fixture.feedback.presentations.map(\.action),
            [.showLocalRuntimeGuidance]
        )
    }

    func testAutomaticApplicationRejectionPublishesDisabledStateAndLaterSuccessClearsIt() async {
        let fixture = CoordinatorFixture(
            systemOutcome: .rejected(.applicationNotAllowed)
        )
        await fixture.coordinator.handleSystemTrigger(
            .mouse,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        fixture.systemProcessor.outcome = .manualInputRequired
        await fixture.coordinator.handleSystemTrigger(
            .keyboardSelection,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )

        XCTAssertEqual(fixture.foregroundDisabledValues, [true, false])
    }

    func testShortcutNoSelectionOpensManualWithoutEngineCall() async {
        let fixture = CoordinatorFixture(systemOutcome: .manualInputRequired)
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        XCTAssertEqual(fixture.manual.openCount, 1)
        XCTAssertEqual(fixture.engine.translateCalls.count, 0)
        XCTAssertEqual(fixture.providerManagement.automaticApplicationReads, [])
    }

    func testAutomaticOffDeviceIntersectsProviderAllowlistWithGeneralCeiling() async {
        let allowed = ApplicationIdentity(
            bundleIdentifier: "invalid.example.allowed",
            displayName: "Allowed"
        )
        let providerOnly = ApplicationIdentity(
            bundleIdentifier: "invalid.example.provider-only",
            displayName: "Provider Only"
        )
        let fixture = CoordinatorFixture(
            providerClass: .cloud,
            systemOutcome: .rejected(.noValidSelection)
        )
        fixture.preferences.value.generalAutomaticApplications = [allowed]
        fixture.providerManagement.automaticApplicationsValue = [allowed, providerOnly]

        await fixture.coordinator.handleSystemTrigger(
            .mouse,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )

        XCTAssertEqual(fixture.providerManagement.automaticApplicationReads, [fixture.providerID])
        XCTAssertEqual(fixture.systemProcessor.policies.last?.offDeviceAllowlist, [allowed])
    }

    func testShortcutNeverLoadsProviderAutomaticApplications() async {
        let fixture = CoordinatorFixture(
            providerClass: .cloud,
            systemOutcome: .rejected(.noValidSelection)
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        XCTAssertEqual(fixture.providerManagement.automaticApplicationReads, [])
        XCTAssertEqual(fixture.systemProcessor.policies.last?.offDeviceAllowlist, [])
    }

    func testAuthorizedAutomaticAndShortcutStartExactlyOneTranslation() async {
        for trigger in [CaptureTrigger.mouse, .shortcut] {
            let fixture = CoordinatorFixture()
            fixture.systemProcessor.outcome = .authorized(
                fixture.intent(),
                fixture.context()
            )
            fixture.engine.updates = [.preparing]
            await fixture.coordinator.handleSystemTrigger(
                trigger,
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID
            )
            await fixture.waitForEngineCalls(1)
            XCTAssertEqual(fixture.engine.translateCalls.count, 1)
            XCTAssertEqual(fixture.panel.temporaryShows, 1)
        }
    }

    func testAuthorizedCustomPresetCarriesUserOwnedNameToPresentation() async {
        let customID = PresetID(rawValue: "custom-synthetic")
        let fixture = CoordinatorFixture(presetID: customID)
        fixture.presets.customPresetsValue = [
            CustomPreset(
                id: customID,
                name: "My Private Preset",
                explanation: "Synthetic explanation",
                template: "Translate {text}",
                targetLanguage: .automatic,
                action: .translate
            ),
        ]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(), fixture.context()
        )
        fixture.engine.updates = [.preparing]

        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: customID
        )
        await fixture.waitForEngineCalls(1)

        XCTAssertEqual(fixture.panel.updates.first?.presetDisplayName, "My Private Preset")
    }

    func testManualSubmissionUsesExactProviderAndNeverSystemProcessor() async {
        let explicitProvider = ProviderConfigurationID()
        let fixture = CoordinatorFixture(providerID: explicitProvider)
        fixture.gate.manualOutcome = .authorized(fixture.intent(), fixture.context())
        fixture.engine.updates = [.preparing]

        await fixture.coordinator.submitManual(
            ManualTranslationDraft(
                text: "synthetic manual text",
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID,
                providerID: explicitProvider
            )
        )
        await fixture.waitForEngineCalls(1)

        XCTAssertEqual(fixture.gate.manualSubmissions.count, 1)
        XCTAssertEqual(fixture.gate.manualSubmissions.first?.providerConfigurationID, explicitProvider)
        XCTAssertTrue(fixture.systemProcessor.calls.isEmpty)
        XCTAssertEqual(fixture.engine.translateCalls.count, 1)
    }

    func testRejectedManualAndProviderDriftStopBeforeEngine() async {
        let fixture = CoordinatorFixture()
        fixture.gate.manualOutcome = .rejected(.providerChanged)
        await fixture.coordinator.submitManual(
            ManualTranslationDraft(
                text: "synthetic manual text",
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID,
                providerID: nil
            )
        )
        XCTAssertEqual(fixture.engine.translateCalls.count, 0)

        fixture.preflight.result = .failure(.destinationReconfirmationRequired)
        fixture.gate.reset()
        await fixture.coordinator.submitManual(
            ManualTranslationDraft(
                text: "synthetic manual text",
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID,
                providerID: nil
            )
        )
        XCTAssertEqual(fixture.gate.manualSubmissions.count, 0)
        XCTAssertEqual(fixture.engine.translateCalls.count, 0)
    }
}

@MainActor
final class CoordinatorFixture {
    let providerID: ProviderConfigurationID
    let presetID: PresetID
    let providerSnapshot: ProviderDestinationSnapshot
    let validatedPreset: ValidatedPromptPreset
    let preferences: CoordinatorPreferencesStore
    let providerManagement = CoordinatorProviderManagement()
    let preflight: CoordinatorPreflight
    let systemProcessor: CoordinatorSystemProcessor
    let gate = CoordinatorAuthorizationGate()
    let engine = CoordinatorTranslationEngine()
    let presets: CoordinatorPromptPresetStore
    let history = CoordinatorHistory()
    let panel = CoordinatorPanelPresenter()
    let manual = CoordinatorManualPresenter()
    let feedback = CoordinatorFeedbackPresenter()
    let copyWriter = CoordinatorCopyWriter()
    let foregroundRecorder = CoordinatorForegroundRecorder()
    var foregroundDisabledValues: [Bool] { foregroundRecorder.values }
    let coordinator: AppCoordinator

    init(
        providerID: ProviderConfigurationID = ProviderConfigurationID(),
        presetID: PresetID = PresetID(rawValue: "accurate-translation"),
        providerClass: DestinationPrivacyClass = .localOnDevice,
        systemOutcome: SelectionAuthorizationOutcome = .rejected(.noValidSelection),
        panelPresenter: (any ResultPanelPresenting)? = nil
    ) {
        self.providerID = providerID
        self.presetID = presetID
        providerSnapshot = .appFixture(
            configurationID: providerID,
            privacyClass: providerClass
        )
        validatedPreset = .mintAfterPromptValidation(
            id: presetID,
            action: .translate,
            template: "Translate {text}"
        )
        preferences = CoordinatorPreferencesStore(.appFixture(providerID: providerID))
        preflight = CoordinatorPreflight(result: .success(providerSnapshot))
        systemProcessor = CoordinatorSystemProcessor(outcome: systemOutcome)
        presets = CoordinatorPromptPresetStore(preset: validatedPreset)
        let environment = AppEnvironment(
            systemSelectionProcessor: systemProcessor,
            authorizationGate: gate,
            translationEngine: engine,
            preferences: preferences,
            providerManagement: providerManagement,
            providerPreflight: preflight,
            providerInspection: CoordinatorProviderInspection(),
            providerConfirmation: CoordinatorProviderConfirmation(),
            promptPresets: presets,
            history: history,
            logger: SafeLogger(emitter: CoordinatorLogEmitter())
        )
        coordinator = AppCoordinator(
            environment: environment,
            panelPresenter: panelPresenter ?? panel,
            manualInputPresenter: manual,
            feedbackPresenter: feedback,
            resultCopyWriter: copyWriter,
            foregroundApplicationDisabledChanged: { [foregroundRecorder] disabled in
                foregroundRecorder.values.append(disabled)
            }
        )
    }

    func intent(
        requestID: TranslationRequestID = TranslationRequestID(),
        application: ApplicationIdentity? = nil,
        text: String = "synthetic source",
        provider: ProviderDestinationSnapshot? = nil
    ) -> AuthorizedTranslationIntent {
        .mintAfterAuthorization(
            requestID: requestID,
            payload: .init(
                text: text,
                sourceApplication: application,
                options: .init(
                    sourceLanguage: .automatic,
                    targetLanguage: .identified("en"),
                    preset: validatedPreset,
                    timeouts: .init(
                        connection: .seconds(5),
                        firstToken: .seconds(120),
                        streamIdle: .seconds(30)
                    )
                ),
                provider: provider ?? providerSnapshot,
                displayRect: nil
            )
        )
    }

    func context(
        application: ApplicationIdentity? = nil,
        text: String = "synthetic source",
        provider: ProviderDestinationSnapshot? = nil
    ) -> AuthorizedTranslationPresentationContext {
        AuthorizedTranslationPresentationContext(
            payload: intent(
                application: application,
                text: text,
                provider: provider
            ).payload
        )
    }

    func waitForEngineCalls(_ count: Int) async {
        for _ in 0..<100 where engine.translateCalls.count < count { await Task.yield() }
    }

    func waitForRetryCalls(_ count: Int) async {
        for _ in 0..<100 where engine.retryCalls.count < count { await Task.yield() }
    }

    func manualDraft() -> ManualTranslationDraft {
        ManualTranslationDraft(
            text: "synthetic manual text",
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: presetID,
            providerID: nil
        )
    }
}

@MainActor
final class CoordinatorForegroundRecorder {
    var values: [Bool] = []
}

final class CoordinatorPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    var value: PreferencesSnapshot {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    private var storage: PreferencesSnapshot
    private var shouldSuspendNextSnapshot = false
    private var snapshotIsSuspended = false
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    init(_ value: PreferencesSnapshot) { storage = value }
    func snapshot() async throws -> PreferencesSnapshot {
        let shouldSuspend = lock.withLock { () -> Bool in
            guard shouldSuspendNextSnapshot else { return false }
            shouldSuspendNextSnapshot = false
            snapshotIsSuspended = true
            return true
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                lock.withLock { snapshotContinuation = continuation }
            }
        }
        return value
    }
    func update(_ transform: @Sendable (inout PreferencesSnapshot) throws -> Void) async throws {
        try lock.withLock { try transform(&storage) }
    }
    func suspendNextSnapshot() {
        lock.withLock { shouldSuspendNextSnapshot = true }
    }
    func waitUntilSnapshotSuspended() async {
        while !lock.withLock({ snapshotIsSuspended }) { await Task.yield() }
    }
    func resumeSnapshot() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            snapshotIsSuspended = false
            defer { snapshotContinuation = nil }
            return snapshotContinuation
        }
        continuation?.resume()
    }
}

final class CoordinatorProviderManagement: ProviderManagement, @unchecked Sendable {
    private let lock = NSLock()
    var automaticApplicationsValue: Set<ApplicationIdentity> = []
    private(set) var automaticApplicationReads: [ProviderConfigurationID] = []
    func automaticApplications(for id: ProviderConfigurationID) async throws -> Set<ApplicationIdentity> {
        lock.withLock { automaticApplicationReads.append(id) }
        return automaticApplicationsValue
    }
    func descriptors() async throws -> [SanitizedProviderDescriptor] { throw SanitizedFailure.invalidProviderConfiguration }
    func configuration(_ id: ProviderConfigurationID) async throws -> ProviderConfigurationDetails { throw SanitizedFailure.invalidProviderConfiguration }
    func create(_ draft: ProviderConfigurationDraft, credential: consuming SensitiveCredentialInput?) async throws -> SanitizedProviderDescriptor { throw SanitizedFailure.invalidProviderConfiguration }
    func update(_ id: ProviderConfigurationID, draft: ProviderConfigurationDraft, credential: consuming ProviderCredentialChange) async throws -> SanitizedProviderDescriptor { throw SanitizedFailure.invalidProviderConfiguration }
    func ensureDefaultOllamaConfiguration() async throws -> SanitizedProviderDescriptor { throw SanitizedFailure.invalidProviderConfiguration }
    func setAutomaticApplications(_ applications: Set<ApplicationIdentity>, for id: ProviderConfigurationID) async throws {}
    func delete(_ id: ProviderConfigurationID) async throws {}
}

final class CoordinatorPreflight: ProviderPreflight, @unchecked Sendable {
    var result: Result<ProviderDestinationSnapshot, SanitizedFailure>
    var resultsByID: [ProviderConfigurationID: Result<ProviderDestinationSnapshot, SanitizedFailure>] = [:]
    private(set) var reads: [ProviderConfigurationID] = []
    init(result: Result<ProviderDestinationSnapshot, SanitizedFailure>) { self.result = result }
    func resolveDestination(for configurationID: ProviderConfigurationID) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        reads.append(configurationID)
        return resultsByID[configurationID] ?? result
    }
    func currentSnapshot(for id: ProviderConfigurationID) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        await resolveDestination(for: id)
    }
}

final class CoordinatorSystemProcessor: SystemSelectionProcessing, @unchecked Sendable {
    struct Call { let trigger: CaptureTrigger }
    var outcome: SelectionAuthorizationOutcome
    private(set) var calls: [Call] = []
    private(set) var policies: [CapturePolicySnapshot] = []
    var simulatedSystemReadsPerCall = 0
    private(set) var systemReads = 0
    init(outcome: SelectionAuthorizationOutcome) { self.outcome = outcome }
    func process(trigger: CaptureTrigger, options: TranslationOptionsSnapshot, policy: CapturePolicySnapshot, provider: ProviderDestinationSnapshot) async -> SelectionAuthorizationOutcome {
        calls.append(Call(trigger: trigger))
        policies.append(policy)
        systemReads += simulatedSystemReadsPerCall
        return outcome
    }
}

final class CoordinatorAuthorizationGate: SelectionAuthorizationGate, @unchecked Sendable {
    var manualOutcome: SelectionAuthorizationOutcome = .rejected(.noValidSelection)
    private(set) var manualSubmissions: [ManualTranslationSubmission] = []
    private(set) var manualProviders: [ProviderDestinationSnapshot] = []
    func authorizeSystemSelection(trigger: CaptureTrigger, context: ForegroundApplicationContext, options: TranslationOptionsSnapshot, policy: CapturePolicySnapshot, provider: ProviderDestinationSnapshot) async -> SelectionAuthorizationOutcome { .rejected(.unsafeFallbackState) }
    func authorizeManualSubmission(_ submission: ManualTranslationSubmission, policy: SendPolicySnapshot, provider: ProviderDestinationSnapshot) async -> SelectionAuthorizationOutcome {
        manualSubmissions.append(submission)
        manualProviders.append(provider)
        return manualOutcome
    }
    func reset() {
        manualSubmissions = []
        manualProviders = []
    }
}

final class CoordinatorTranslationEngine: TranslationEngine, @unchecked Sendable {
    var updates: [TranslationUpdate] = []
    var retryUpdates: [TranslationUpdate] = []
    var suspendsStreams = false
    var suspendsRetryStreams = false
    private var shouldSuspendNextCancel = false
    private var shouldSuspendNextTranslateAdmission = false
    private var shouldSuspendNextRetryAdmission = false
    private var translateAdmissionIsSuspended = false
    private var translateAdmissionContinuation: CheckedContinuation<Void, Never>?
    private var retryAdmissionIsSuspended = false
    private var retryAdmissionContinuation: CheckedContinuation<Void, Never>?
    private var cancelIsSuspended = false
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private(set) var continuations: [AsyncStream<TranslationUpdate>.Continuation] = []
    private(set) var retryContinuations: [AsyncStream<TranslationUpdate>.Continuation] = []
    private(set) var translateCalls: [TranslationRequestID] = []
    private(set) var retryCalls: [TranslationRequestID] = []
    private(set) var cancelCalls: [TranslationRequestID] = []
    func translate(_ intent: AuthorizedTranslationIntent) async -> AsyncStream<TranslationUpdate> {
        translateCalls.append(intent.requestID)
        if shouldSuspendNextTranslateAdmission {
            shouldSuspendNextTranslateAdmission = false
            translateAdmissionIsSuspended = true
            await withCheckedContinuation { translateAdmissionContinuation = $0 }
        }
        if suspendsStreams {
            return AsyncStream<TranslationUpdate> { continuation in
                continuations.append(continuation)
            }
        }
        let values = updates
        return AsyncStream<TranslationUpdate> { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }
    func retry(_ requestID: TranslationRequestID) async -> AsyncStream<TranslationUpdate> {
        retryCalls.append(requestID)
        if shouldSuspendNextRetryAdmission {
            shouldSuspendNextRetryAdmission = false
            retryAdmissionIsSuspended = true
            await withCheckedContinuation { retryAdmissionContinuation = $0 }
        }
        if suspendsRetryStreams {
            return AsyncStream<TranslationUpdate> { continuation in
                retryContinuations.append(continuation)
            }
        }
        let values = retryUpdates
        return AsyncStream<TranslationUpdate> { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }
    func cancel(_ requestID: TranslationRequestID) async {
        cancelCalls.append(requestID)
        guard shouldSuspendNextCancel else { return }
        shouldSuspendNextCancel = false
        cancelIsSuspended = true
        await withCheckedContinuation { cancelContinuation = $0 }
    }
    func suspendNextCancel() { shouldSuspendNextCancel = true }
    func suspendNextTranslateAdmission() {
        shouldSuspendNextTranslateAdmission = true
    }
    func suspendNextRetryAdmission() {
        shouldSuspendNextRetryAdmission = true
    }
    func waitUntilTranslateAdmissionSuspended() async {
        while !translateAdmissionIsSuspended { await Task.yield() }
    }
    func resumeTranslateAdmission() {
        translateAdmissionIsSuspended = false
        translateAdmissionContinuation?.resume()
        translateAdmissionContinuation = nil
    }
    func waitUntilRetryAdmissionSuspended() async {
        while !retryAdmissionIsSuspended { await Task.yield() }
    }
    func resumeRetryAdmission() {
        retryAdmissionIsSuspended = false
        retryAdmissionContinuation?.resume()
        retryAdmissionContinuation = nil
    }
    func waitUntilCancelSuspended() async {
        while !cancelIsSuspended { await Task.yield() }
    }
    func resumeCancel() {
        cancelIsSuspended = false
        cancelContinuation?.resume()
        cancelContinuation = nil
    }
    func yield(_ update: TranslationUpdate, to streamIndex: Int) {
        continuations[streamIndex].yield(update)
    }
    func yieldRetry(_ update: TranslationUpdate, to streamIndex: Int) {
        retryContinuations[streamIndex].yield(update)
    }
}

final class CoordinatorPromptPresetStore: PromptPresetStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreset: ValidatedPromptPreset
    private var storedError: Error?
    private var storedCustomPresetsValue: [CustomPreset] = []
    private var storedRequested: [PresetID] = []
    private var shouldSuspendNextCustomLoad = false
    private var customLoadIsSuspended = false
    private var customLoadContinuation: CheckedContinuation<Void, Never>?

    var preset: ValidatedPromptPreset {
        get { lock.withLock { storedPreset } }
        set { lock.withLock { storedPreset = newValue } }
    }

    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }

    var customPresetsValue: [CustomPreset] {
        get { lock.withLock { storedCustomPresetsValue } }
        set { lock.withLock { storedCustomPresetsValue = newValue } }
    }

    var requested: [PresetID] { lock.withLock { storedRequested } }

    init(preset: ValidatedPromptPreset) { storedPreset = preset }

    func validatedPreset(_ id: PresetID) async throws -> ValidatedPromptPreset {
        let result = lock.withLock { () -> Result<ValidatedPromptPreset, Error> in
            storedRequested.append(id)
            if let storedError { return .failure(storedError) }
            return .success(storedPreset)
        }
        return try result.get()
    }
    func builtIns() async -> [PromptPresetDescriptor] { [] }
    func customPresets() async throws -> [CustomPreset] {
        let shouldSuspend = lock.withLock { () -> Bool in
            guard shouldSuspendNextCustomLoad else { return false }
            shouldSuspendNextCustomLoad = false
            customLoadIsSuspended = true
            return true
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                lock.withLock { customLoadContinuation = continuation }
            }
        }
        return lock.withLock { storedCustomPresetsValue }
    }
    func suspendNextCustomPresetLoad() {
        lock.withLock { shouldSuspendNextCustomLoad = true }
    }
    func waitUntilCustomPresetLoadSuspended() async {
        while !lock.withLock({ customLoadIsSuspended }) { await Task.yield() }
    }
    func resumeCustomPresetLoad() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            customLoadIsSuspended = false
            defer { customLoadContinuation = nil }
            return customLoadContinuation
        }
        continuation?.resume()
    }
    func duplicateBuiltIn(_ id: PresetID) async throws -> CustomPreset { throw PromptPresetFailure.presetNotFound }
    func validate(_ preset: CustomPreset) async throws -> ValidatedPromptPreset { throw PromptPresetFailure.presetNotFound }
    func preview(_ id: PresetID) async throws -> PromptPresetPreview { throw PromptPresetFailure.presetNotFound }
    func save(_ preset: CustomPreset) async throws {}
    func delete(_ id: PresetID) async throws {}
}

final class CoordinatorHistory: TranslationHistory, @unchecked Sendable {
    struct Call { let completion: CompletedTranslation; let sourceApplication: ApplicationIdentity? }
    var outcome: HistoryWriteOutcome = .stored
    private(set) var calls: [Call] = []
    private var shouldSuspendNextRecord = false
    private var recordIsSuspended = false
    private var recordContinuation: CheckedContinuation<Void, Never>?
    func recordCompleted(_ completion: CompletedTranslation, sourceApplication: ApplicationIdentity?) async throws -> HistoryWriteOutcome {
        calls.append(Call(completion: completion, sourceApplication: sourceApplication))
        if shouldSuspendNextRecord {
            shouldSuspendNextRecord = false
            recordIsSuspended = true
            await withCheckedContinuation { recordContinuation = $0 }
        }
        return outcome
    }
    func suspendNextRecord() { shouldSuspendNextRecord = true }
    func waitUntilRecordSuspended() async {
        while !recordIsSuspended { await Task.yield() }
    }
    func resumeRecord() {
        recordIsSuspended = false
        recordContinuation?.resume()
        recordContinuation = nil
    }
    func search(_ query: HistoryQuery) async throws -> [HistorySummary] { [] }
    func performMaintenance() async throws {}
    func delete(_ id: TranslationRecordID) async throws {}
    func clearAll() async throws {}
}

@MainActor
final class CoordinatorPanelPresenter: ResultPanelPresenting {
    private(set) var temporaryShows = 0
    private(set) var updates: [TranslationPresentation] = []
    private(set) var dismissTemporaryCount = 0
    private(set) var dismissPinnedCount = 0
    private(set) var lastActions: ResultPanelActions?
    private(set) var actionSets: [ResultPanelActions] = []
    func showTemporary(_ presentation: TranslationPresentation, actions: ResultPanelActions) {
        temporaryShows += 1
        updates.append(presentation)
        lastActions = actions
        actionSets.append(actions)
    }
    func updateTemporary(_ presentation: TranslationPresentation) { updates.append(presentation) }
    func dismissTemporary() { dismissTemporaryCount += 1 }
    func pinTemporary() {}
    func dismissPinned() { dismissPinnedCount += 1 }
}

@MainActor
final class CoordinatorManualPresenter: ManualInputPresenting {
    private(set) var openCount = 0
    private(set) var presetPickerCount = 0
    private(set) var presetPickerCancelCount = 0
    private var sessionID: UUID?
    private var selection: (@MainActor @Sendable (PresetID) -> Void)?
    func open() { openCount += 1 }
    func openPresetPicker(
        sessionID: UUID,
        currentPresetID: PresetID,
        onSelect: @escaping @MainActor @Sendable (PresetID) -> Void
    ) {
        presetPickerCount += 1
        self.sessionID = sessionID
        selection = onSelect
    }
    func cancelPresetPicker(sessionID: UUID?) {
        if let sessionID, self.sessionID != sessionID { return }
        presetPickerCancelCount += 1
        selection = nil
        self.sessionID = nil
    }
    func select(_ presetID: PresetID) {
        let callback = selection
        selection = nil
        sessionID = nil
        callback?(presetID)
    }
}

@MainActor
final class CoordinatorFeedbackPresenter: CoordinatorFeedbackPresenting {
    private(set) var presentations: [SafeNextActionPresentation] = []
    var failures: [SanitizedFailure] { presentations.compactMap(\.sanitizedFailure) }
    func presentSafeNextAction(_ presentation: SafeNextActionPresentation) {
        presentations.append(presentation)
    }
}

@MainActor
final class CoordinatorCopyWriter: TranslationResultCopying {
    private(set) var values: [String] = []
    func copy(_ text: String) { values.append(text) }
}

struct CoordinatorProviderInspection: ProviderInspection {
    func discoverModels(for configurationID: ProviderConfigurationID) async throws -> [String] { [] }
    func testConnection(for configurationID: ProviderConfigurationID) async throws {}
}

struct CoordinatorProviderConfirmation: ProviderConfirmationService {
    func prepareConfirmation(for id: ProviderConfigurationID) async throws -> ProviderConfirmationChallenge { throw SanitizedFailure.invalidProviderConfiguration }
    func confirm(_ challenge: ProviderConfirmationChallenge) async throws -> ProviderDestinationSnapshot { throw SanitizedFailure.invalidProviderConfiguration }
}

struct CoordinatorLogEmitter: SafeLogEmitting { func emit(_ record: SafeLogRecord) {} }

extension ProviderDestinationSnapshot {
    static func appFixture(
        configurationID: ProviderConfigurationID,
        privacyClass: DestinationPrivacyClass
    ) -> Self {
        .mintAfterResolution(
            configurationID: configurationID,
            privacyClass: privacyClass,
            configurationRevision: 1,
            confirmationRevision: 1,
            origin: ProviderOrigin(scheme: "https", host: "example.invalid", effectivePort: 443),
            resolutionFingerprint: ["203.0.113.1"],
            protocolKind: .ollamaNative,
            model: "synthetic-model"
        )
    }
}

extension PreferencesSnapshot {
    static func appFixture(providerID: ProviderConfigurationID) -> Self {
        let fixture = CoordinatorPreferencesFixture(defaultProviderID: providerID)
        return try! JSONDecoder().decode(
            Self.self,
            from: JSONEncoder().encode(fixture)
        )
    }
}

private struct CoordinatorPreferencesFixture: Codable {
    var uiLanguage: ApplicationLanguage = .english
    var defaultTargetLanguage: LanguageChoice = .identified("en")
    var onboardingCompleted = true
    var automaticCaptureEnabled = true
    var generalAutomaticApplications: Set<ApplicationIdentity> = []
    var mouseSelectionEnabled = true
    var keyboardSelectionEnabled = true
    var clipboardFallbackEnabled = false
    var historyEnabled = true
    var historyRetentionDays = 30
    var historyMaximumCount = 1_000
    var selectionDebounceMilliseconds = 350
    var selectionCharacterLimit = 2_000
    var connectionTimeoutSeconds = 5
    var firstTokenTimeoutSeconds = 120
    var streamIdleTimeoutSeconds = 30
    var launchAtLogin = false
    var shortcut = ShortcutDescriptor.defaultOptionShiftD
    var defaultPresetID = PresetID(rawValue: "accurate-translation")
    var defaultProviderID: ProviderConfigurationID?
    var historyExcludedApplications: Set<ApplicationIdentity> = []
}
