import ModelProviders
import PrivacyStorage
import SelectionCapture
import SharedSupport
import SwiftUI
import XCTest

@testable import GlideTranslate

@MainActor
final class OnboardingTests: XCTestCase {
    private enum Effect: Hashable {
        case ensureDefaultOllama
        case loopbackOllamaTagsRequest
        case explicitPasteboardWrite
        case registerOptionShiftD
        case showReplacementChoice
        case accessibilityPrompt
        case persistOnboardingComplete
        case updateSelectedModel
        case cloudCall
        case chatBody
        case modelDownload
        case modelDelete
        case automaticCaptureEnable
        case launchAtLoginMutation
        case unrelatedPermissionPrompt
        case telemetry
        case updateCheck
        case periodicTask
    }

    private enum OnboardingRow {
        case launch(expected: [Effect])
        case skipPrivacy(expected: [Effect])
        case detectOllama(expected: [Effect])
        case skipOllama(expected: [Effect])
        case copyInstallGuidance(expected: [Effect])
        case registerDefaultShortcut(expected: [Effect])
        case shortcutConflict(expected: [Effect])
        case viewAccessibilityExplanation(expected: [Effect])
        case skipAccessibility(expected: [Effect])
        case enableSelectionAfterExplanation(expected: [Effect])
        case finishWithoutSelection(expected: [Effect])
    }

    private let rows: [OnboardingRow] = [
        .launch(expected: []),
        .skipPrivacy(expected: []),
        .detectOllama(expected: [.ensureDefaultOllama, .loopbackOllamaTagsRequest]),
        .skipOllama(expected: []),
        .copyInstallGuidance(expected: [.explicitPasteboardWrite]),
        .registerDefaultShortcut(expected: [.registerOptionShiftD]),
        .shortcutConflict(expected: [.registerOptionShiftD, .showReplacementChoice]),
        .viewAccessibilityExplanation(expected: []),
        .skipAccessibility(expected: []),
        .enableSelectionAfterExplanation(expected: [.accessibilityPrompt]),
        .finishWithoutSelection(expected: [.persistOnboardingComplete]),
    ]

    func testEveryOnboardingEffectRequiresItsNamedUserAction() async {
        for row in rows {
            let fixture: Fixture
            let expected: [Effect]
            switch row {
            case let .launch(value):
                fixture = Fixture(step: .privacyModel)
                expected = value
            case let .skipPrivacy(value):
                fixture = Fixture(step: .privacyModel)
                fixture.coordinator.skip()
                expected = value
            case let .detectOllama(value):
                fixture = Fixture(step: .localOllama, models: ["qwen2.5:7b"])
                await fixture.coordinator.detectOllama()
                expected = value
            case let .skipOllama(value):
                fixture = Fixture(step: .localOllama)
                fixture.coordinator.skip()
                expected = value
            case let .copyInstallGuidance(value):
                fixture = Fixture(step: .localOllama)
                fixture.coordinator.copyInstallGuidance()
                expected = value
            case let .registerDefaultShortcut(value):
                fixture = Fixture(step: .shortcut)
                await fixture.coordinator.continueCurrentStep()
                expected = value
            case let .shortcutConflict(value):
                fixture = Fixture(step: .shortcut, shortcutFailure: .conflict)
                await fixture.coordinator.continueCurrentStep()
                expected = value
            case let .viewAccessibilityExplanation(value):
                fixture = Fixture(step: .accessibility)
                fixture.coordinator.noteAccessibilityExplanationRendered()
                expected = value
            case let .skipAccessibility(value):
                fixture = Fixture(step: .accessibility)
                fixture.coordinator.skip()
                expected = value
            case let .enableSelectionAfterExplanation(value):
                fixture = Fixture(step: .accessibility)
                fixture.coordinator.noteAccessibilityExplanationRendered()
                fixture.coordinator.enableSelectionCapture()
                expected = value
            case let .finishWithoutSelection(value):
                fixture = Fixture(step: .complete)
                await fixture.coordinator.finish()
                expected = value
                XCTAssertEqual(fixture.finishCounter.value, 1)
            }

            XCTAssertEqual(fixture.recorder.effects, expected)
            assertForbiddenEffectsRemainZero(fixture.recorder)
            assertPrivacyDefaultsRemainOff(fixture.preferences.value)
        }
    }

