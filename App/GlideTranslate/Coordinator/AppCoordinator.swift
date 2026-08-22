import Foundation
import PrivacyStorage
import SelectionCapture
import SharedSupport

struct ManualTranslationDraft: Sendable {
    let text: String
    let sourceLanguage: LanguageChoice
    let targetLanguage: LanguageChoice
    let presetID: PresetID
    let providerID: ProviderConfigurationID?
}

@MainActor
protocol ManualInputPresenting: AnyObject {
    func open()
    func openPresetPicker(
        sessionID: UUID,
        currentPresetID: PresetID,
        onSelect: @escaping @MainActor @Sendable (PresetID) -> Void
    )
    func cancelPresetPicker(sessionID: UUID?)
}

@MainActor
protocol CoordinatorFeedbackPresenting: AnyObject {
    func presentSafeNextAction(_ presentation: SafeNextActionPresentation)
}

@MainActor
protocol TranslationResultCopying: Sendable {
    func copy(_ text: String)
}

@MainActor
private struct NoopTranslationResultCopyWriter: TranslationResultCopying {
    func copy(_ text: String) {}
}

@MainActor
final class AppCoordinator {
    @MainActor
    private final class EntryGate {
        private var isTerminal = false
        private var activeCount = 0
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []

        func acquire() -> Bool {
            guard !isTerminal else { return false }
            activeCount &+= 1
            return true
        }

