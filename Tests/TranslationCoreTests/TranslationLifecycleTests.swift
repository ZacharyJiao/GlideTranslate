import Foundation
import ModelProviders
import SharedSupport
import TestSupport
@testable import TranslationCore
import XCTest

final class TranslationLifecycleTests: XCTestCase {
    func testValidAndMalformedProviderOrdering() async {
        let valid = await EngineFixture(chunks: [
            .connected, .content("a"), .content("b"), .done
        ]).runToTerminal()
        XCTAssertEqual(valid.compactMap(\.simple), [
            .preparing, .connecting, .waitingForFirstToken,
            .streaming("a"), .streaming("b"), .completed("ab")
        ])

        let empty = await EngineFixture(chunks: [
            .connected, .content(""), .content("a"), .done
        ]).runToTerminal()
        XCTAssertEqual(empty.compactMap(\.simple), [
            .preparing, .connecting, .waitingForFirstToken,
            .streaming("a"), .completed("a")
        ])

        for chunks in [[TranslationChunk.connected, .done], [.content("a")]] {
            let updates = await EngineFixture(chunks: chunks).runToTerminal()
            XCTAssertEqual(updates.last, .failed(.providerProtocolFailure))
        }
    }

    func testProviderErrorsAreSanitizedWithoutRawPropagation() async {
        let known = await EngineFixture(
            chunks: [.connected],
            providerFailure: SanitizedFailure.modelUnavailable
        ).runToTerminal()
        XCTAssertEqual(known.last, .failed(.modelUnavailable))

        let unknown = await EngineFixture(
            chunks: [.connected],
            providerFailure: SyntheticProviderError()
        ).runToTerminal()
        XCTAssertEqual(unknown.last, .failed(.providerProtocolFailure))
    }

    func testPreflightMismatchStopsBeforePromptAndProvider() async {
        let fixture = EngineFixture(chunks: [.connected, .content("a"), .done])
        fixture.preflight.current = .success(.fixture(model: "changed-model"))

        let updates = await fixture.runToTerminal()

        XCTAssertEqual(updates, [.preparing, .failed(.destinationReconfirmationRequired)])
        XCTAssertEqual(fixture.provider.generateCount, 0)
        XCTAssertEqual(fixture.compiler.compileCount, 0)
    }

    func testInvalidPromptStopsBeforeProvider() async {
        let fixture = EngineFixture(
            chunks: [.connected, .content("a"), .done],
            template: "No selected-text marker"
        )

        let updates = await fixture.runToTerminal()

        XCTAssertEqual(updates, [.preparing, .failed(.providerProtocolFailure)])
        XCTAssertEqual(fixture.provider.generateCount, 0)
    }

    func testProviderReceivesSeparatedPromptAndExactAuthorizedDestination() async {
        let fixture = EngineFixture(chunks: [.connected, .content("ok"), .done])
        let updates = await fixture.runToTerminal()

        XCTAssertEqual(fixture.provider.generateCount, 1)
        XCTAssertEqual(fixture.compiler.compileCount, 1)
        XCTAssertEqual(fixture.provider.requests.first?.userContent, EngineFixture.sourceText)
        XCTAssertFalse(fixture.provider.requests.first?.instruction.contains(EngineFixture.sourceText) ?? true)
        XCTAssertTrue(fixture.provider.requests.first?.instruction.contains("en") ?? false)
        XCTAssertEqual(fixture.provider.requests.first?.model, fixture.destination.model)
        XCTAssertEqual(fixture.provider.requests.first?.timeouts, fixture.intent.payload.options.timeouts)
        XCTAssertEqual(fixture.provider.requests.first?.requestID, fixture.intent.requestID)
        XCTAssertEqual(fixture.provider.destinations, [fixture.destination])

        guard case .completed(let completion) = updates.last else {
            return XCTFail("expected completion")
        }
        XCTAssertEqual(completion.requestID, fixture.intent.requestID)
        XCTAssertEqual(completion.sourceText, EngineFixture.sourceText)
        XCTAssertEqual(completion.resultText, "ok")
        XCTAssertEqual(completion.presetID, fixture.intent.payload.options.preset.id)
        XCTAssertEqual(completion.sourceLanguage, .identified("en"))
        XCTAssertEqual(completion.targetLanguage, .identified("ja"))
        XCTAssertEqual(completion.providerClass, fixture.destination.privacyClass)
        await fixture.provider.waitForCloseCount(1)
        XCTAssertEqual(fixture.provider.observedCloseCount(), 1)
    }