    func testEveryNonCompleteStepCanSkipWithoutCallingItsEffect() {
        for step in OnboardingStep.allCases where step != .complete {
            let fixture = Fixture(step: step)
            fixture.coordinator.skip()
            XCTAssertTrue(fixture.recorder.effects.isEmpty, "step: \(step)")
        }
    }

    func testAccessibilityPromptRequiresExplanationToRenderFirst() {
        let fixture = Fixture(step: .accessibility)

        fixture.coordinator.enableSelectionCapture()
        XCTAssertEqual(fixture.recorder.effects, [])
        XCTAssertEqual(fixture.coordinator.safeError, .explanationRequired)

        fixture.coordinator.noteAccessibilityExplanationRendered()
        fixture.coordinator.enableSelectionCapture()
        XCTAssertEqual(fixture.recorder.effects, [.accessibilityPrompt])
        XCTAssertGreaterThanOrEqual(fixture.coordinator.accessibilityExplanationRenderCount, 1)
    }

    func testRepeatedDetectKeepsOneLoopbackConfigurationAndClassifiesResults() async {
        let fixture = Fixture(step: .localOllama, models: ["llama3.2", "qwen2.5:7b"])

        await fixture.coordinator.detectOllama()
        await fixture.coordinator.detectOllama()

        XCTAssertEqual(fixture.provider.createdConfigurationCount, 1)
        XCTAssertEqual(fixture.coordinator.ollamaState, .available(models: ["llama3.2", "qwen2.5:7b"]))
        XCTAssertEqual(fixture.recorder.effects, [
            .ensureDefaultOllama, .loopbackOllamaTagsRequest,
            .ensureDefaultOllama, .loopbackOllamaTagsRequest,
        ])
        assertForbiddenEffectsRemainZero(fixture.recorder)
    }

    func testEmptyAndUnavailableOllamaExposeOnlySafeCategories() async {
        let empty = Fixture(step: .localOllama, models: [])
        await empty.coordinator.detectOllama()
        XCTAssertEqual(empty.coordinator.ollamaState, .modelsEmpty)

        let unavailable = Fixture(step: .localOllama, providerFailure: .ollamaUnavailable)
        await unavailable.coordinator.detectOllama()
        XCTAssertEqual(unavailable.coordinator.ollamaState, .unavailable)
    }

    func testSelectingDiscoveredModelIsTheOnlyModelMutationAndSetsDefaultProvider() async {
        let fixture = Fixture(step: .localOllama, models: ["qwen2.5:7b"])
        await fixture.coordinator.detectOllama()
        XCTAssertEqual(fixture.recorder.effects, [.ensureDefaultOllama, .loopbackOllamaTagsRequest])

        await fixture.coordinator.selectModel("qwen2.5:7b")

        XCTAssertEqual(fixture.recorder.effects.last, .updateSelectedModel)
        XCTAssertEqual(fixture.preferences.value.defaultProviderID, fixture.provider.configurationID)
        XCTAssertEqual(fixture.provider.selectedModels, ["qwen2.5:7b"])
        assertForbiddenEffectsRemainZero(fixture.recorder)
    }

    func testManualModelEntryUsesTheSameExplicitSelectionPath() async {
        let fixture = Fixture(step: .localOllama, models: [])
        await fixture.coordinator.detectOllama()
        fixture.coordinator.manualModelName = "  qwen2.5:7b  "

        await fixture.coordinator.selectManualModel()

        XCTAssertEqual(fixture.provider.selectedModels, ["qwen2.5:7b"])
        XCTAssertEqual(fixture.preferences.value.defaultProviderID, fixture.provider.configurationID)
        XCTAssertEqual(fixture.coordinator.step, .shortcut)
    }