        func release() {
            precondition(activeCount > 0)
            activeCount -= 1
            guard activeCount == 0 else { return }
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func retire() {
            isTerminal = true
        }

        func drain() async {
            guard activeCount > 0 else { return }
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    private final class PanelPresentationState {
        var presentation: TranslationPresentation?
    }

    private struct ActiveRequest {
        let requestID: TranslationRequestID
        let generation: UInt64
        let trustedSourceApplication: ApplicationIdentity?
        let panelState: PanelPresentationState
    }

    private struct IntentClaim {
        let generation: UInt64
        let priorRequestID: TranslationRequestID?
    }

    private struct PreparedSystemTrigger {
        let options: TranslationOptionsSnapshot
        let policy: CapturePolicySnapshot
        let provider: ProviderDestinationSnapshot
        let providerID: ProviderConfigurationID
        let manualCharacterLimit: Int
    }

    private struct ActivePresetPicker {
        let ownerGeneration: UInt64
        let sessionID: UUID
    }

    private struct ResubmissionSeed: Sendable {
        let context: AuthorizedTranslationPresentationContext
        let selectedProviderID: ProviderConfigurationID
        let trustedSourceApplication: ApplicationIdentity?

        init(
            context: AuthorizedTranslationPresentationContext,
            selectedProviderID: ProviderConfigurationID
        ) {
            self.context = context
            self.selectedProviderID = selectedProviderID
            trustedSourceApplication = context.sourceApplication
        }

        private init(
            reauthorizedContext context: AuthorizedTranslationPresentationContext,
            preserving seed: Self
        ) {
            self.context = context
            selectedProviderID = seed.selectedProviderID
            trustedSourceApplication = seed.trustedSourceApplication
        }

        static func reauthorized(
            context: AuthorizedTranslationPresentationContext,
            preserving seed: Self
        ) -> Self {
            Self(reauthorizedContext: context, preserving: seed)
        }
    }

    private let environment: AppEnvironment
    private let contextLoader: AuthorizationContextLoader
    private let panelPresenter: any ResultPanelPresenting
    private let manualInputPresenter: any ManualInputPresenting
    private let feedbackPresenter: any CoordinatorFeedbackPresenting
    private let resultCopyWriter: any TranslationResultCopying
    private let preferencesChanged:
        (@MainActor @Sendable (PreferencesSnapshot) async -> Void)?
    private let foregroundApplicationDisabledChanged:
        @MainActor @Sendable (Bool) -> Void
    private var active: ActiveRequest?
    private var streamTask: Task<Void, Never>?
    private var currentStreamTaskID: UUID?
    private var ownedStreamTasks: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private var automaticAttemptGeneration: UInt64 = 0
    private var presentation: TranslationPresentation?
    private var presentationGeneration: UInt64?
    private var isRetired = false
    private let entryGate = EntryGate()
    private var activePresetPicker: ActivePresetPicker?
    private var terminationCompleted = false
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    lazy var manualInputViewModel: ManualInputViewModel = .development { [weak self] draft in
        await self?.submitManual(draft)
    }

    init(
        environment: AppEnvironment,
        panelPresenter: any ResultPanelPresenting,
        manualInputPresenter: any ManualInputPresenting,
        feedbackPresenter: any CoordinatorFeedbackPresenting,
        resultCopyWriter: any TranslationResultCopying = NoopTranslationResultCopyWriter(),
        foregroundApplicationDisabledChanged:
            @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        preferencesChanged:
            (@MainActor @Sendable (PreferencesSnapshot) async -> Void)? = nil
    ) {
        self.environment = environment
        contextLoader = AuthorizationContextLoader(
            preferences: environment.preferences,
            providerManagement: environment.providerManagement,
            providerPreflight: environment.providerPreflight
        )
        self.panelPresenter = panelPresenter
        self.manualInputPresenter = manualInputPresenter
        self.feedbackPresenter = feedbackPresenter
        self.resultCopyWriter = resultCopyWriter
        self.foregroundApplicationDisabledChanged =
            foregroundApplicationDisabledChanged
        self.preferencesChanged = preferencesChanged
    }

    func handleSystemTrigger(
        _ trigger: CaptureTrigger,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        presetID: PresetID
    ) async {
        guard entryGate.acquire() else { return }
        defer { entryGate.release() }
        if trigger == .mouse || trigger == .keyboardSelection {
            await handleAutomaticSystemTrigger(
                trigger,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                presetID: presetID
            )
            return
        }
        guard let claim = claimIntent() else { return }
        await cancelPriorRequest(for: claim)
        guard isCurrent(claim) else { return }
        await handleSystemTrigger(
            trigger,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            presetID: presetID,
            claim: claim
        )
    }

    private func handleSystemTrigger(
        _ trigger: CaptureTrigger,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        presetID: PresetID,
        claim: IntentClaim
    ) async {
        do {
            let prepared = try await prepareSystemTrigger(
                trigger,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                presetID: presetID
            )
            guard isCurrent(claim) else { return }
            let outcome = await environment.systemSelectionProcessor.process(
                trigger: trigger,
                options: prepared.options,
                policy: prepared.policy,
                provider: prepared.provider
            )
            guard isCurrent(claim) else { return }
            recordCaptureOutcome(outcome)
            publishForegroundApplicationState(
                for: trigger,
                outcome: outcome
            )
            await handle(
                outcome,
                trigger: trigger,
                selectedProviderID: prepared.providerID,
                manualCharacterLimit: prepared.manualCharacterLimit,
                claim: claim
            )
        } catch {
            present(error, claim: claim)
        }
    }

    private func handleAutomaticSystemTrigger(
        _ trigger: CaptureTrigger,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        presetID: PresetID
    ) async {
        automaticAttemptGeneration &+= 1
        let attemptGeneration = automaticAttemptGeneration
        let observedGeneration = generation
        do {
            let prepared = try await prepareSystemTrigger(
                trigger,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                presetID: presetID
            )
            guard isCurrentAutomaticAttempt(
                attemptGeneration,
                observedGeneration: observedGeneration
            ) else { return }
            let outcome = await environment.systemSelectionProcessor.process(
                trigger: trigger,
                options: prepared.options,
                policy: prepared.policy,
                provider: prepared.provider
            )
            guard isCurrentAutomaticAttempt(
                attemptGeneration,
                observedGeneration: observedGeneration
            ) else { return }
            recordCaptureOutcome(outcome)
            publishForegroundApplicationState(
                for: trigger,
                outcome: outcome
            )
            guard case .authorized = outcome,
                  let claim = claimIntent() else { return }
            await cancelPriorRequest(for: claim)
            guard isCurrent(claim) else { return }
            await handle(
                outcome,
                trigger: trigger,
                selectedProviderID: prepared.providerID,
                manualCharacterLimit: prepared.manualCharacterLimit,
                claim: claim
            )
        } catch {
            return
        }
    }

    private func prepareSystemTrigger(
        _ trigger: CaptureTrigger,
        sourceLanguage: LanguageChoice,
        targetLanguage: LanguageChoice,
        presetID: PresetID
    ) async throws -> PreparedSystemTrigger {
        async let preset = environment.promptPresets.validatedPreset(presetID)
        async let inputs = contextLoader.systemInputs(for: trigger)
        let (validatedPreset, authorizationInputs) = try await (preset, inputs)
        let options = TranslationOptionsSnapshot(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            preset: validatedPreset,
            timeouts: Self.timeouts(from: authorizationInputs.preferences)
        )
        return PreparedSystemTrigger(
            options: options,
            policy: authorizationInputs.policy,
            provider: authorizationInputs.provider,
            providerID: authorizationInputs.providerID,
            manualCharacterLimit:
                authorizationInputs.preferences.selectionCharacterLimit
        )
    }

    func submitManual(_ draft: ManualTranslationDraft) async {
        guard entryGate.acquire() else { return }
        defer { entryGate.release() }
        guard let claim = claimIntent() else { return }
        await cancelPriorRequest(for: claim)
        guard isCurrent(claim) else { return }
        do {
            let validatedPreset = try await environment.promptPresets
                .validatedPreset(draft.presetID)
            let inputs = try await contextLoader.manualInputs(
                selectedProviderID: draft.providerID
            )
            guard isCurrent(claim) else { return }
            guard let text = Self.validatedManualText(
                draft.text,
                limit: inputs.preferences.selectionCharacterLimit
            ) else {
                feedbackPresenter.presentSafeNextAction(
                    SanitizedFailure.noValidSelection.safeNextActionPresentation
                )
                return
            }
            let submission = ManualTranslationSubmission(
                text: text,
                options: TranslationOptionsSnapshot(
                    sourceLanguage: draft.sourceLanguage,
                    targetLanguage: draft.targetLanguage,
                    preset: validatedPreset,
                    timeouts: Self.timeouts(from: inputs.preferences)
                ),
                providerConfigurationID: inputs.providerID
            )
            let outcome = await environment.authorizationGate
                .authorizeManualSubmission(
                    submission,
                    policy: SendPolicySnapshot(expectedProvider: inputs.provider),
                    provider: inputs.provider
                )
            guard isCurrent(claim) else { return }
            await handle(
                outcome,
                trigger: .manualInput,
                selectedProviderID: inputs.providerID,
                manualCharacterLimit: inputs.preferences.selectionCharacterLimit,
                claim: claim
            )
        } catch {
            present(error, claim: claim)
        }
    }

    func handleMenuTranslateSelectedText() async {
        guard entryGate.acquire() else { return }
        defer { entryGate.release() }
        guard let claim = claimIntent() else { return }
        await cancelPriorRequest(for: claim)
        guard isCurrent(claim) else { return }
        do {
            let preferences = try await environment.preferences.snapshot()
            guard isCurrent(claim) else { return }
            await handleSystemTrigger(
                .shortcut,
                sourceLanguage: .automatic,
                targetLanguage: preferences.defaultTargetLanguage,
                presetID: preferences.defaultPresetID,
                claim: claim
            )
        } catch {
            present(error, claim: claim)
        }
    }

    func setAutomaticCapturePaused(_ paused: Bool) async {
        guard entryGate.acquire() else { return }
        defer { entryGate.release() }
        guard !isRetired else { return }
        do {
            try await environment.preferences.update {
                $0.automaticCaptureEnabled = !paused
            }
            let snapshot = try await environment.preferences.snapshot()
            guard !isRetired else { return }
            await preferencesChanged?(snapshot)
        } catch {
            present(error)
        }
    }

    func selectDefaultPreset(_ presetID: PresetID) async {
        guard entryGate.acquire() else { return }
        defer { entryGate.release() }
        guard !isRetired else { return }
        do {
            try await environment.preferences.update {
                $0.defaultPresetID = presetID
            }
            let snapshot = try await environment.preferences.snapshot()
            guard !isRetired else { return }
            await preferencesChanged?(snapshot)
        } catch {
            present(error)
        }
    }

    func terminate() async {
        if isRetired {
            await waitForTermination()
            return
        }
        isRetired = true
        entryGate.retire()
        generation &+= 1
        cancelCurrentStreamTask()
        let requestID = active?.requestID
        active = nil
        presentation = nil
        presentationGeneration = nil
        cancelActivePresetPicker()
        panelPresenter.dismissTemporary()
        panelPresenter.dismissPinned()
        if let requestID {
            await environment.translationEngine.cancel(requestID)
        }
        await drainOwnedStreamTasks()
        await entryGate.drain()
        cancelActivePresetPicker()
        finishTermination()
    }

    private func handle(
        _ outcome: SelectionAuthorizationOutcome,
        trigger: CaptureTrigger,
        selectedProviderID: ProviderConfigurationID,
        manualCharacterLimit: Int? = nil,
        claim: IntentClaim
    ) async {
        guard isCurrent(claim) else { return }
        switch outcome {
        case let .authorized(intent, context):
            await start(
                intent,
                context: context,
                selectedProviderID: selectedProviderID,
                claim: claim
            )
        case .manualInputRequired:
            if let manualCharacterLimit {
                manualInputViewModel.updateCharacterLimit(manualCharacterLimit)
            }
            manualInputPresenter.open()
        case let .rejected(failure):
            guard failure != .cancelled else { return }
            guard trigger != .mouse, trigger != .keyboardSelection else { return }
            feedbackPresenter.presentSafeNextAction(
                failure.safeNextActionPresentation
            )
        }
    }

    private func publishForegroundApplicationState(
        for trigger: CaptureTrigger,
        outcome: SelectionAuthorizationOutcome
    ) {
        guard trigger == .mouse || trigger == .keyboardSelection else { return }
        let disabled: Bool
        if case let .rejected(failure) = outcome {
            disabled = failure == .applicationNotAllowed
                || failure == .offDeviceApplicationNotAllowed
        } else {
            disabled = false
        }
        foregroundApplicationDisabledChanged(disabled)
    }

    private func recordCaptureOutcome(
        _ outcome: SelectionAuthorizationOutcome
    ) {
        let category: CaptureOutcomeCategory
        switch outcome {
        case .authorized:
            category = .succeeded
        case .manualInputRequired:
            category = .rejected
        case .rejected(.cancelled):
            category = .cancelled
        case .rejected(.selectionReadTimedOut):
            category = .timedOut
        case .rejected:
            category = .rejected
        }
        environment.logger.record(.captureOutcome(category))
        if case let .rejected(failure) = outcome {
            environment.logger.record(
                .captureFailure(failure.captureFailureCategory)
            )
        }
    }

    private func start(
        _ intent: AuthorizedTranslationIntent,
        context: AuthorizedTranslationPresentationContext,
        selectedProviderID: ProviderConfigurationID,
        claim: IntentClaim
    ) async {
        let seed = ResubmissionSeed(
            context: context,
            selectedProviderID: selectedProviderID
        )
        await begin(intent, context: context, seed: seed, claim: claim)
    }

    private func startResubmission(
        _ intent: AuthorizedTranslationIntent,
        context: AuthorizedTranslationPresentationContext,
        preserving seed: ResubmissionSeed,
        claim: IntentClaim
    ) async {
        await begin(
            intent,
            context: context,
            seed: .reauthorized(context: context, preserving: seed),
            claim: claim
        )
    }

    private func begin(
        _ intent: AuthorizedTranslationIntent,
        context: AuthorizedTranslationPresentationContext,
        seed: ResubmissionSeed,
        claim: IntentClaim
    ) async {
        guard let requestGeneration = await prepareStream(
            requestID: intent.requestID,
            context: context,
            seed: seed,
            claim: claim
        ) else { return }
        launchStreamTask { [weak self, environment] in
            guard !Task.isCancelled else { return }
            let stream = await environment.translationEngine.translate(intent)
            guard !Task.isCancelled,
                  let self,
                  !self.isRetired,
                  self.generation == requestGeneration else {
                await environment.translationEngine.cancel(intent.requestID)
                return
            }
            for await update in stream {
                guard !Task.isCancelled else { return }
                await self.consume(update, generation: requestGeneration)
            }
        }
    }

    private func prepareStream(
        requestID: TranslationRequestID,
        context: AuthorizedTranslationPresentationContext,
        seed: ResubmissionSeed,
        claim: IntentClaim
    ) async -> UInt64? {
        let requestGeneration = claim.generation
        let displayName = await presetDisplayName(for: context.presetID)
        guard isCurrent(claim) else { return nil }
        let panelState = PanelPresentationState()
        let preparing = TranslationPresentation(
            context: context,
            presetDisplayName: displayName
        )
        panelState.presentation = preparing
        presentation = preparing
        presentationGeneration = requestGeneration
        active = ActiveRequest(
            requestID: requestID,
            generation: requestGeneration,
            trustedSourceApplication: seed.trustedSourceApplication,
            panelState: panelState
        )
        panelPresenter.showTemporary(
            preparing,
            actions: actions(
                for: requestID,
                generation: requestGeneration,
                seed: seed,
                panelState: panelState
            )
        )
        return requestGeneration
    }

    private func presetDisplayName(for id: PresetID) async -> String? {
        guard !PresetID.builtInDisplayIDs.contains(id) else { return nil }
        return try? await environment.promptPresets.customPresets()
            .first(where: { $0.id == id })?.name
    }

    private func consume(
        _ update: TranslationUpdate,
        generation expectedGeneration: UInt64
    ) async {
        guard let active,
              active.generation == expectedGeneration,
              generation == expectedGeneration,
              var current = presentation else { return }
        switch update {
        case .preparing:
            break
        case .connecting:
            current = current.withPhase(.connecting)
        case .waitingForFirstToken:
            current = current.withPhase(.waitingForFirstToken)
        case let .streaming(delta):
            current = current.appending(delta: delta)
        case let .completed(completion):
            current = current.completing(with: completion)
            presentation = current
            active.panelState.presentation = current
            panelPresenter.updateTemporary(current)
            self.active = nil
            do {
                let historyOutcome = try await environment.history.recordCompleted(
                    completion,
                    sourceApplication: active.trustedSourceApplication
                )
                guard canPresentCompletionFeedback(
                    generation: expectedGeneration
                ) else { return }
                if let presentation = historyOutcome.safeNextActionPresentation {
                    feedbackPresenter.presentSafeNextAction(presentation)
                }
            } catch {
                guard canPresentCompletionFeedback(
                    generation: expectedGeneration
                ) else { return }
                environment.logger.record(.historyOutcome(.unrecoverable))
                feedbackPresenter.presentSafeNextAction(
                    SanitizedFailure.historyUnrecoverable.safeNextActionPresentation
                )
            }
            return
        case .cancelled:
            cancelPresetPickerOwned(by: active.generation)
            self.active = nil
            panelPresenter.dismissTemporary()
            presentation = nil
            presentationGeneration = nil
            return
        case let .failed(failure):
            current = current.withPhase(.failed)
            presentation = current
            active.panelState.presentation = current
            panelPresenter.updateTemporary(current)
            self.active = nil
            environment.logger.record(.translationOutcome(
                failure,
                durationMilliseconds: 0
            ))
            if failure != .cancelled {
                feedbackPresenter.presentSafeNextAction(
                    failure.safeNextActionPresentation
                )
            }
            return
        }
        presentation = current
        active.panelState.presentation = current
        panelPresenter.updateTemporary(current)
    }

    private func actions(
        for requestID: TranslationRequestID,
        generation: UInt64,
        seed: ResubmissionSeed,
        panelState: PanelPresentationState
    ) -> ResultPanelActions {
        ResultPanelActions(
            copy: { [weak self, panelState] in
                self?.copyResult(from: panelState)
            },
            retry: { [weak self] in
                Task { await self?.retry(requestID, seed: seed) }
            },
            changePreset: { [weak self] in
                self?.openPresetPicker(
                    seed: seed,
                    ownerGeneration: generation
                )
            },
            close: { [weak self] in
                self?.cancelPresetPickerOwned(by: generation)
                Task {
                    await self?.presentationClosed(
                        requestID: requestID,
                        generation: generation
                    )
                }
            }
        )
    }

    private func copyResult(from panelState: PanelPresentationState?) {
        guard let result = panelState?.presentation?.resultText,
              !result.isEmpty else { return }
        resultCopyWriter.copy(result)
    }

    private func retry(
        _ requestID: TranslationRequestID,
        seed: ResubmissionSeed
    ) async {
        guard entryGate.acquire() else { return }
        defer { entryGate.release() }
        guard let claim = claimIntent() else { return }
        await cancelPriorRequest(for: claim)
        guard isCurrent(claim) else { return }
        guard let requestGeneration = await prepareStream(
            requestID: requestID,
            context: seed.context,
            seed: seed,
            claim: claim
        ) else { return }
        launchStreamTask { [weak self, environment] in
            guard !Task.isCancelled else { return }
            let stream = await environment.translationEngine.retry(requestID)
            guard !Task.isCancelled,
                  let self,
                  !self.isRetired,
                  self.generation == requestGeneration else {
                await environment.translationEngine.cancel(requestID)
                return
            }
            for await update in stream {
                guard !Task.isCancelled else { return }
                await self.consume(update, generation: requestGeneration)
            }
        }
    }

    private func openPresetPicker(
        seed: ResubmissionSeed,
        ownerGeneration: UInt64
    ) {
        guard !isRetired else { return }
        cancelActivePresetPicker()
        let sessionID = UUID()
        activePresetPicker = ActivePresetPicker(
            ownerGeneration: ownerGeneration,
            sessionID: sessionID
        )
        manualInputPresenter.openPresetPicker(
            sessionID: sessionID,
            currentPresetID: seed.context.presetID
        ) { [weak self] presetID in
            guard self?.consumePresetPicker(sessionID: sessionID) == true else {
                return
            }
            Task { await self?.changePreset(to: presetID, seed: seed) }
        }
    }

    private func changePreset(
        to presetID: PresetID,
        seed: ResubmissionSeed
    ) async {
        guard entryGate.acquire() else { return }
        defer { entryGate.release() }
        guard let claim = claimIntent() else { return }
        await cancelPriorRequest(for: claim)
        guard isCurrent(claim) else { return }
        do {
            let validatedPreset = try await environment.promptPresets
                .validatedPreset(presetID)
            let inputs = try await contextLoader.manualInputs(
                selectedProviderID: seed.selectedProviderID
            )
            guard isCurrent(claim) else { return }
            let submission = ManualTranslationSubmission(
                text: seed.context.sourceText,
                options: TranslationOptionsSnapshot(
                    sourceLanguage: seed.context.sourceLanguage,
                    targetLanguage: seed.context.targetLanguage,
                    preset: validatedPreset,
                    timeouts: Self.timeouts(from: inputs.preferences)
                ),
                providerConfigurationID: seed.selectedProviderID
            )
            let outcome = await environment.authorizationGate
                .authorizeManualSubmission(
                    submission,
                    policy: SendPolicySnapshot(expectedProvider: inputs.provider),
                    provider: inputs.provider
                )
            guard isCurrent(claim) else { return }
            switch outcome {
            case let .authorized(intent, context):
                await startResubmission(
                    intent,
                    context: context,
                    preserving: seed,
                    claim: claim
                )
            case .manualInputRequired:
                manualInputViewModel.updateCharacterLimit(
                    inputs.preferences.selectionCharacterLimit
                )
                manualInputPresenter.open()
            case let .rejected(failure):
                if failure != .cancelled {
                    feedbackPresenter.presentSafeNextAction(
                        failure.safeNextActionPresentation
                    )
                }
            }
        } catch {
            present(error, claim: claim)
        }
    }

    private func presentationClosed(
        requestID: TranslationRequestID,
        generation panelGeneration: UInt64
    ) async {
        cancelPresetPickerOwned(by: panelGeneration)
        guard presentationGeneration == panelGeneration else { return }
        generation &+= 1
        cancelCurrentStreamTask()
        let ownsActiveRequest = active?.generation == panelGeneration
        if ownsActiveRequest { active = nil }
        presentation = nil
        presentationGeneration = nil
        if ownsActiveRequest {
            await environment.translationEngine.cancel(requestID)
        }
    }

    private func present(_ error: Error, claim: IntentClaim? = nil) {
        if let claim, !isCurrent(claim) { return }
        guard !isRetired else { return }
        feedbackPresenter.presentSafeNextAction(
            ((error as? SanitizedFailure) ?? .invalidProviderConfiguration)
                .safeNextActionPresentation
        )
    }

    private func claimIntent() -> IntentClaim? {
        guard !isRetired else { return nil }
        cancelActivePresetPicker()
        generation &+= 1
        let claim = IntentClaim(
            generation: generation,
            priorRequestID: active?.requestID
        )
        cancelCurrentStreamTask()
        active = nil
        presentation = nil
        presentationGeneration = nil
        panelPresenter.dismissTemporary()
        return claim
    }

    private func consumePresetPicker(sessionID: UUID) -> Bool {
        guard activePresetPicker?.sessionID == sessionID else { return false }
        manualInputPresenter.cancelPresetPicker(sessionID: sessionID)
        activePresetPicker = nil
        return true
    }

    private func cancelPresetPickerOwned(by generation: UInt64) {
        guard activePresetPicker?.ownerGeneration == generation else { return }
        cancelActivePresetPicker()
    }

    private func cancelActivePresetPicker() {
        guard let activePresetPicker else { return }
        manualInputPresenter.cancelPresetPicker(
            sessionID: activePresetPicker.sessionID
        )
        self.activePresetPicker = nil
    }

    private func cancelPriorRequest(for claim: IntentClaim) async {
        if let requestID = claim.priorRequestID {
            await environment.translationEngine.cancel(requestID)
        }
        guard isCurrent(claim) else { return }
        await drainOwnedStreamTasks()
    }

    private func isCurrent(_ claim: IntentClaim) -> Bool {
        !isRetired && generation == claim.generation
    }

    private func isCurrentAutomaticAttempt(
        _ attemptGeneration: UInt64,
        observedGeneration: UInt64
    ) -> Bool {
        !isRetired
            && automaticAttemptGeneration == attemptGeneration
            && generation == observedGeneration
    }

    private func canPresentCompletionFeedback(
        generation expectedGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled && !isRetired && generation == expectedGeneration
    }

    private func launchStreamTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.ownedStreamTaskFinished(id)
        }
        ownedStreamTasks[id] = task
        streamTask = task
        currentStreamTaskID = id
    }

