import Foundation
import SharedSupport
@testable import TranslationCore
import XCTest

final class TranslationTimeoutTests: XCTestCase {
    func testEachTimeoutHasIndependentInclusiveBoundary() async {
        let rows: [(TranslationPhase, Duration, Duration, SanitizedFailure)] = [
            (.connecting, .seconds(5), .milliseconds(1), .connectionTimeout),
            (.waitingForFirstToken, .seconds(120), .milliseconds(1), .firstTokenTimeout),
            (.streaming, .seconds(30), .milliseconds(1), .streamIdleTimeout)
        ]

        for row in rows {
            let fixture = EngineFixture(
                chunks: [],
                timeouts: .init(
                    connection: .seconds(5),
                    firstToken: .seconds(120),
                    streamIdle: .seconds(30)
                ),
                manualProvider: true
            )
            let recorder = UpdateRecorder()
            let stream = await fixture.engine.translate(fixture.intent)
            let collector = Task { await recorder.consume(stream) }
            await fixture.provider.waitUntilGenerated()

            switch row.0 {
            case .connecting:
                break
            case .waitingForFirstToken:
                fixture.provider.yield(.connected)
                await recorder.waitUntilContains(.waitingForFirstToken)
            case .streaming:
                fixture.provider.yield(.connected)
                await recorder.waitUntilContains(.waitingForFirstToken)
                fixture.provider.yield(.content("a"))
                await recorder.waitUntilContains(.streaming("a"))
            case .preparing, .terminal:
                XCTFail("invalid timeout fixture phase")
            }
            await fixture.clock.waitForSleepers(1)
            await fixture.clock.advance(by: row.1 - row.2)
            let terminalBeforeBoundary = await recorder.hasTerminalUpdate
            XCTAssertFalse(terminalBeforeBoundary)
            await fixture.clock.advance(by: row.2)
            await collector.value

            let terminalUpdate = await recorder.terminalUpdate
            XCTAssertEqual(terminalUpdate, .failed(row.3))
            await fixture.provider.waitForCloseCount(1)
            XCTAssertEqual(fixture.provider.observedCloseCount(), 1)
        }
    }

    func testIdleTimerResetsOnEveryNonemptyDelta() async {
        let fixture = EngineFixture(chunks: [], manualProvider: true)
        let recorder = UpdateRecorder()
        let stream = await fixture.engine.translate(fixture.intent)
        let collector = Task { await recorder.consume(stream) }
        await fixture.provider.waitUntilGenerated()
        fixture.provider.yield(.connected)
        await recorder.waitUntilContains(.waitingForFirstToken)
        fixture.provider.yield(.content("a"))
        await recorder.waitUntilContains(.streaming("a"))
        await fixture.clock.waitForSleepers(1)

        await fixture.clock.advance(by: .seconds(29))
        fixture.provider.yield(.content("b"))
        await recorder.waitUntilContains(.streaming("b"))
        await fixture.clock.waitForSleepers(1)
        await fixture.clock.advance(by: .seconds(29))
        let terminalBeforeBoundary = await recorder.hasTerminalUpdate
        XCTAssertFalse(terminalBeforeBoundary)
        await fixture.clock.advance(by: .seconds(1))
        await collector.value

        let terminalUpdate = await recorder.terminalUpdate
        XCTAssertEqual(terminalUpdate, .failed(.streamIdleTimeout))
    }

    func testEmptyContentDoesNotStartOrResetTokenTimer() async {
        let fixture = EngineFixture(chunks: [], manualProvider: true)
        let recorder = UpdateRecorder()
        let stream = await fixture.engine.translate(fixture.intent)
        let collector = Task { await recorder.consume(stream) }
        await fixture.provider.waitUntilGenerated()
        fixture.provider.yield(.connected)
        await recorder.waitUntilContains(.waitingForFirstToken)
        await fixture.clock.waitForSleepers(1)
        await fixture.clock.advance(by: .seconds(119))
        fixture.provider.yield(.content(""))
        await fixture.clock.advance(by: .seconds(1))
        await collector.value

        let terminalUpdate = await recorder.terminalUpdate
        XCTAssertEqual(terminalUpdate, .failed(.firstTokenTimeout))
    }

    func testCancelledAndDisarmedSleepersCannotFireHandlers() async {
        let transitions: [(TranslationPhase, TranslationPhase?)] = [
            (.connecting, .waitingForFirstToken),
            (.waitingForFirstToken, .streaming),
            (.streaming, .streaming),
            (.streaming, nil)
        ]

        for transition in transitions {
            let clock = HostileAppClock()
            let controller = TimeoutController(clock: clock)
            let probe = TimeoutHandlerProbe()
            _ = await controller.arm(owner: 1, token: 1, phase: transition.0, duration: .seconds(1)) { _ in
                await probe.record("stale")
            }
            await clock.waitForSleepers(1)
            if let next = transition.1 {
                _ = await controller.arm(owner: 1, token: 2, phase: next, duration: .seconds(1)) { _ in
                    await probe.record("current")
                }
                await clock.waitForSleepers(2)
            } else {
                await controller.disarm(owner: 1)
            }

            await clock.releaseOldest()
            await Task.yield()
            let staleValues = await probe.snapshot()
            XCTAssertEqual(staleValues, [])

            if transition.1 != nil {
                await clock.releaseOldest()
                await probe.waitForCount(1)
                let currentValues = await probe.snapshot()
                XCTAssertEqual(currentValues, ["current"])
            }
        }
    }

