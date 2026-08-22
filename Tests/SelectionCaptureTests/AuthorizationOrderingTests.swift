import Foundation
import SharedSupport
import TestSupport
import XCTest
@testable import SelectionCapture

final class AuthorizationOrderingTests: XCTestCase {
    private final class DiagnosticRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SelectionAXDiagnostic] = []

        var events: [SelectionAXDiagnostic] {
            lock.withLock { storage }
        }

        func record(_ event: SelectionAXDiagnostic) {
            lock.withLock { storage.append(event) }
        }
    }

    func testAllPreReadRejectionsHaveZeroSystemReadsAndZeroMints() async {
        let app = ApplicationIdentity(
            bundleIdentifier: "invalid.example.authorization",
            displayName: "Fixture"
        )
        let rows: [(String, CaptureTrigger, CapturePolicySnapshot, DestinationPrivacyClass)] = [
            ("paused mouse", .mouse, .fixture(master: false, mouseEnabled: true,
                keyboardEnabled: false, general: [app], offDevice: [app], clipboard: false), .localOnDevice),
            ("disallowed mouse", .mouse, .fixture(master: true, mouseEnabled: true,
                keyboardEnabled: false, general: [], offDevice: [app], clipboard: false), .localOnDevice),
            ("off-device denied mouse", .mouse, .fixture(master: true, mouseEnabled: true,
                keyboardEnabled: false, general: [app], offDevice: [], clipboard: false), .cloud),
            ("disabled keyboard", .keyboardSelection, .fixture(master: true, mouseEnabled: false,
                keyboardEnabled: false, general: [app], offDevice: [app], clipboard: false), .localOnDevice),
            ("paused keyboard", .keyboardSelection, .fixture(master: false, mouseEnabled: false,
                keyboardEnabled: true, general: [app], offDevice: [app], clipboard: false), .localOnDevice),
            ("unresolved shortcut", .shortcut, .fixture(master: false, mouseEnabled: false,
                keyboardEnabled: false, general: [], offDevice: [], clipboard: true), .unresolvedOrChanged)
        ]

        for (name, trigger, policy, privacyClass) in rows {
            let fixture = AuthorizationFixture(triggerPolicy: policy)
            let provider = ProviderDestinationSnapshot.fixture(
                configurationID: fixture.expected.configurationID,
                privacyClass: privacyClass
            )
            _ = await fixture.gate.authorizeSystemSelection(
                trigger: trigger,
                context: fixture.context,
                options: fixture.options,
                policy: policy,
                provider: provider
            )
            XCTAssertEqual(fixture.systemReader.count.value, 0, name)
            XCTAssertEqual(fixture.clipboardReader.count.value, 0, name)
            XCTAssertEqual(fixture.snapshotReader.count.value, 0, name)
            XCTAssertEqual(fixture.mintSpy.count.value, 0, name)
        }
    }

    func testManualSubmissionStillRevalidatesDestination() async {
        for changed in [false, true] {
            let fixture = AuthorizationFixture()
            if changed {
                fixture.snapshotReader.result = .success(
                    fixture.expected.changing(.configurationRevision)
                )
            }
            let submission = ManualTranslationSubmission(
                text: "synthetic manual text",
                options: fixture.options,
                providerConfigurationID: fixture.expected.configurationID
            )
            let result = await fixture.gate.authorizeManualSubmission(
                submission,
                policy: .init(expectedProvider: fixture.expected),
                provider: fixture.expected
            )
            XCTAssertEqual(result.isAuthorized, !changed)
            XCTAssertEqual(fixture.systemReader.count.value, 0)
            XCTAssertEqual(fixture.clipboardReader.count.value, 0)
            XCTAssertEqual(fixture.snapshotReader.count.value, 1)
            XCTAssertEqual(fixture.mintSpy.count.value, changed ? 0 : 1)
        }
    }

    func testForegroundChangeBeforeReadStopsAllSystemAndProviderReads() async {
        let base = AuthorizationFixture()
        let changed = ForegroundApplicationContext(
            application: base.app,
            processIdentifier: 43,
            activationSequence: 2
        )
        let fixture = AuthorizationFixture(foregroundResults: [.success(changed)])
        let result = await fixture.gate.authorizeSystemSelection(
            trigger: .mouse,
            context: fixture.context,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertEqual(result.failure, .foregroundApplicationChanged)
        XCTAssertEqual(fixture.systemReader.count.value, 0)
        XCTAssertEqual(fixture.snapshotReader.count.value, 0)
        XCTAssertEqual(fixture.mintSpy.count.value, 0)
    }

    func testForegroundChangeAfterReadStopsBeforeSnapshotAndMint() async {
        let base = AuthorizationFixture()
        let changed = ForegroundApplicationContext(
            application: base.app,
            processIdentifier: 43,
            activationSequence: 2
        )
        let fixture = AuthorizationFixture(
            foregroundResults: [.success(base.context), .success(changed)]
        )
        let result = await fixture.gate.authorizeSystemSelection(
            trigger: .mouse,
            context: fixture.context,
            options: fixture.options,
            policy: fixture.policy,
            provider: fixture.expected
        )
        XCTAssertEqual(result.failure, .foregroundApplicationChanged)
        XCTAssertEqual(fixture.systemReader.count.value, 1)
        XCTAssertEqual(fixture.snapshotReader.count.value, 0)
        XCTAssertEqual(fixture.mintSpy.count.value, 0)
    }

    func testCancellationDuringNonthrowingSnapshotReadCancelsReservation() async {
        let fixture = AuthorizationFixture()
        let snapshotReader = SuspendingSnapshotReader()
        let reservations = LockedCounter()
        let commits = LockedCounter()
        let cancellations = LockedCounter()
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: fixture.foregroundReader,
            systemReader: fixture.systemReader,
            clipboardReader: fixture.clipboardReader,
            snapshotReader: snapshotReader,
            selectionFilter: PassThroughSelectionFilter(),
            duplicateChecker: RecordingDuplicateChecker(
                reservations: reservations,
                commits: commits,
                cancellations: cancellations
            ),
            mintObserver: fixture.mintSpy
        )

        let task = Task {
            await gate.authorizeSystemSelection(
                trigger: .mouse,
                context: fixture.context,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
        }
        while await !snapshotReader.started { await Task.yield() }
        task.cancel()
        await snapshotReader.resume(with: .success(fixture.expected))
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(reservations.value, 1)
        XCTAssertEqual(commits.value, 0)
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertEqual(fixture.mintSpy.count.value, 0)
    }

    func testForegroundChangeDuringSnapshotReadStopsBeforeMint() async {
        let fixture = AuthorizationFixture()
        let changed = ForegroundApplicationContext(
            application: fixture.app,
            processIdentifier: 43,
            activationSequence: 2
        )
        let foreground = StubForegroundReader([
            .success(fixture.context),
            .success(fixture.context),
            .success(changed)
        ])
        let snapshot = SuspendingSnapshotReader()
        let cancellations = LockedCounter()
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: foreground,
            systemReader: fixture.systemReader,
            clipboardReader: fixture.clipboardReader,
            snapshotReader: snapshot,
            selectionFilter: PassThroughSelectionFilter(),
            duplicateChecker: RecordingDuplicateChecker(
                reservations: LockedCounter(),
                commits: LockedCounter(),
                cancellations: cancellations
            ),
            mintObserver: fixture.mintSpy
        )
        let task = Task {
            await gate.authorizeSystemSelection(
                trigger: .mouse,
                context: fixture.context,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
        }
        while await !snapshot.started { await Task.yield() }
        await snapshot.resume(with: .success(fixture.expected))
        let result = await task.value

        XCTAssertEqual(result.failure, .foregroundApplicationChanged)
        XCTAssertEqual(fixture.mintSpy.count.value, 0)
        XCTAssertEqual(cancellations.value, 1)
    }

    func testCancellationDuringSystemReadNeverEntersClipboardFallback() async {
        let fixture = AuthorizationFixture()
        let system = SuspendingSystemReader()
        let policy = CapturePolicySnapshot.fixture(
            master: false,
            mouseEnabled: false,
            keyboardEnabled: false,
            general: [],
            offDevice: [],
            clipboard: true
        )
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: fixture.foregroundReader,
            systemReader: system,
            clipboardReader: fixture.clipboardReader,
            snapshotReader: fixture.snapshotReader,
            selectionFilter: PassThroughSelectionFilter(),
            duplicateChecker: TestDuplicateChecker(),
            mintObserver: fixture.mintSpy
        )
        let task = Task {
            await gate.authorizeSystemSelection(
                trigger: .shortcut,
                context: fixture.context,
                options: fixture.options,
                policy: policy,
                provider: fixture.expected
            )
        }
        while await !system.started { await Task.yield() }
        task.cancel()
        await system.resume(with: .failure(.noValidSelection))
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(fixture.clipboardReader.count.value, 0)
        XCTAssertEqual(fixture.snapshotReader.count.value, 0)
        XCTAssertEqual(fixture.mintSpy.count.value, 0)
    }

    func testCancelledFailedSnapshotReportsCancellation() async {
        let fixture = AuthorizationFixture()
        let snapshot = SuspendingSnapshotReader()
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: fixture.foregroundReader,
            systemReader: fixture.systemReader,
            clipboardReader: fixture.clipboardReader,
            snapshotReader: snapshot,
            selectionFilter: PassThroughSelectionFilter(),
            duplicateChecker: TestDuplicateChecker(),
            mintObserver: fixture.mintSpy
        )
        let task = Task {
            await gate.authorizeSystemSelection(
                trigger: .mouse,
                context: fixture.context,
                options: fixture.options,
                policy: fixture.policy,
                provider: fixture.expected
            )
        }
        while await !snapshot.started { await Task.yield() }
        task.cancel()
        await snapshot.resume(with: .failure(.invalidProviderConfiguration))
        let result = await task.value
        XCTAssertEqual(result.failure, .cancelled)
    }

    func testManualSubmissionRequiresEveryProviderIDToMatch() async {
        let fixture = AuthorizationFixture()
        let otherID = ProviderConfigurationID()
        let submission = ManualTranslationSubmission(
            text: "synthetic manual text",
            options: fixture.options,
            providerConfigurationID: otherID
        )
        let result = await fixture.gate.authorizeManualSubmission(
            submission,
            policy: .init(expectedProvider: fixture.expected),
            provider: fixture.expected
        )
        XCTAssertEqual(result.failure, .providerChanged)
        XCTAssertEqual(fixture.snapshotReader.count.value, 0)
        XCTAssertEqual(fixture.mintSpy.count.value, 0)
    }

    func testShortcutFallbackOrdering() async {
        let success = AuthorizationFixture()
        let explicitPolicy = CapturePolicySnapshot.fixture(
            master: false, mouseEnabled: false, keyboardEnabled: false,
            general: [], offDevice: [], clipboard: true
        )
        let direct = await success.gate.authorizeSystemSelection(
            trigger: .shortcut,
            context: success.context,
            options: success.options,
            policy: explicitPolicy,
            provider: success.expected
        )
        XCTAssertTrue(direct.isAuthorized)
        XCTAssertEqual(success.clipboardReader.count.value, 0)

        let fallback = AuthorizationFixture()
        fallback.systemReader.result = .failure(.noValidSelection)
        fallback.clipboardReader.result = .success(
            CapturedSelection(text: "synthetic fallback", displayRect: nil)
        )
        let recovered = await fallback.gate.authorizeSystemSelection(
            trigger: .shortcut,
            context: fallback.context,
            options: fallback.options,
            policy: explicitPolicy,
            provider: fallback.expected
        )
        XCTAssertTrue(recovered.isAuthorized)
        XCTAssertEqual(fallback.clipboardReader.count.value, 1)

        let disabled = AuthorizationFixture()
        disabled.systemReader.result = .failure(.noValidSelection)
        let noFallbackPolicy = CapturePolicySnapshot.fixture(
            master: false, mouseEnabled: false, keyboardEnabled: false,
            general: [], offDevice: [], clipboard: false
        )
        let manual = await disabled.gate.authorizeSystemSelection(
            trigger: .shortcut,
            context: disabled.context,
            options: disabled.options,
            policy: noFallbackPolicy,
            provider: disabled.expected
        )
        XCTAssertTrue(manual.isManualInputRequired)
        XCTAssertEqual(disabled.clipboardReader.count.value, 0)
    }

    func testShortcutClipboardFallbackReportsClosedStageResult() async {
        let fixture = AuthorizationFixture()
        fixture.systemReader.result = .failure(.noValidSelection)
        let recorder = DiagnosticRecorder()
        let gate = DefaultSelectionAuthorizationGate(
            foregroundReader: fixture.foregroundReader,
            systemReader: fixture.systemReader,
            clipboardReader: fixture.clipboardReader,
            snapshotReader: fixture.snapshotReader,
            selectionFilter: PassThroughSelectionFilter(),
            duplicateChecker: TestDuplicateChecker(),
            mintObserver: fixture.mintSpy,
            diagnosticHandler: recorder.record
        )
        let policy = CapturePolicySnapshot.fixture(
            master: false,
            mouseEnabled: false,
            keyboardEnabled: false,
            general: [],
            offDevice: [],
            clipboard: true
        )

        let outcome = await gate.authorizeSystemSelection(
            trigger: .shortcut,
            context: fixture.context,
            options: fixture.options,
            policy: policy,
            provider: fixture.expected
        )

        XCTAssertTrue(outcome.isManualInputRequired)
        XCTAssertEqual(recorder.events, [
            .clipboardFallbackStarted,
            .clipboardFallbackNoValidSelection,
        ])
    }

    func testAcceptedAutomaticPathNeverUsesEnabledClipboardFallback() async {
        let fixture = AuthorizationFixture()
        let policy = CapturePolicySnapshot.fixture(
            master: true,
            mouseEnabled: true,
            keyboardEnabled: false,
            general: [fixture.app],
            offDevice: [fixture.app],
            clipboard: true
        )
        let result = await fixture.gate.authorizeSystemSelection(
            trigger: .mouse,
            context: fixture.context,
            options: fixture.options,
            policy: policy,
            provider: fixture.expected
        )
        XCTAssertTrue(result.isAuthorized)
        XCTAssertEqual(fixture.systemReader.count.value, 1)
        XCTAssertEqual(fixture.clipboardReader.count.value, 0)
    }
}