    private func cancelCurrentStreamTask() {
        streamTask?.cancel()
        streamTask = nil
        currentStreamTaskID = nil
    }

    private func ownedStreamTaskFinished(_ id: UUID) {
        if currentStreamTaskID == id {
            streamTask = nil
            currentStreamTaskID = nil
        }
        ownedStreamTasks[id] = nil
    }

    private func drainOwnedStreamTasks() async {
        let tasks = Array(ownedStreamTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func waitForTermination() async {
        guard !terminationCompleted else { return }
        await withCheckedContinuation { terminationWaiters.append($0) }
    }

    private func finishTermination() {
        terminationCompleted = true
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private static func timeouts(
        from preferences: PreferencesSnapshot
    ) -> TranslationTimeoutPolicy {
        TranslationTimeoutPolicy(
            connection: .seconds(preferences.connectionTimeoutSeconds),
            firstToken: .seconds(preferences.firstTokenTimeoutSeconds),
            streamIdle: .seconds(preferences.streamIdleTimeoutSeconds)
        )
    }

    private static func validatedManualText(
        _ raw: String,
        limit: Int
    ) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit else { return nil }
        return text
    }
}

private extension TranslationPresentation {
    func withPhase(_ phase: TranslationPresentationPhase) -> Self {
        Self(
            sourceText: sourceText,
            resultText: resultText,
            presetID: presetID,
            presetDisplayName: presetDisplayName,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            providerClass: providerClass,
            displayRect: displayRect,
            phase: phase
        )
    }
}