    func testOlderOwnerCannotReclaimController() async {
        let controller = TimeoutController(clock: HostileAppClock())
        let newer = await controller.arm(owner: 2, token: 1, phase: .connecting, duration: .seconds(1)) { _ in }
        let older = await controller.arm(owner: 1, token: 2, phase: .connecting, duration: .seconds(1)) { _ in }
        XCTAssertTrue(newer)
        XCTAssertFalse(older)
        await controller.disarm(owner: 2)
    }

    func testExpiredIdleHandlerCannotTerminateAfterIdleReset() async {
        let fixture = EngineFixture(chunks: [], manualProvider: true)
        let timeout = PausedDeliveryTimeoutController()
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
        await fixture.provider.waitUntilGenerated()
        fixture.provider.yield(.connected)
        await recorder.waitUntilContains(.waitingForFirstToken)
        fixture.provider.yield(.content("a"))
        await recorder.waitUntilContains(.streaming("a"))
        await timeout.waitForArmCount(3)
        await timeout.pauseDelivery(index: 2)
        fixture.provider.yield(.content("b"))
        await recorder.waitUntilContains(.streaming("b"))
        await timeout.waitForArmCount(4)
        await timeout.releaseDelivery()
        await Task.yield()

        let beforeDone = await recorder.snapshot()
        XCTAssertFalse(beforeDone.contains(.failed(.streamIdleTimeout)))
        fixture.provider.yield(.done)
        await collector.value
        let final = await recorder.snapshot()
        XCTAssertEqual(final.last?.simple, .completed("ab"))
    }

    func testImmediateTimeoutDeliveryOccursOnceBeforeProviderCall() async {
        let fixture = EngineFixture(chunks: [], manualProvider: true)
        let engine = DefaultTranslationEngine(
            provider: fixture.provider,
            preflight: fixture.preflight,
            clock: fixture.clock,
            languageResolver: LocalLanguageResolver(provider: FixedLanguageProvider()),
            timeoutController: ImmediateDeliveryTimeoutController()
        )

        let stream = await engine.translate(fixture.intent)
        var updates: [TranslationUpdate] = []
        for await update in stream { updates.append(update) }

        XCTAssertEqual(updates.filter(\.isTerminal), [.failed(.connectionTimeout)])
        XCTAssertEqual(fixture.provider.generateCount, 0)
    }
}

private actor ImmediateDeliveryTimeoutController: TimeoutControlling {
    func arm(owner: UInt64, token: UInt64, phase: TranslationPhase, duration: Duration, handler: @escaping @Sendable (UInt64) async -> Void) async -> Bool {
        await handler(token)
        return true
    }
    func disarm(owner: UInt64) async {}
}

private actor PausedDeliveryTimeoutController: TimeoutControlling {
    private struct Entry {
        let token: UInt64
        let handler: @Sendable (UInt64) async -> Void
    }
    private var entries: [Entry] = []
    private var release: CheckedContinuation<Void, Never>?

    func arm(owner: UInt64, token: UInt64, phase: TranslationPhase, duration: Duration, handler: @escaping @Sendable (UInt64) async -> Void) async -> Bool {
        entries.append(Entry(token: token, handler: handler))
        return true
    }
    func disarm(owner: UInt64) async {}
    func waitForArmCount(_ count: Int) async { while entries.count < count { await Task.yield() } }
    func pauseDelivery(index: Int) {
        let entry = entries[index]
        Task {
            await withCheckedContinuation { self.release = $0 }
            await entry.handler(entry.token)
        }
    }
    func releaseDelivery() { release?.resume(); release = nil }
}

actor UpdateRecorder {
    private var updates: [TranslationUpdate] = []

    var hasTerminalUpdate: Bool {
        updates.contains(where: \.isTerminal)
    }

    var terminalUpdate: TranslationUpdate? {
        updates.last(where: \.isTerminal)
    }

    func consume(_ stream: AsyncStream<TranslationUpdate>) async {
        for await update in stream {
            updates.append(update)
        }
    }

    func snapshot() -> [TranslationUpdate] { updates }

    func waitUntilContains(_ expected: SimpleTranslationUpdate) async {
        while !updates.compactMap(\.simple).contains(expected) {
            await Task.yield()
        }
    }
}

actor TimeoutHandlerProbe {
    private var values: [String] = []

    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
    func waitForCount(_ count: Int) async {
        while values.count < count { await Task.yield() }
    }
}

final class HostileAppClock: AppClock, @unchecked Sendable {
    private struct Sleeper {
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let instant = ContinuousClock.now
    private var sleepers: [Sleeper] = []
    private var releasedCount = 0

    var now: ContinuousClock.Instant { instant }
    var date: Date { Date(timeIntervalSince1970: 0) }

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { sleepers.append(Sleeper(continuation: continuation)) }
            }
        } onCancel: {
            // Deliberately leave the sleeper releasable after cancellation.
        }
        lock.withLock { releasedCount += 1 }
    }

    func waitForSleepers(_ count: Int) async {
        while lock.withLock({ sleepers.count < count }) { await Task.yield() }
    }

    func releaseOldest() async {
        let expected = lock.withLock { releasedCount + 1 }
        let sleeper = lock.withLock { sleepers.removeFirst() }
        sleeper.continuation.resume()
        while lock.withLock({ releasedCount < expected }) { await Task.yield() }
    }
}

extension TranslationUpdate {
    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .preparing, .connecting, .waitingForFirstToken, .streaming:
            false
        }
    }
}