    func testShortcutConflictCanRegisterAndPersistAUserReplacement() async {
        let fixture = Fixture(
            step: .shortcut,
            shortcutFailures: [.conflict, nil]
        )
        await fixture.coordinator.continueCurrentStep()
        XCTAssertTrue(fixture.coordinator.requiresShortcutReplacement)
        XCTAssertEqual(fixture.coordinator.step, .shortcut)

        await fixture.coordinator.registerReplacement(.optionShiftF)

        XCTAssertFalse(fixture.coordinator.requiresShortcutReplacement)
        XCTAssertEqual(fixture.preferences.value.shortcut, OnboardingShortcutChoice.optionShiftF.descriptor)
        XCTAssertEqual(fixture.coordinator.step, .accessibility)
    }

    func testShortcutViewOffersDefaultAttemptBeforeShowingConflictReplacement() async {
        let fixture = Fixture(
            step: .shortcut,
            shortcutFailures: [.conflict]
        )
        let initialView = OnboardingView(coordinator: fixture.coordinator)
        let initialHost = NSHostingView(rootView: initialView)
        initialHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(initialView.shortcutPresentation, .defaultAttempt)

        await fixture.coordinator.continueCurrentStep()

        let conflictView = OnboardingView(coordinator: fixture.coordinator)
        let conflictHost = NSHostingView(rootView: conflictView)
        conflictHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(conflictView.shortcutPresentation, .replacement)
    }

    func testProductionProviderAdapterMapsRealEmptySignalAndUsesOnlyNarrowOperations() async throws {
        let providerID = ProviderConfigurationID()
        let management = ProviderManagerSpy(id: providerID)
        let inspection = InspectionSpy(result: .failure(.modelUnavailable))
        let service = ProductionOnboardingProviderService(
            management: management,
            inspection: inspection
        )

        let first = try await service.ensureDefaultOllama()
        let second = try await service.ensureDefaultOllama()
        let models = try await service.discoverModels(for: providerID)
        try await service.selectModel("qwen2.5:7b", for: providerID)

        XCTAssertEqual(first, providerID)
        XCTAssertEqual(second, providerID)
        XCTAssertEqual(management.ensureCount, 2)
        XCTAssertEqual(Set(management.returnedIDs).count, 1)
        XCTAssertEqual(inspection.discoverIDs, [providerID])
        XCTAssertEqual(models, [])
        XCTAssertEqual(management.modelUpdates, ["qwen2.5:7b"])
    }

    func testSyntheticViewRenderAndSkipPerformNoExternalEffect() {
        for step in OnboardingStep.allCases where step != .complete {
            let fixture = Fixture(step: step)
            let host = NSHostingView(rootView: OnboardingView(coordinator: fixture.coordinator))
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            XCTAssertEqual(fixture.recorder.effects, [], "render step: \(step)")

            fixture.coordinator.skip()
            XCTAssertEqual(fixture.recorder.effects, [], "skip step: \(step)")
        }
    }

    func testProviderPreferenceFailureIsTypedAndRetryReconcilesDefault() async {
        let fixture = Fixture(step: .localOllama, models: ["qwen2.5:7b"])
        await fixture.coordinator.detectOllama()
        fixture.preferences.failNextUpdate()

        await fixture.coordinator.selectModel("qwen2.5:7b")

        XCTAssertEqual(fixture.coordinator.safeError, .persistenceFailed)
        XCTAssertNil(fixture.preferences.value.defaultProviderID)
        XCTAssertEqual(fixture.coordinator.step, .localOllama)

        await fixture.coordinator.selectModel("qwen2.5:7b")
        XCTAssertEqual(fixture.preferences.value.defaultProviderID, fixture.provider.configurationID)
        XCTAssertEqual(fixture.coordinator.step, .shortcut)
        XCTAssertEqual(fixture.provider.selectedModels, ["qwen2.5:7b"])
    }

