import Carbon.HIToolbox
import Foundation
import SharedSupport
import TestSupport
import XCTest
@testable import SelectionCapture

final class ClipboardFallbackTests: XCTestCase {
    private final class PasteboardSpy: PasteboardReading, @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [Int]
        private var texts: [String?]
        private(set) var changeReads = 0
        private(set) var stringReads = 0
        private(set) var destructiveCapabilityCalls = 0

        init(changes: [Int], text: String?) {
            self.changes = changes
            texts = [text]
        }

        init(changes: [Int], texts: [String?]) {
            self.changes = changes
            self.texts = texts
        }

        var changeCount: Int {
            lock.withLock {
                changeReads += 1
                return changes.count > 1 ? changes.removeFirst() : changes[0]
            }
        }

        func stringForPlainText() -> String? {
            lock.withLock {
                stringReads += 1
                return texts.count > 1 ? texts.removeFirst() : texts[0]
            }
        }

        func readPriorItems() { lock.withLock { destructiveCapabilityCalls += 1 } }
        func readPriorTypes() { lock.withLock { destructiveCapabilityCalls += 1 } }
        func readPriorData() { lock.withLock { destructiveCapabilityCalls += 1 } }
        func clearContents() { lock.withLock { destructiveCapabilityCalls += 1 } }
        func writeObjects() { lock.withLock { destructiveCapabilityCalls += 1 } }

        var counts: (Int, Int) {
            lock.withLock { (changeReads, stringReads) }
        }

