import ModelProviders
import SharedSupport

public actor DefaultTranslationEngine: TranslationEngine {
    private let provider: any ProviderService
    private let preflight: any ProviderPreflight
    private let parser: PromptTemplateParser
    private let compiler: any PromptCompiling
    private let languageResolver: LocalLanguageResolver
    private let timeout: any TimeoutControlling
    private var generation: UInt64 = 0
    private var timeoutTokenGeneration: UInt64 = 0
    private var active: ActiveTranslation?
    private var latestRetrySnapshot: RetrySnapshot?

    package init(
        provider: any ProviderService,
        preflight: any ProviderPreflight,
        clock: any AppClock,
        parser: PromptTemplateParser = PromptTemplateParser(),
        compiler: any PromptCompiling = PromptCompiler(),
        languageResolver: LocalLanguageResolver = LocalLanguageResolver(),
        timeoutController: (any TimeoutControlling)? = nil
    ) {
        self.provider = provider
        self.preflight = preflight
        self.parser = parser
        self.compiler = compiler
        self.languageResolver = languageResolver
        timeout = timeoutController ?? TimeoutController(clock: clock)
    }

    public func translate(
        _ intent: AuthorizedTranslationIntent
    ) async -> AsyncStream<TranslationUpdate> {
        let displacedGeneration = replaceActiveIfNeeded()
        generation &+= 1
        let capturedGeneration = generation
        let pair = AsyncStream<TranslationUpdate>.makeStream()
        pair.continuation.yield(.preparing)
        let task = Task {
            await self.execute(
                intent: intent,
                retrySnapshot: nil,
                generation: capturedGeneration
            )
        }
        active = ActiveTranslation(
            requestID: intent.requestID,
            generation: capturedGeneration,
            continuation: pair.continuation,
            task: task,
            retrySnapshot: nil,
            timeoutPhase: nil,
            timeoutToken: nil
        )
        if let displacedGeneration {
            await timeout.disarm(owner: displacedGeneration)
        }
        return pair.stream
    }

    public func retry(
        _ requestID: TranslationRequestID
    ) async -> AsyncStream<TranslationUpdate> {
        guard let snapshot = latestRetrySnapshot,
              snapshot.intent.requestID == requestID
        else {
            let pair = AsyncStream<TranslationUpdate>.makeStream()
            pair.continuation.yield(.failed(.providerProtocolFailure))
            pair.continuation.finish()
            return pair.stream
        }
        let displacedGeneration = replaceActiveIfNeeded()
        generation &+= 1
        let capturedGeneration = generation
        let pair = AsyncStream<TranslationUpdate>.makeStream()
        pair.continuation.yield(.preparing)
        let task = Task {
            await self.execute(
                intent: snapshot.intent,
                retrySnapshot: snapshot,
                generation: capturedGeneration
            )
        }
        active = ActiveTranslation(
            requestID: requestID,
            generation: capturedGeneration,
            continuation: pair.continuation,
            task: task,
            retrySnapshot: nil,
            timeoutPhase: nil,
            timeoutToken: nil
        )
        if let displacedGeneration {
            await timeout.disarm(owner: displacedGeneration)
        }
        return pair.stream
    }

    public func cancel(_ requestID: TranslationRequestID) async {
        guard let current = active,
              current.requestID == requestID
        else {
            return
        }
        active = nil
        generation &+= 1
        current.task.cancel()
        current.continuation.yield(.cancelled)
        current.continuation.finish()
        await timeout.disarm(owner: current.generation)
    }

    private func execute(
        intent: AuthorizedTranslationIntent,
        retrySnapshot fixedSnapshot: RetrySnapshot?,
        generation capturedGeneration: UInt64
    ) async {
        let payload = intent.payload
        guard case .success(let currentDestination) = await preflight.resolveDestination(
            for: payload.provider.configurationID
        ), currentDestination == payload.provider else {
            await finish(
                .failed(.destinationReconfirmationRequired),
                generation: capturedGeneration
            )
            return
        }
        guard isCurrent(capturedGeneration) else { return }

        let syntax: PromptSyntaxTree
        do {
            syntax = try parser.parse(payload.options.preset.template)
        } catch {
            await finish(.failed(.providerProtocolFailure), generation: capturedGeneration)
            return
        }
        let source: LanguageChoice
        let target: LanguageChoice
        if let fixedSnapshot {
            guard fixedSnapshot.providerConfigurationID == currentDestination.configurationID,
                  fixedSnapshot.model == currentDestination.model
            else {
                await finish(
                    .failed(.destinationReconfirmationRequired),
                    generation: capturedGeneration
                )
                return
            }
            source = fixedSnapshot.resolvedSource
            target = fixedSnapshot.target
        } else {
            let explicitSource: LanguageChoice?
            switch payload.options.sourceLanguage {
            case .automatic:
                explicitSource = nil
            case .identified:
                explicitSource = payload.options.sourceLanguage
            }
            source = languageResolver.resolve(
                payload.text,
                override: explicitSource
            )
            target = payload.options.targetLanguage
        }
        let compiled = compiler.compile(
            syntax,
            selectedText: payload.text,
            source: source,
            target: target
        )
        let request = TranslationRequest(
            instruction: compiled.instruction,
            userContent: compiled.userContent,
            model: currentDestination.model,
            timeouts: payload.options.timeouts,
            requestID: intent.requestID
        )
        var lifecycle = TranslationLifecycle(
            requestID: intent.requestID,
            sourceText: payload.text,
            presetID: payload.options.preset.id,
            sourceLanguage: source,
            targetLanguage: target,
            providerClass: currentDestination.privacyClass
        )
        let snapshot = fixedSnapshot ?? RetrySnapshot(
            intent: intent,
            resolvedSource: source,
            target: target,
            providerConfigurationID: currentDestination.configurationID,
            model: currentDestination.model
        )
        setRetrySnapshot(snapshot, generation: capturedGeneration)

        yield(.connecting, generation: capturedGeneration)
        setTimeoutPhase(.connecting, generation: capturedGeneration)
        await arm(
            phase: .connecting,
            duration: payload.options.timeouts.connection,
            failure: .connectionTimeout,
            generation: capturedGeneration
        )
        guard !Task.isCancelled, isCurrent(capturedGeneration) else { return }
        let chunks = await provider.generate(
            request,
            authorizedDestination: currentDestination
        )

        do {
            for try await chunk in chunks {
                guard isCurrent(capturedGeneration) else { return }
                let update = try lifecycle.accept(chunk)
                switch chunk {
                case .connected:
                    setTimeoutPhase(.waitingForFirstToken, generation: capturedGeneration)
                    await arm(
                        phase: .waitingForFirstToken,
                        duration: payload.options.timeouts.firstToken,
                        failure: .firstTokenTimeout,
                        generation: capturedGeneration
                    )
                case .content(let value) where !value.isEmpty:
                    setTimeoutPhase(.streaming, generation: capturedGeneration)
                    await arm(
                        phase: .streaming,
                        duration: payload.options.timeouts.streamIdle,
                        failure: .streamIdleTimeout,
                        generation: capturedGeneration
                    )
                case .content, .done:
                    break
                }
                guard !Task.isCancelled, isCurrent(capturedGeneration) else { return }
                if let update {
                    if case .completed = update {
                        await finish(update, generation: capturedGeneration)
                        return
                    }
                    yield(update, generation: capturedGeneration)
                }
            }
            guard !Task.isCancelled, isCurrent(capturedGeneration) else { return }
            await finish(.failed(.providerProtocolFailure), generation: capturedGeneration)
        } catch is CancellationError {
            await finish(.cancelled, generation: capturedGeneration)
        } catch let failure as SanitizedFailure {
            if failure == .cancelled {
                await finish(.cancelled, generation: capturedGeneration)
            } else {
                await finish(.failed(failure), generation: capturedGeneration)
            }
        } catch {
            await finish(.failed(.providerProtocolFailure), generation: capturedGeneration)
        }
    }

    private func arm(
        phase: TranslationPhase,
        duration: Duration,
        failure: SanitizedFailure,
        generation capturedGeneration: UInt64
    ) async {
        timeoutTokenGeneration &+= 1
        let token = timeoutTokenGeneration
        setTimeoutToken(token, generation: capturedGeneration)
        _ = await timeout.arm(owner: capturedGeneration, token: token, phase: phase, duration: duration) { token in
            await self.timeoutFired(
                failure,
                phase: phase,
                token: token,
                generation: capturedGeneration
            )
        }
    }

    private func timeoutFired(
        _ failure: SanitizedFailure,
        phase: TranslationPhase,
        token: UInt64,
        generation capturedGeneration: UInt64
    ) async {
        guard let current = active,
              current.generation == capturedGeneration,
              current.timeoutPhase == phase,
              current.timeoutToken == token
        else {
            return
        }
        active = nil
        generation &+= 1
        if let snapshot = current.retrySnapshot {
            latestRetrySnapshot = snapshot
        }
        current.task.cancel()
        current.continuation.yield(.failed(failure))
        current.continuation.finish()
        await timeout.disarm(owner: capturedGeneration)
    }

    private func finish(
        _ update: TranslationUpdate,
        generation capturedGeneration: UInt64
    ) async {
        guard let current = active,
              current.generation == capturedGeneration
        else {
            return
        }
        active = nil
        if case .cancelled = update {
            // Cancellation never creates or replaces a retry snapshot.
        } else if let snapshot = current.retrySnapshot {
            latestRetrySnapshot = snapshot
        }
        current.continuation.yield(update)
        current.continuation.finish()
        await timeout.disarm(owner: capturedGeneration)
    }

    private func yield(
        _ update: TranslationUpdate,
        generation capturedGeneration: UInt64
    ) {
        guard let current = active,
              current.generation == capturedGeneration
        else {
            return
        }
        current.continuation.yield(update)
    }

    private func isCurrent(_ capturedGeneration: UInt64) -> Bool {
        active?.generation == capturedGeneration
    }

    private func setRetrySnapshot(
        _ snapshot: RetrySnapshot,
        generation capturedGeneration: UInt64
    ) {
        guard var current = active,
              current.generation == capturedGeneration
        else {
            return
        }
        current.retrySnapshot = snapshot
        active = current
    }

    private func setTimeoutPhase(
        _ phase: TranslationPhase,
        generation capturedGeneration: UInt64
    ) {
        guard var current = active,
              current.generation == capturedGeneration
        else { return }
        current.timeoutPhase = phase
        current.timeoutToken = nil
        active = current
    }

    private func setTimeoutToken(
        _ token: UInt64,
        generation capturedGeneration: UInt64
    ) {
        guard var current = active,
              current.generation == capturedGeneration
        else { return }
        current.timeoutToken = token
        active = current
    }

    private func replaceActiveIfNeeded() -> UInt64? {
        guard let current = active else { return nil }
        active = nil
        generation &+= 1
        current.task.cancel()
        current.continuation.yield(.cancelled)
        current.continuation.finish()
        return current.generation
    }
}