    private func assertForbiddenEffectsRemainZero(
        _ recorder: EffectRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden: Set<Effect> = [
            .cloudCall, .chatBody, .modelDownload, .modelDelete,
            .automaticCaptureEnable, .launchAtLoginMutation,
            .unrelatedPermissionPrompt, .telemetry, .updateCheck, .periodicTask,
        ]
        XCTAssertTrue(
            recorder.effects.allSatisfy { !forbidden.contains($0) },
            file: file,
            line: line
        )
    }

    private func assertPrivacyDefaultsRemainOff(
        _ value: PreferencesSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(value.automaticCaptureEnabled, file: file, line: line)
        XCTAssertFalse(value.keyboardSelectionEnabled, file: file, line: line)
        XCTAssertFalse(value.clipboardFallbackEnabled, file: file, line: line)
        XCTAssertFalse(value.historyEnabled, file: file, line: line)
        XCTAssertFalse(value.mouseSelectionEnabled, file: file, line: line)
        XCTAssertFalse(value.launchAtLogin, file: file, line: line)
        XCTAssertTrue(value.generalAutomaticApplications.isEmpty, file: file, line: line)
        XCTAssertTrue(value.historyExcludedApplications.isEmpty, file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let recorder = EffectRecorder()
        let preferences: OnboardingPreferences
        let provider: ProviderFixture
        let finishCounter = Counter()
        let coordinator: OnboardingCoordinator

        init(
            step: OnboardingStep,
            models: [String] = [],
            shortcutFailure: ShortcutRegistrationFailure? = nil,
            shortcutFailures: [ShortcutRegistrationFailure?]? = nil,
            providerFailure: SanitizedFailure? = nil
        ) {
            let providerID = ProviderConfigurationID()
            preferences = OnboardingPreferences(providerID: providerID, recorder: recorder)
            provider = ProviderFixture(
                configurationID: providerID,
                models: models,
                failure: providerFailure,
                recorder: recorder
            )
            let shortcut = ShortcutSettingsModel(
                registrar: ShortcutFixture(
                    failures: shortcutFailures ?? [shortcutFailure],
                    recorder: recorder
                )
            )
            coordinator = OnboardingCoordinator(
                initialStep: step,
                preferences: preferences,
                provider: provider,
                shortcut: shortcut,
                clipboard: ClipboardFixture(recorder: recorder),
                accessibility: AccessibilityFixture(recorder: recorder),
                onReplacementRequired: { [recorder] in
                    recorder.append(.showReplacementChoice)
                },
                onFinished: { [finishCounter] in finishCounter.increment() }
            )
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int { lock.withLock { storage } }
        func increment() { lock.withLock { storage += 1 } }
    }

    private final class EffectRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Effect] = []
        var effects: [Effect] { lock.withLock { storage } }
        func append(_ effect: Effect) { lock.withLock { storage.append(effect) } }
    }

    private final class OnboardingPreferences: PreferencesStore, @unchecked Sendable {
        private let lock = NSLock()
        private let recorder: EffectRecorder
        var value: PreferencesSnapshot {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
        private var storage: PreferencesSnapshot
        private var updateFailuresRemaining = 0

        init(providerID: ProviderConfigurationID, recorder: EffectRecorder) {
            var value = PreferencesSnapshot.appFixture(providerID: providerID)
            value.onboardingCompleted = false
            value.automaticCaptureEnabled = false
            value.mouseSelectionEnabled = false
            value.keyboardSelectionEnabled = false
            value.clipboardFallbackEnabled = false
            value.historyEnabled = false
            value.generalAutomaticApplications = []
            value.historyExcludedApplications = []
            value.defaultProviderID = nil
            storage = value
            self.recorder = recorder
        }

        func snapshot() async throws -> PreferencesSnapshot { value }
        func update(_ transform: @Sendable (inout PreferencesSnapshot) throws -> Void) async throws {
            let shouldFail = lock.withLock { () -> Bool in
                guard updateFailuresRemaining > 0 else { return false }
                updateFailuresRemaining -= 1
                return true
            }
            if shouldFail { throw SanitizedFailure.preferencesUnrecoverable }
            let wasComplete = value.onboardingCompleted
            try lock.withLock { try transform(&storage) }
            if !wasComplete, value.onboardingCompleted {
                recorder.append(.persistOnboardingComplete)
            }
        }

        func failNextUpdate() {
            lock.withLock { updateFailuresRemaining += 1 }
        }
    }