    func testLifecycleTransitionMatrixIsClosed() throws {
        let destination = ProviderDestinationSnapshot.fixture()
        let intent = AuthorizedTranslationIntent.fixture(
            destination: destination,
            timeouts: .init(connection: .seconds(1), firstToken: .seconds(1), streamIdle: .seconds(1))
        )
        func makeLifecycle() -> TranslationLifecycle {
            TranslationLifecycle(
                requestID: intent.requestID,
                sourceText: EngineFixture.sourceText,
                presetID: intent.payload.options.preset.id,
                sourceLanguage: .identified("en"),
                targetLanguage: .identified("ja"),
                providerClass: destination.privacyClass
            )
        }

        for invalid in [TranslationChunk.content("x"), .done] {
            var lifecycle = makeLifecycle()
            XCTAssertThrowsError(try lifecycle.accept(invalid))
        }
        var waiting = makeLifecycle()
        _ = try waiting.accept(.connected)
        XCTAssertNil(try waiting.accept(.content("")))
        XCTAssertThrowsError(try waiting.accept(.connected))
        XCTAssertThrowsError(try waiting.accept(.done))

        var streaming = makeLifecycle()
        _ = try streaming.accept(.connected)
        _ = try streaming.accept(.content("x"))
        XCTAssertNil(try streaming.accept(.content("")))
        XCTAssertThrowsError(try streaming.accept(.connected))
        _ = try streaming.accept(.done)
        for invalid in [TranslationChunk.connected, .content("late"), .done] {
            XCTAssertThrowsError(try streaming.accept(invalid))
        }
    }

    func testPublicFactoryUsesInjectedProviderPreflightAndClock() async {
        let fixture = EngineFixture(chunks: [.connected, .content("factory"), .done])
        let engine = TranslationCoreFactory.makeEngine(
            provider: fixture.provider,
            preflight: fixture.preflight,
            clock: fixture.clock
        )

        let stream = await engine.translate(fixture.intent)
        var updates: [TranslationUpdate] = []
        for await update in stream { updates.append(update) }

        XCTAssertEqual(updates.last?.simple, .completed("factory"))
        XCTAssertEqual(fixture.preflight.resolveCount, 1)
        XCTAssertEqual(fixture.provider.generateCount, 1)
    }

    func testPublicFactoryRoutesCancellationRetryAndInjectedClockTimeout() async {
        let cancelFixture = EngineFixture(chunks: [], manualProvider: true)
        let cancelEngine = TranslationCoreFactory.makeEngine(provider: cancelFixture.provider, preflight: cancelFixture.preflight, clock: cancelFixture.clock)
        let cancelStream = await cancelEngine.translate(cancelFixture.intent)
        await cancelFixture.provider.waitUntilGenerated()
        await cancelEngine.cancel(cancelFixture.intent.requestID)
        let cancelled = await collect(cancelStream)
        XCTAssertEqual(cancelled.last, .cancelled)

        let retryFixture = EngineFixture(chunks: [.connected, .content("retry"), .done])
        let retryEngine = TranslationCoreFactory.makeEngine(provider: retryFixture.provider, preflight: retryFixture.preflight, clock: retryFixture.clock)
        _ = await collect(await retryEngine.translate(retryFixture.intent))
        let retried = await collect(await retryEngine.retry(retryFixture.intent.requestID))
        XCTAssertEqual(retried.last?.simple, .completed("retry"))

        let timeoutFixture = EngineFixture(chunks: [], manualProvider: true)
        let timeoutEngine = TranslationCoreFactory.makeEngine(provider: timeoutFixture.provider, preflight: timeoutFixture.preflight, clock: timeoutFixture.clock)
        let timeoutStream = await timeoutEngine.translate(timeoutFixture.intent)
        let timeoutTask = Task {
            var updates: [TranslationUpdate] = []
            for await update in timeoutStream { updates.append(update) }
            return updates
        }
        await timeoutFixture.provider.waitUntilGenerated()
        await timeoutFixture.clock.waitForSleepers(1)
        await timeoutFixture.clock.advance(by: .seconds(5))
        let timedOut = await timeoutTask.value
        XCTAssertEqual(timedOut.last, .failed(.connectionTimeout))
    }

    private func collect(_ stream: AsyncStream<TranslationUpdate>) async -> [TranslationUpdate] {
        var updates: [TranslationUpdate] = []
        for await update in stream { updates.append(update) }
        return updates
    }