        var destructiveCount: Int {
            lock.withLock { destructiveCapabilityCalls }
        }
    }

    private final class SecureInputSpy: SecureInputReading, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool]

        init(_ values: [Bool]) { self.values = values }

        var isEnabled: Bool {
            lock.withLock {
                values.count > 1 ? values.removeFirst() : values[0]
            }
        }
    }

    private final class CopySpy: CopyRequesting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests = 0
        func requestCopy() throws { lock.withLock { requests += 1 } }
        var count: Int { lock.withLock { requests } }
    }

    private final class ClipboardFactorySpy:
        ShortcutClipboardReaderMaking, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var makes = 0
        func makeReader() -> any ShortcutClipboardReading {
            lock.withLock { makes += 1 }
            return StubClipboardReader(result: .failure(.noValidSelection))
        }
        var count: Int { lock.withLock { makes } }
    }

    private final class CommandCopyBuilderSpy:
        CommandCopyEventBuilding, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var descriptors: [CommandCopyEventDescriptor] = []
        var failAtCall: Int?

        func makeEvent(
            _ descriptor: CommandCopyEventDescriptor
        ) throws -> CommandCopyEventToken {
            try lock.withLock {
                descriptors.append(descriptor)
                if descriptors.count == failAtCall {
                    throw CopyRequestFailure.eventUnavailable
                }
                return .fixture()
            }
        }

        var snapshot: [CommandCopyEventDescriptor] {
            lock.withLock { descriptors }
        }
    }

    private final class CommandCopyPosterSpy:
        CommandCopySequencePosting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private(set) var allCallsOnMainThread = true

        func post(_ sequence: CommandCopySequence) {
            lock.withLock {
                calls += 1
                allCallsOnMainThread = allCallsOnMainThread && Thread.isMainThread
            }
        }

        var snapshot: (Int, Bool) {
            lock.withLock { (calls, allCallsOnMainThread) }
        }
    }

    func testSecureInputInitiallyEnabledPerformsNoClipboardOrCopyAccess() async {
        let pasteboard = PasteboardSpy(changes: [1], text: "synthetic")
        let copy = CopySpy()
        let reader = makeReader(
            pasteboard: pasteboard,
            secureInput: SecureInputSpy([true]),
            copy: copy,
            clock: ManualAppClock()
        )
        let outcome = await reader.readShortcutSelection()
        XCTAssertEqual(outcome.failure, .unsafeFallbackState)
        XCTAssertEqual(pasteboard.counts.0, 0)
        XCTAssertEqual(pasteboard.counts.1, 0)
        XCTAssertEqual(pasteboard.destructiveCount, 0)
        XCTAssertEqual(copy.count, 0)
    }

    func testSecureInputTransitionStopsWithoutReadingText() async {
        let clock = ManualAppClock()
        let pasteboard = PasteboardSpy(changes: [1], text: "synthetic")
        let copy = CopySpy()
        let reader = makeReader(
            pasteboard: pasteboard,
            secureInput: SecureInputSpy([false, false, true]),
            copy: copy,
            clock: clock
        )
        let task = Task { await reader.readShortcutSelection() }
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(25))
        let outcome = await task.value
        XCTAssertEqual(outcome.failure, .unsafeFallbackState)
        XCTAssertEqual(pasteboard.counts.1, 0)
        XCTAssertEqual(pasteboard.destructiveCount, 0)
        XCTAssertEqual(copy.count, 1)
    }

    func testNoChangeByDeadlineReadsNoClipboardText() async {
        let clock = ManualAppClock()
        let pasteboard = PasteboardSpy(changes: [1], text: "synthetic")
        let copy = CopySpy()
        let reader = makeReader(
            pasteboard: pasteboard,
            secureInput: SecureInputSpy([false]),
            copy: copy,
            clock: clock
        )
        let task = Task { await reader.readShortcutSelection() }
        for _ in 0..<20 {
            await clock.waitForSleepers(1)
            await clock.advance(by: .milliseconds(25))
        }
        let outcome = await task.value
        XCTAssertEqual(outcome.failure, .noValidSelection)
        XCTAssertEqual(pasteboard.counts.1, 0)
        XCTAssertEqual(pasteboard.destructiveCount, 0)
        XCTAssertEqual(copy.count, 1)
    }

    func testChangedClipboardReadsOnlyPostCopyPlainTextAndFiltersIt() async {
        for (text, expected) in [
            ("", Result<String, SelectionAuthorizationFailure>.failure(.noValidSelection)),
            ("  synthetic selection  ", .success("synthetic selection"))
        ] {
            let clock = ManualAppClock()
            let pasteboard = PasteboardSpy(changes: [1, 2, 2], text: text)
            let copy = CopySpy()
            let reader = makeReader(
                pasteboard: pasteboard,
                secureInput: SecureInputSpy([false]),
                copy: copy,
                clock: clock
            )
            let task = Task { await reader.readShortcutSelection() }
            await clock.waitForSleepers(1)
            await clock.advance(by: .milliseconds(25))
            let outcome = await task.value
            switch (outcome, expected) {
            case (.success(let captured), .success(let value)):
                XCTAssertEqual(captured.text, value)
                XCTAssertNil(captured.displayRect)
            case (.failure(let actual), .failure(let value)):
                XCTAssertEqual(actual, value)
            default:
                XCTFail("unexpected clipboard outcome")
            }
            XCTAssertEqual(pasteboard.counts.1, 1)
            XCTAssertEqual(pasteboard.destructiveCount, 0)
            XCTAssertEqual(copy.count, 1)
        }
    }

    func testLaterExternalChangeReturnsLatestObservedTextWithoutRestoration() async {
        let clock = ManualAppClock()
        let pasteboard = PasteboardSpy(
            changes: [1, 2, 3],
            texts: ["latest external value"]
        )
        let reader = makeReader(
            pasteboard: pasteboard,
            secureInput: SecureInputSpy([false]),
            copy: CopySpy(),
            clock: clock
        )
        let task = Task { await reader.readShortcutSelection() }
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(25))
        let outcome = await task.value
        guard case .success(let captured) = outcome else {
            return XCTFail("expected latest value")
        }
        XCTAssertEqual(captured.text, "latest external value")
        XCTAssertEqual(pasteboard.destructiveCount, 0)
    }

    func testSystemCopyRequesterPostsCommandCDownThenUpOnMainThread() async throws {
        let builder = CommandCopyBuilderSpy()
        let poster = CommandCopyPosterSpy()
        let requester = SystemCopyRequester(
            eventBuilder: builder,
            sequencePoster: poster
        )
        try await MainActor.run { try requester.requestCopy() }
        XCTAssertEqual(builder.snapshot, [
            .init(
                virtualKey: UInt16(kVK_ANSI_C),
                commandModified: true,
                phase: .keyDown
            ),
            .init(
                virtualKey: UInt16(kVK_ANSI_C),
                commandModified: true,
                phase: .keyUp
            )
        ])
        let snapshot = poster.snapshot
        XCTAssertEqual(snapshot.0, 1)
        XCTAssertTrue(snapshot.1)
    }

    func testSecondEventConstructionFailurePostsNoPartialSequence() async {
        let builder = CommandCopyBuilderSpy()
        builder.failAtCall = 2
        let poster = CommandCopyPosterSpy()
        let requester = SystemCopyRequester(
            eventBuilder: builder,
            sequencePoster: poster
        )
        do {
            try await MainActor.run { try requester.requestCopy() }
            XCTFail("expected construction failure")
        } catch {
            XCTAssertEqual(error as? CopyRequestFailure, .eventUnavailable)
        }
        XCTAssertEqual(builder.snapshot.count, 2)
        XCTAssertEqual(poster.snapshot.0, 0)
    }

    func testCancellationDuringWaitReadsNoClipboardText() async {
        let clock = ManualAppClock()
        let pasteboard = PasteboardSpy(changes: [1], text: "synthetic")
        let copy = CopySpy()
        let reader = makeReader(
            pasteboard: pasteboard,
            secureInput: SecureInputSpy([false]),
            copy: copy,
            clock: clock
        )
        let task = Task { await reader.readShortcutSelection() }
        await clock.waitForSleepers(1)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome.failure, .cancelled)
        XCTAssertEqual(pasteboard.counts.1, 0)
        XCTAssertEqual(pasteboard.destructiveCount, 0)
        XCTAssertEqual(copy.count, 1)
    }

    func testConcurrentReadIsRejectedWithoutASecondCopyRequest() async {
        let clock = ManualAppClock()
        let pasteboard = PasteboardSpy(changes: [1, 2, 3, 3], text: "synthetic")
        let copy = CopySpy()
        let reader = makeReader(
            pasteboard: pasteboard,
            secureInput: SecureInputSpy([false]),
            copy: copy,
            clock: clock
        )
        let first = Task { await reader.readShortcutSelection() }
        await clock.waitForSleepers(1)
        let second = Task { await reader.readShortcutSelection() }
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome.failure, .unsafeFallbackState)
        XCTAssertEqual(copy.count, 1)
        await clock.advance(by: .milliseconds(25))
        _ = await first.value
        XCTAssertEqual(copy.count, 1)
    }

    func testAutomaticAndDisabledPathsNeverConstructLazyClipboardReader() async {
        for (trigger, policy, systemResult): (
            CaptureTrigger,
            CapturePolicySnapshot,
            Result<CapturedSelection, SelectionAuthorizationFailure>
        ) in [
            (
                .mouse,
                CapturePolicySnapshot(
                    automaticCaptureEnabled: true,
                    mouseSelectionEnabled: true,
                    keyboardSelectionEnabled: false,
                    generalAllowlist: [AuthorizationFixture().app],
                    offDeviceAllowlist: [AuthorizationFixture().app],
                    clipboardFallbackEnabled: true,
                    selectionDebounceMilliseconds: 350,
                    selectionCharacterLimit: 2_000
                ),
                .failure(.unsupportedApplication)
            ),
            (
                .shortcut,
                CapturePolicySnapshot.authorizedMouse(
                    application: AuthorizationFixture().app
                ),
                .failure(.unsupportedApplication)
            )
        ] {
            let fixture = AuthorizationFixture(triggerPolicy: policy)
            fixture.systemReader.result = systemResult
            let factory = ClipboardFactorySpy()
            let lazyReader = LazyShortcutClipboardReader(factory: factory)
            let gate = DefaultSelectionAuthorizationGate(
                foregroundReader: fixture.foregroundReader,
                systemReader: fixture.systemReader,
                clipboardReader: lazyReader,
                snapshotReader: fixture.snapshotReader,
                selectionFilter: PassThroughSelectionFilter(),
                duplicateChecker: TestDuplicateChecker(),
                mintObserver: fixture.mintSpy
            )
            _ = await gate.authorizeSystemSelection(
                trigger: trigger,
                context: fixture.context,
                options: fixture.options,
                policy: policy,
                provider: fixture.expected
            )
            XCTAssertEqual(factory.count, 0)
        }
    }

    /// Controller-only V4 probe. The controller must first place a synthetic
    /// plain-text selection in the frontmost TextEdit document. The opt-in and
    /// marker are intentionally separate so an accidental invocation cannot
    /// read the pasteboard without an expected, content-free assertion target.
    func testRealSystemCharacterizationUsesControllerPreparedTextEditSelection() async throws {
        let environment = ProcessInfo.processInfo.environment
        let optInKey = "GLIDETRANSLATE_RUN_REAL_CLIPBOARD_CHARACTERIZATION"
        let markerKey = "GLIDETRANSLATE_REAL_CLIPBOARD_EXPECTED_MARKER"

        guard environment[optInKey] == "1" else {
            throw XCTSkip(
                "PLANNED_SKIP: set GLIDETRANSLATE_RUN_REAL_CLIPBOARD_CHARACTERIZATION=1 for the controller-prepared V4 run"
            )
        }
        guard let expectedMarker = environment[markerKey],
              !expectedMarker.isEmpty,
              expectedMarker.count <= 2_000,
              expectedMarker.rangeOfCharacter(from: .newlines) == nil,
              expectedMarker == expectedMarker.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ) else {
            XCTFail(
                "BLOCKED: real clipboard characterization requires a bounded single-line expected marker"
            )
            return
        }

        let reader = ClipboardSelectionReader(
            pasteboard: SystemPasteboardClient(),
            secureInput: SystemSecureInputReader(),
            copyRequester: SystemCopyRequester(),
            filter: SelectionFilter(limit: 2_000),
            clock: SystemAppClock()
        )
        let outcome = await reader.readShortcutSelection()
        guard case .success(let selection) = outcome else {
            XCTFail(
                "BLOCKED: real clipboard characterization did not produce a successful selection"
            )
            return
        }
        guard selection.text == expectedMarker else {
            XCTFail(
                "BLOCKED: real clipboard characterization marker did not match"
            )
            return
        }
    }

    private func makeReader(
        pasteboard: PasteboardSpy,
        secureInput: SecureInputSpy,
        copy: CopySpy,
        clock: ManualAppClock
    ) -> ClipboardSelectionReader {
        ClipboardSelectionReader(
            pasteboard: pasteboard,
            secureInput: secureInput,
            copyRequester: copy,
            filter: SelectionFilter(limit: 2_000),
            clock: clock
        )
    }
}

private extension Result where Success == CapturedSelection,
    Failure == SelectionAuthorizationFailure {
    var failure: SelectionAuthorizationFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
