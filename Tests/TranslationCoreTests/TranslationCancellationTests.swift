import Foundation
import ModelProviders
import SharedSupport
import TestSupport
@testable import TranslationCore
import XCTest

final class TranslationCancellationTests: XCTestCase {
    func testCancellationWhilePreparingStopsBeforeProvider() async {
        let destination = ProviderDestinationSnapshot.fixture()
        let intent = AuthorizedTranslationIntent.fixture(
            destination: destination,
            timeouts: .init(connection: .seconds(5), firstToken: .seconds(120), streamIdle: .seconds(30))
        )
        let preflight = PreparingPreflightSpy()
        let provider = EngineProviderSpy(chunks: [], failure: nil, manual: true)
        let engine = DefaultTranslationEngine(
            provider: provider,
            preflight: preflight,
            clock: ManualAppClock(),
            languageResolver: LocalLanguageResolver(provider: FixedLanguageProvider())
        )
        let recorder = UpdateRecorder()
        let stream = await engine.translate(intent)
        let collector = Task { await recorder.consume(stream) }
        await preflight.waitUntilCalled()

        await engine.cancel(intent.requestID)
        preflight.resume(with: .success(destination))
        await collector.value

        let values = await recorder.snapshot()
        XCTAssertEqual(values, [.preparing, .cancelled])
        XCTAssertEqual(provider.generateCount, 0)
    }

    func testCancellationInEveryProviderPhaseClosesOnceAndSuppressesLateChunks() async {
        for phase in [TranslationPhase.connecting, .waitingForFirstToken, .streaming] {
            let fixture = EngineFixture(chunks: [], manualProvider: true)
            let recorder = UpdateRecorder()
            let stream = await fixture.engine.translate(fixture.intent)
            let collector = Task { await recorder.consume(stream) }
            await fixture.provider.waitUntilGenerated()
            if phase == .waitingForFirstToken || phase == .streaming {
                fixture.provider.yield(.connected)
                await recorder.waitUntilContains(.waitingForFirstToken)
            }
            if phase == .streaming {
                fixture.provider.yield(.content("a"))
                await recorder.waitUntilContains(.streaming("a"))
            }

            await fixture.engine.cancel(fixture.intent.requestID)
            await fixture.engine.cancel(fixture.intent.requestID)
            fixture.provider.yield(.content("late"))
            await collector.value

            let values = await recorder.snapshot()
            XCTAssertEqual(values.filter(\.isTerminal), [.cancelled])
            XCTAssertFalse(values.contains(.streaming(delta: "late")))
            await fixture.provider.waitForCloseCount(1)
            XCTAssertEqual(fixture.provider.observedCloseCount(), 1)
        }
    }

    func testNewTranslationCancelsOldAndRejectsItsLateChunks() async {
        let fixture = EngineFixture(chunks: [], manualProvider: true)
        let secondIntent = AuthorizedTranslationIntent.fixture(
            destination: fixture.destination,
            text: "Second synthetic source",
            timeouts: fixture.intent.payload.options.timeouts
        )
        let oldRecorder = UpdateRecorder()
        let newRecorder = UpdateRecorder()
        let oldStream = await fixture.engine.translate(fixture.intent)
        let oldCollector = Task { await oldRecorder.consume(oldStream) }
        await fixture.provider.waitForGenerateCount(1)
        let newStream = await fixture.engine.translate(secondIntent)
        let newCollector = Task { await newRecorder.consume(newStream) }
        await fixture.provider.waitForGenerateCount(2)

        fixture.provider.yield(.content("old"), stream: 0)
        fixture.provider.yield(.connected, stream: 1)
        fixture.provider.yield(.content("new"), stream: 1)
        fixture.provider.yield(.done, stream: 1)
        await oldCollector.value
        await newCollector.value

        let oldValues = await oldRecorder.snapshot()
        let newValues = await newRecorder.snapshot()
        XCTAssertEqual(oldValues.last, .cancelled)
        XCTAssertFalse(newValues.contains(.streaming(delta: "old")))
        XCTAssertTrue(newValues.contains(.streaming(delta: "new")))
    }

    func testCancelDuringSuspendedArmNeverCallsProvider() async {
        let fixture = EngineFixture(chunks: [], manualProvider: true)
        let timeout = BarrierTimeoutController(blockArm: true, blockFirstDisarm: false)
        let engine = DefaultTranslationEngine(
            provider: fixture.provider,
            preflight: fixture.preflight,
            clock: fixture.clock,
            languageResolver: LocalLanguageResolver(provider: FixedLanguageProvider()),
            timeoutController: timeout
        )
        let recorder = UpdateRecorder()
        let stream = await engine.translate(fixture.intent)
        let collector = Task { await recorder.consume(stream) }
        await timeout.waitForArm()

        await engine.cancel(fixture.intent.requestID)
        await timeout.releaseArm()
        await collector.value

        XCTAssertEqual(fixture.provider.generateCount, 0)
        let values = await recorder.snapshot()
        XCTAssertEqual(values.last, .cancelled)
    }