    func testEngineClosesOpenProviderStreamOnCompletionAndProtocolFailure() async {
        for chunks in [
            [TranslationChunk.connected, .content("done"), .done],
            [.content("invalid-order")]
        ] {
            let fixture = EngineFixture(chunks: [], manualProvider: true)
            let stream = await fixture.engine.translate(fixture.intent)
            let collector = Task { () -> [TranslationUpdate] in
                var updates: [TranslationUpdate] = []
                for await update in stream { updates.append(update) }
                return updates
            }
            await fixture.provider.waitUntilGenerated()
            chunks.forEach { fixture.provider.yield($0) }
            let updates = await collector.value

            XCTAssertTrue(updates.last?.isTerminal ?? false)
            await fixture.provider.waitForCloseCount(1)
            XCTAssertEqual(fixture.provider.observedCloseCount(), 1)
        }
    }
}

struct SyntheticProviderError: Error {}

enum SimpleTranslationUpdate: Equatable {
    case preparing
    case connecting
    case waitingForFirstToken
    case streaming(String)
    case completed(String)
    case cancelled
    case failed(SanitizedFailure)
}

extension TranslationUpdate {
    var simple: SimpleTranslationUpdate? {
        switch self {
        case .preparing: .preparing
        case .connecting: .connecting
        case .waitingForFirstToken: .waitingForFirstToken
        case .streaming(let delta): .streaming(delta)
        case .completed(let value): .completed(value.resultText)
        case .cancelled: .cancelled
        case .failed(let failure): .failed(failure)
        }
    }
}

final class EngineFixture: @unchecked Sendable {
    static let sourceText = "Synthetic source content"

    let destination: ProviderDestinationSnapshot
    let intent: AuthorizedTranslationIntent
    let provider: EngineProviderSpy
    let preflight: EnginePreflightSpy
    let clock: ManualAppClock
    let engine: DefaultTranslationEngine
    let compiler: EngineCompilerSpy

    init(
        chunks: [TranslationChunk],
        providerFailure: Error? = nil,
        template: String = "Translate {text} from {source_language} to {target_language}.",
        timeouts: TranslationTimeoutPolicy = .init(
            connection: .seconds(5),
            firstToken: .seconds(120),
            streamIdle: .seconds(30)
        ),
        manualProvider: Bool = false
    ) {
        destination = .fixture()
        intent = .fixture(
            destination: destination,
            template: template,
            timeouts: timeouts
        )
        provider = EngineProviderSpy(
            chunks: chunks,
            failure: providerFailure,
            manual: manualProvider
        )
        preflight = EnginePreflightSpy(current: .success(destination))
        clock = ManualAppClock()
        compiler = EngineCompilerSpy()
        engine = DefaultTranslationEngine(
            provider: provider,
            preflight: preflight,
            clock: clock,
            compiler: compiler,
            languageResolver: LocalLanguageResolver(
                provider: FixedLanguageProvider()
            )
        )
    }

    func runToTerminal() async -> [TranslationUpdate] {
        let stream = await engine.translate(intent)
        var updates: [TranslationUpdate] = []
        for await update in stream {
            updates.append(update)
        }
        return updates
    }
}

struct FixedLanguageProvider: LanguageHypothesisProviding {
    func leadingHypothesis(for text: String) -> (languageCode: String, confidence: Double)? {
        ("en", 0.99)
    }
}

final class EngineCompilerSpy: PromptCompiling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var compileCount = 0

    func compile(
        _ syntax: PromptSyntaxTree,
        selectedText: String,
        source: LanguageChoice,
        target: LanguageChoice
    ) -> CompiledPrompt {
        lock.withLock { compileCount += 1 }
        return PromptCompiler().compile(
            syntax,
            selectedText: selectedText,
            source: source,
            target: target
        )
    }
}

final class EnginePreflightSpy: ProviderPreflight, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<ProviderDestinationSnapshot, SanitizedFailure>
    private(set) var resolveCount = 0

    var current: Result<ProviderDestinationSnapshot, SanitizedFailure> {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    init(current: Result<ProviderDestinationSnapshot, SanitizedFailure>) {
        stored = current
    }

    func resolveDestination(
        for configurationID: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        lock.withLock {
            resolveCount += 1
            return stored
        }
    }

    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        await resolveDestination(for: id)
    }
}