    private final class ProviderFixture: OnboardingProviderServicing, @unchecked Sendable {
        let configurationID: ProviderConfigurationID
        private let models: [String]
        private let failure: SanitizedFailure?
        private let recorder: EffectRecorder
        private(set) var selectedModels: [String] = []
        private(set) var createdConfigurationCount = 0
        private var didCreate = false

        init(
            configurationID: ProviderConfigurationID,
            models: [String],
            failure: SanitizedFailure?,
            recorder: EffectRecorder
        ) {
            self.configurationID = configurationID
            self.models = models
            self.failure = failure
            self.recorder = recorder
        }

        func ensureDefaultOllama() async throws -> ProviderConfigurationID {
            recorder.append(.ensureDefaultOllama)
            if !didCreate {
                didCreate = true
                createdConfigurationCount += 1
            }
            if let failure { throw failure }
            return configurationID
        }

        func discoverModels(for id: ProviderConfigurationID) async throws -> [String] {
            recorder.append(.loopbackOllamaTagsRequest)
            if let failure { throw failure }
            return models
        }

        func selectModel(_ model: String, for id: ProviderConfigurationID) async throws {
            selectedModels.append(model)
            recorder.append(.updateSelectedModel)
        }
    }

    private actor ShortcutFixture: GlobalShortcutRegistering {
        var failures: [ShortcutRegistrationFailure?]
        let recorder: EffectRecorder
        init(failures: [ShortcutRegistrationFailure?], recorder: EffectRecorder) {
            self.failures = failures
            self.recorder = recorder
        }
        func register(_ descriptor: ShortcutDescriptor) async throws {
            recorder.append(.registerOptionShiftD)
            if !failures.isEmpty, let failure = failures.removeFirst() { throw failure }
        }
        func unregister() async {}
    }


    private final class ProviderManagerSpy: OnboardingProviderManaging, @unchecked Sendable {
        private let lock = NSLock()
        let id: ProviderConfigurationID
        private(set) var ensureCount = 0
        private(set) var returnedIDs: [ProviderConfigurationID] = []
        private(set) var modelUpdates: [String] = []
        init(id: ProviderConfigurationID) { self.id = id }
        func ensureDefaultOllama() async throws -> ProviderConfigurationID {
            lock.withLock {
                ensureCount += 1
                returnedIDs.append(id)
            }
            return id
        }
        func updateOllamaModel(_ model: String, for id: ProviderConfigurationID) async throws {
            lock.withLock { modelUpdates.append(model) }
        }
    }

    private final class InspectionSpy: ProviderInspection, @unchecked Sendable {
        private let lock = NSLock()
        let result: Result<[String], SanitizedFailure>
        private(set) var discoverIDs: [ProviderConfigurationID] = []
        init(result: Result<[String], SanitizedFailure>) { self.result = result }
        func discoverModels(for configurationID: ProviderConfigurationID) async throws -> [String] {
            lock.withLock { discoverIDs.append(configurationID) }
            return try result.get()
        }
        func testConnection(for configurationID: ProviderConfigurationID) async throws {}
    }

    private struct ClipboardFixture: OnboardingClipboardWriting {
        let recorder: EffectRecorder
        func copy(_ text: String) { recorder.append(.explicitPasteboardWrite) }
    }

    private struct AccessibilityFixture: AccessibilityPrompting {
        let recorder: EffectRecorder
        func requestSelectionAccess() -> Bool {
            recorder.append(.accessibilityPrompt)
            return true
        }
    }
}