    func testConcurrentReplacementRegistersBeforeOldTimerCleanupSuspends() async {
        let fixture = EngineFixture(chunks: [], manualProvider: true)
        let timeout = BarrierTimeoutController(blockArm: false, blockFirstDisarm: true)
        let engine = DefaultTranslationEngine(
            provider: fixture.provider,
            preflight: fixture.preflight,
            clock: fixture.clock,
            languageResolver: LocalLanguageResolver(provider: FixedLanguageProvider()),
            timeoutController: timeout
        )
        let second = AuthorizedTranslationIntent.fixture(destination: fixture.destination, text: "second", timeouts: fixture.intent.payload.options.timeouts)
        let third = AuthorizedTranslationIntent.fixture(destination: fixture.destination, text: "third", timeouts: fixture.intent.payload.options.timeouts)
        let firstRecorder = UpdateRecorder()
        let secondRecorder = UpdateRecorder()
        let thirdRecorder = UpdateRecorder()
        let firstStream = await engine.translate(fixture.intent)
        let firstCollector = Task { await firstRecorder.consume(firstStream) }
        await fixture.provider.waitForGenerateCount(1)
        let secondTask = Task { await engine.translate(second) }
        await timeout.waitForBlockedDisarm()
        let thirdStream = await engine.translate(third)
        let thirdCollector = Task { await thirdRecorder.consume(thirdStream) }
        await timeout.releaseDisarm()
        let secondStream = await secondTask.value
        let secondCollector = Task { await secondRecorder.consume(secondStream) }
        let thirdIndex = await fixture.provider.waitForRequest(userContent: "third")

        fixture.provider.yield(.connected, stream: thirdIndex)
        fixture.provider.yield(.content("third"), stream: thirdIndex)
        fixture.provider.yield(.done, stream: thirdIndex)
        await firstCollector.value
        await secondCollector.value
        await thirdCollector.value

        let firstValues = await firstRecorder.snapshot()
        let secondValues = await secondRecorder.snapshot()
        let thirdValues = await thirdRecorder.snapshot()
        XCTAssertEqual(firstValues.last, .cancelled)
        XCTAssertEqual(secondValues.last, .cancelled)
        XCTAssertEqual(thirdValues.last?.simple, .completed("third"))
        XCTAssertEqual(firstValues.filter(\.isTerminal).count, 1)
        XCTAssertEqual(secondValues.filter(\.isTerminal).count, 1)
        XCTAssertEqual(thirdValues.filter(\.isTerminal).count, 1)
        await fixture.provider.waitForCloseCount(fixture.provider.observedGenerateCount())
        XCTAssertEqual(
            fixture.provider.observedCloseCount(),
            fixture.provider.observedGenerateCount()
        )
    }
}

private actor BarrierTimeoutController: TimeoutControlling {
    private let blockArm: Bool
    private let blockFirstDisarm: Bool
    private var armContinuation: CheckedContinuation<Void, Never>?
    private var disarmContinuation: CheckedContinuation<Void, Never>?
    private var armEntered = false
    private var disarmEntered = false
    private var didBlockDisarm = false

    init(blockArm: Bool, blockFirstDisarm: Bool) {
        self.blockArm = blockArm
        self.blockFirstDisarm = blockFirstDisarm
    }

    func arm(owner: UInt64, token: UInt64, phase: TranslationPhase, duration: Duration, handler: @escaping @Sendable (UInt64) async -> Void) async -> Bool {
        armEntered = true
        guard blockArm else { return true }
        await withCheckedContinuation { armContinuation = $0 }
        return true
    }

    func disarm(owner: UInt64) async {
        guard blockFirstDisarm, !didBlockDisarm else { return }
        didBlockDisarm = true
        disarmEntered = true
        await withCheckedContinuation { disarmContinuation = $0 }
    }

    func waitForArm() async { while !armEntered { await Task.yield() } }
    func waitForBlockedDisarm() async { while !disarmEntered { await Task.yield() } }
    func releaseArm() { armContinuation?.resume(); armContinuation = nil }
    func releaseDisarm() { disarmContinuation?.resume(); disarmContinuation = nil }
}

private final class PreparingPreflightSpy: ProviderPreflight, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<ProviderDestinationSnapshot, SanitizedFailure>, Never>?
    private var called = false

    func resolveDestination(
        for configurationID: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        await withCheckedContinuation { continuation in
            lock.withLock {
                called = true
                self.continuation = continuation
            }
        }
    }

    func currentSnapshot(
        for id: ProviderConfigurationID
    ) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {
        await resolveDestination(for: id)
    }

    func waitUntilCalled() async {
        while lock.withLock({ !called }) { await Task.yield() }
    }

    func resume(
        with result: Result<ProviderDestinationSnapshot, SanitizedFailure>
    ) {
        lock.withLock { continuation.take() }?.resume(returning: result)
    }
}

private extension Optional {
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