final class EngineProviderSpy: ProviderService, @unchecked Sendable {
    private let lock = NSLock()
    private let initialChunks: [TranslationChunk]
    private let initialFailure: Error?
    private var manual: Bool
    private var continuations: [AsyncThrowingStream<TranslationChunk, Error>.Continuation] = []
    private(set) var requests: [TranslationRequest] = []
    private(set) var destinations: [ProviderDestinationSnapshot] = []
    private(set) var generateCount = 0
    private(set) var closeCount = 0

    init(chunks: [TranslationChunk], failure: Error?, manual: Bool) {
        initialChunks = chunks
        initialFailure = failure
        self.manual = manual
    }

    func generate(
        _ request: TranslationRequest,
        authorizedDestination: ProviderDestinationSnapshot
    ) async -> AsyncThrowingStream<TranslationChunk, Error> {
        let pair = AsyncThrowingStream<TranslationChunk, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { self?.closeCount += 1 }
        }
        let isManual = lock.withLock {
            generateCount += 1
            requests.append(request)
            destinations.append(authorizedDestination)
            continuations.append(pair.continuation)
            return manual
        }
        if !isManual {
            initialChunks.forEach { pair.continuation.yield($0) }
            if let initialFailure {
                pair.continuation.finish(throwing: initialFailure)
            } else {
                pair.continuation.finish()
            }
        }
        return pair.stream
    }

    func waitUntilGenerated() async {
        while lock.withLock({ generateCount == 0 }) { await Task.yield() }
    }

    func waitForGenerateCount(_ expected: Int) async {
        while lock.withLock({ generateCount < expected }) { await Task.yield() }
    }

    func waitForRequest(userContent: String) async -> Int {
        while true {
            if let index = lock.withLock({ requests.firstIndex { $0.userContent == userContent } }) {
                return index
            }
            await Task.yield()
        }
    }

    func yield(_ chunk: TranslationChunk, stream index: Int = 0) {
        lock.withLock { continuations[index] }.yield(chunk)
    }

    func finish(stream index: Int = 0, throwing error: Error? = nil) {
        let continuation = lock.withLock { continuations[index] }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    func setManual(_ value: Bool) {
        lock.withLock { manual = value }
    }

    func waitForCloseCount(_ expected: Int) async {
        while lock.withLock({ closeCount < expected }) { await Task.yield() }
    }

    func observedCloseCount() -> Int {
        lock.withLock { closeCount }
    }

    func observedGenerateCount() -> Int {
        lock.withLock { generateCount }
    }
}

extension ProviderDestinationSnapshot {
    static func fixture(
        configurationID: ProviderConfigurationID = ProviderConfigurationID(),
        privacyClass: DestinationPrivacyClass = .localOnDevice,
        configurationRevision: UInt64 = 1,
        confirmationRevision: UInt64 = 1,
        origin: ProviderOrigin = ProviderOrigin(
            scheme: "http",
            host: "127.0.0.1",
            effectivePort: 11_434
        ),
        resolutionFingerprint: Set<String> = ["127.0.0.1"],
        protocolKind: ProviderProtocolKind = .ollamaNative,
        model: String = "synthetic-model"
    ) -> Self {
        .mintAfterResolution(
            configurationID: configurationID,
            privacyClass: privacyClass,
            configurationRevision: configurationRevision,
            confirmationRevision: confirmationRevision,
            origin: origin,
            resolutionFingerprint: resolutionFingerprint,
            protocolKind: protocolKind,
            model: model
        )
    }
}

extension AuthorizedTranslationIntent {
    static func fixture(
        requestID: TranslationRequestID = TranslationRequestID(),
        destination: ProviderDestinationSnapshot,
        text: String = EngineFixture.sourceText,
        template: String = "Translate {text}",
        source: LanguageChoice = .automatic,
        target: LanguageChoice = .identified("ja"),
        preset: ValidatedPromptPreset? = nil,
        timeouts: TranslationTimeoutPolicy
    ) -> Self {
        .mintAfterAuthorization(
            requestID: requestID,
            payload: AuthorizedTranslationPayload(
                text: text,
                sourceApplication: nil,
                options: TranslationOptionsSnapshot(
                    sourceLanguage: source,
                    targetLanguage: target,
                    preset: preset ?? .mintAfterPromptValidation(
                        id: PresetID(rawValue: "accurate-translation"),
                        action: .translate,
                        template: template
                    ),
                    timeouts: timeouts
                ),
                provider: destination,
                displayRect: nil
            )
        )
    }
}
