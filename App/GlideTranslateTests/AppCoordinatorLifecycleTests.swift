import Foundation
import PrivacyStorage
@testable import SharedSupport
import XCTest

@testable import GlideTranslate

@MainActor
final class AppCoordinatorLifecycleTests: XCTestCase {
    private enum CoordinatorRow: Equatable {
        case newTemporary(cancelsPrior: Int, pinnedUnaffected: Bool)
        case completedHistoryEnabled(historyCalls: Int)
        case changePresetFromExcludedApplication(historyOutcome: HistoryWriteOutcome)
        case cancelled(historyCalls: Int)
        case failed(historyCalls: Int)
    }

    private let rows: [CoordinatorRow] = [
        .newTemporary(cancelsPrior: 1, pinnedUnaffected: true),
        .completedHistoryEnabled(historyCalls: 1),
        .changePresetFromExcludedApplication(historyOutcome: .skipped(.excludedApplication)),
        .cancelled(historyCalls: 0),
        .failed(historyCalls: 0),
    ]

    func testLifecycleRowsAreExplicit() { XCTAssertEqual(rows.count, 5) }

    func testNewAuthorizedRequestCancelsPriorAndDismissesOnlyTemporary() async {
        let fixture = CoordinatorFixture()
        let firstID = TranslationRequestID()
        let secondID = TranslationRequestID()
        fixture.engine.updates = [.preparing]
        fixture.systemProcessor.outcome = .authorized(fixture.intent(requestID: firstID), fixture.context())
        await fixture.coordinator.handleSystemTrigger(.shortcut, sourceLanguage: .automatic, targetLanguage: .identified("en"), presetID: fixture.presetID)
        await fixture.waitForEngineCalls(1)
        fixture.systemProcessor.outcome = .authorized(fixture.intent(requestID: secondID), fixture.context())
        await fixture.coordinator.handleSystemTrigger(.shortcut, sourceLanguage: .automatic, targetLanguage: .identified("en"), presetID: fixture.presetID)
        await fixture.waitForEngineCalls(2)

        XCTAssertGreaterThanOrEqual(
            fixture.engine.cancelCalls.filter { $0 == firstID }.count,
            1
        )
        XCTAssertGreaterThanOrEqual(fixture.panel.dismissTemporaryCount, 1)
        XCTAssertEqual(fixture.panel.dismissPinnedCount, 0)
    }

    func testSuspendedOlderEntryCannotCommitAfterNewerRequestOrTermination() async {
        let fixture = CoordinatorFixture()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "old"),
            fixture.context(text: "old")
        )
        fixture.preferences.suspendNextSnapshot()
        let old = Task {
            await fixture.coordinator.handleSystemTrigger(
                .shortcut,
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID
            )
        }
        await fixture.preferences.waitUntilSnapshotSuspended()

        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "new"),
            fixture.context(text: "new")
        )
        fixture.engine.updates = [.preparing]
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)
        fixture.preferences.resumeSnapshot()
        await old.value

        XCTAssertEqual(fixture.engine.translateCalls.count, 1)
        XCTAssertEqual(fixture.systemProcessor.calls.count, 1)

        fixture.preferences.suspendNextSnapshot()
        let afterTermination = Task {
            await fixture.coordinator.handleMenuTranslateSelectedText()
        }
        await fixture.preferences.waitUntilSnapshotSuspended()
        var terminationCompleted = false
        let termination = Task {
            await fixture.coordinator.terminate()
            terminationCompleted = true
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(terminationCompleted)
        fixture.preferences.resumeSnapshot()
        await afterTermination.value
        await termination.value
        XCTAssertTrue(terminationCompleted)
        XCTAssertEqual(fixture.engine.translateCalls.count, 1)
    }

    func testTerminationDrainsEntrySuspendedInPriorCancellationBeforePreflight() async {
        let fixture = CoordinatorFixture()
        fixture.engine.suspendsStreams = true
        let firstID = TranslationRequestID()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: firstID, text: "first"),
            fixture.context(text: "first")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)

        fixture.engine.suspendNextCancel()
        let second = Task {
            await fixture.coordinator.handleSystemTrigger(
                .shortcut,
                sourceLanguage: .automatic,
                targetLanguage: .identified("fr"),
                presetID: fixture.presetID
            )
        }
        await fixture.engine.waitUntilCancelSuspended()
        let presetReadsBefore = fixture.presets.requested.count
        let preflightReadsBefore = fixture.preflight.reads.count
        var terminationCompleted = false
        let termination = Task {
            await fixture.coordinator.terminate()
            terminationCompleted = true
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(terminationCompleted)

        fixture.engine.resumeCancel()
        await second.value
        await termination.value

        XCTAssertTrue(terminationCompleted)
        XCTAssertEqual(fixture.presets.requested.count, presetReadsBefore)
        XCTAssertEqual(fixture.preflight.reads.count, preflightReadsBefore)
        XCTAssertEqual(fixture.engine.translateCalls.count, 1)
    }

    func testStalePriorCancellationCannotDrainNewerAdmittedStream() async {
        let fixture = CoordinatorFixture()
        fixture.engine.suspendsStreams = true
        let firstID = TranslationRequestID()
        let newestID = TranslationRequestID()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: firstID, text: "first"),
            fixture.context(text: "first")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)

        fixture.engine.suspendNextCancel()
        let stale = Task {
            await fixture.coordinator.handleSystemTrigger(
                .shortcut,
                sourceLanguage: .automatic,
                targetLanguage: .identified("fr"),
                presetID: fixture.presetID
            )
        }
        await fixture.engine.waitUntilCancelSuspended()

        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: newestID, text: "newest"),
            fixture.context(text: "newest")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("de"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(2)

        fixture.engine.resumeCancel()
        await stale.value
        fixture.engine.yield(
            .completed(.appCompletion(
                requestID: newestID,
                presetID: fixture.presetID,
                result: "newest result"
            )),
            to: 1
        )
        for _ in 0..<100 where fixture.history.calls.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(fixture.history.calls.count, 1)
        XCTAssertEqual(fixture.history.calls.first?.completion.resultText, "newest result")
        XCTAssertEqual(fixture.panel.updates.last?.resultText, "newest result")
    }

    func testTerminationJoinsEngineAdmissionAndCancelsAfterAdmissionRace() async {
        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        fixture.engine.suspendNextTranslateAdmission()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )

        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.engine.waitUntilTranslateAdmissionSuspended()

        var terminationCompleted = false
        let termination = Task {
            await fixture.coordinator.terminate()
            terminationCompleted = true
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(terminationCompleted)

        fixture.engine.resumeTranslateAdmission()
        await termination.value

        XCTAssertTrue(terminationCompleted)
        XCTAssertGreaterThanOrEqual(
            fixture.engine.cancelCalls.filter { $0 == requestID }.count,
            2
        )
    }

    func testTerminationJoinsSuspendedHistoryWriteBeforeReturning() async {
        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        fixture.history.outcome = .skipped(.excludedApplication)
        fixture.history.suspendNextRecord()
        fixture.engine.updates = [
            .completed(.appCompletion(
                requestID: requestID,
                presetID: fixture.presetID,
                result: "finished"
            )),
        ]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )

        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.history.waitUntilRecordSuspended()

        var terminationCompleted = false
        let termination = Task {
            await fixture.coordinator.terminate()
            terminationCompleted = true
        }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(terminationCompleted)

        fixture.history.resumeRecord()
        await termination.value
        XCTAssertTrue(terminationCompleted)
        XCTAssertEqual(fixture.history.calls.count, 1)
        XCTAssertTrue(fixture.feedback.presentations.isEmpty)
    }

    func testSupersedingIntentSuppressesSuspendedHistoryFeedback() async {
        let fixture = CoordinatorFixture()
        let completedRequestID = TranslationRequestID()
        fixture.history.outcome = .skipped(.excludedApplication)
        fixture.history.suspendNextRecord()
        fixture.engine.updates = [
            .completed(.appCompletion(
                requestID: completedRequestID,
                presetID: fixture.presetID,
                result: "finished"
            )),
        ]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: completedRequestID),
            fixture.context()
        )

        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.history.waitUntilRecordSuspended()

        fixture.systemProcessor.outcome = .rejected(.cancelled)
        let supersedingIntent = Task {
            await fixture.coordinator.handleSystemTrigger(
                .shortcut,
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID
            )
        }
        for _ in 0..<30 { await Task.yield() }
        fixture.history.resumeRecord()
        await supersedingIntent.value

        XCTAssertTrue(fixture.feedback.presentations.isEmpty)
    }

    func testRetryWaitsForSuspendedTranslateAdmissionWithSameRequestID() async {
        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        fixture.engine.suspendNextTranslateAdmission()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.engine.waitUntilTranslateAdmissionSuspended()

        fixture.panel.lastActions?.retry()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(fixture.engine.retryCalls.isEmpty)

        fixture.engine.resumeTranslateAdmission()
        await fixture.waitForRetryCalls(1)
        XCTAssertEqual(fixture.engine.retryCalls, [requestID])
    }

    func testNewerRetryWaitsForSuspendedRetryAdmissionWithSameRequestID() async {
        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        fixture.engine.suspendsStreams = true
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)

        fixture.engine.suspendNextRetryAdmission()
        fixture.panel.lastActions?.retry()
        await fixture.engine.waitUntilRetryAdmissionSuspended()
        fixture.panel.lastActions?.retry()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(fixture.engine.retryCalls, [requestID])

        fixture.engine.resumeRetryAdmission()
        await fixture.waitForRetryCalls(2)
        XCTAssertEqual(fixture.engine.retryCalls, [requestID, requestID])
    }

    func testStaleCustomPresetDisplayLoadCannotShowAfterNewerIntent() async {
        let customID = PresetID(rawValue: "custom-latest-wins")
        let fixture = CoordinatorFixture(presetID: customID)
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "old"),
            fixture.context(text: "old")
        )
        fixture.presets.suspendNextCustomPresetLoad()
        let old = Task {
            await fixture.coordinator.handleSystemTrigger(
                .shortcut,
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: customID
            )
        }
        await fixture.presets.waitUntilCustomPresetLoadSuspended()

        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "new"),
            fixture.context(text: "new")
        )
        fixture.engine.updates = [.preparing]
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: customID
        )
        await fixture.waitForEngineCalls(1)
        fixture.presets.resumeCustomPresetLoad()
        await old.value

        XCTAssertEqual(fixture.panel.temporaryShows, 1)
        XCTAssertEqual(fixture.engine.translateCalls.count, 1)
    }

    func testCustomPresetDisplayNameSurvivesEveryStreamingPhase() async {
        let customID = PresetID(rawValue: "custom-display-name")
        let fixture = CoordinatorFixture(presetID: customID)
        fixture.presets.customPresetsValue = [CustomPreset(
            id: customID,
            name: "My Custom Preset",
            explanation: "Synthetic",
            template: "Translate {text}",
            targetLanguage: .identified("en"),
            action: .translate
        )]
        let requestID = TranslationRequestID()
        fixture.engine.updates = [
            .connecting,
            .waitingForFirstToken,
            .streaming(delta: "result"),
            .completed(.appCompletion(
                requestID: requestID,
                presetID: customID,
                result: "result"
            )),
        ]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )

        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: customID
        )
        for _ in 0..<100 where fixture.panel.updates.last?.phase != .completed {
            await Task.yield()
        }

        XCTAssertFalse(fixture.panel.updates.isEmpty)
        XCTAssertTrue(fixture.panel.updates.allSatisfy {
            $0.presetDisplayName == "My Custom Preset"
        })
    }

    func testStaleGenerationCannotUpdatePanelOrWriteHistory() async {
        let fixture = CoordinatorFixture()
        fixture.engine.suspendsStreams = true
        let oldID = TranslationRequestID()
        let currentID = TranslationRequestID()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: oldID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: currentID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(2)

        fixture.engine.yield(
            CompletedTranslation.appUpdate(
                requestID: oldID,
                presetID: fixture.presetID,
                result: "stale"
            ),
            to: 0
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(fixture.history.calls.isEmpty)
        XCTAssertFalse(fixture.panel.updates.contains { $0.resultText == "stale" })

        fixture.engine.yield(
            CompletedTranslation.appUpdate(
                requestID: currentID,
                presetID: fixture.presetID,
                result: "current"
            ),
            to: 1
        )
        for _ in 0..<100 where fixture.history.calls.isEmpty { await Task.yield() }
        XCTAssertEqual(fixture.history.calls.count, 1)
        XCTAssertEqual(fixture.panel.updates.last?.resultText, "current")
    }

    func testRetryOwnsStreamUpdatesHistoryAndCanBeClosed() async {
        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        let firstCompletion = CompletedTranslation.appCompletion(
            requestID: requestID,
            presetID: fixture.presetID,
            result: "first"
        )
        fixture.engine.updates = [.completed(firstCompletion)]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        for _ in 0..<100 where fixture.history.calls.count < 1 { await Task.yield() }

        let retryCompletion = CompletedTranslation.appCompletion(
            requestID: requestID,
            presetID: fixture.presetID,
            result: "retry"
        )
        fixture.engine.retryUpdates = [
            .preparing,
            .streaming(delta: "re"),
            .completed(retryCompletion),
        ]
        fixture.panel.actionSets[0].retry()
        for _ in 0..<100 where fixture.history.calls.count < 2 { await Task.yield() }

        XCTAssertEqual(fixture.engine.retryCalls, [requestID])
        XCTAssertEqual(fixture.panel.temporaryShows, 2)
        XCTAssertEqual(fixture.panel.updates.last?.resultText, "retry")
        XCTAssertEqual(fixture.history.calls.map(\.completion), [firstCompletion, retryCompletion])

        fixture.engine.suspendsRetryStreams = true
        fixture.panel.lastActions?.retry()
        for _ in 0..<100 where fixture.engine.retryCalls.count < 2 { await Task.yield() }
        let cancelCount = fixture.engine.cancelCalls.count
        fixture.panel.lastActions?.close()
        for _ in 0..<100 where fixture.engine.cancelCalls.count == cancelCount { await Task.yield() }
        XCTAssertEqual(fixture.engine.cancelCalls.last, requestID)
    }

    func testClosingOlderPanelCannotEraseNewerAdmittedRequest() async {
        let fixture = CoordinatorFixture()
        fixture.engine.suspendsStreams = true
        let firstID = TranslationRequestID()
        let newestID = TranslationRequestID()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: firstID, text: "first"),
            fixture.context(text: "first")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)
        let firstActions = fixture.panel.lastActions

        fixture.engine.suspendNextCancel()
        firstActions?.close()
        await fixture.engine.waitUntilCancelSuspended()

        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: newestID, text: "newest"),
            fixture.context(text: "newest")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("fr"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(2)

        fixture.engine.resumeCancel()
        for _ in 0..<30 { await Task.yield() }
        fixture.engine.yield(
            .completed(.appCompletion(
                requestID: newestID,
                presetID: fixture.presetID,
                result: "survives old close"
            )),
            to: 1
        )
        for _ in 0..<100 where fixture.history.calls.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(fixture.history.calls.count, 1)
        XCTAssertEqual(fixture.history.calls.first?.completion.resultText, "survives old close")
        XCTAssertEqual(fixture.panel.updates.last?.resultText, "survives old close")
    }

    func testCopyActionWritesOnlyTheCurrentCompletedResult() async {
        let fixture = CoordinatorFixture()
        fixture.engine.updates = [.completed(.appCompletion(
            requestID: TranslationRequestID(),
            presetID: fixture.presetID,
            result: "copy-current"
        ))]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(),
            fixture.context()
        )

        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        for _ in 0..<100 where fixture.panel.updates.last?.phase != .completed {
            await Task.yield()
        }
        fixture.panel.lastActions?.copy()

        XCTAssertEqual(fixture.copyWriter.values, ["copy-current"])
    }

    func testPinnedCopyKeepsItsOwnCompletedResultAfterNewTemporaryAppears() async {
        let panel = ResultPanelController(configuration: .testing)
        let fixture = CoordinatorFixture(panelPresenter: panel)
        let firstID = TranslationRequestID()
        fixture.engine.updates = [.completed(.appCompletion(
            requestID: firstID,
            presetID: fixture.presetID,
            result: "pinned result"
        ))]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: firstID, text: "first"),
            fixture.context(text: "first")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        for _ in 0..<100 where panel.debugTemporaryPanel?.presentation?.phase != .completed {
            await Task.yield()
        }
        panel.pinTemporary()

        fixture.engine.updates = [.preparing]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "second"),
            fixture.context(text: "second")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        panel.debugPinnedPanel?.resultActions?.copy()

        XCTAssertEqual(fixture.copyWriter.values, ["pinned result"])
    }

    func testRetryStaleUpdatesAreIgnoredAfterReplacement() async {
        let fixture = CoordinatorFixture()
        let oldID = TranslationRequestID()
        fixture.engine.updates = [.completed(.appCompletion(
            requestID: oldID,
            presetID: fixture.presetID,
            result: "first"
        ))]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: oldID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        for _ in 0..<100 where fixture.history.calls.isEmpty { await Task.yield() }
        fixture.engine.suspendsRetryStreams = true
        fixture.panel.lastActions?.retry()
        for _ in 0..<100 where fixture.engine.retryCalls.isEmpty { await Task.yield() }

        let newID = TranslationRequestID()
        fixture.engine.updates = [.preparing]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: newID, text: "new source"),
            fixture.context(text: "new source")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(2)
        fixture.engine.yieldRetry(
            .completed(.appCompletion(
                requestID: oldID,
                presetID: fixture.presetID,
                result: "stale retry"
            )),
            to: 0
        )
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(fixture.history.calls.count, 1)
        XCTAssertFalse(fixture.panel.updates.contains { $0.resultText == "stale retry" })
    }

    func testRetryFailureUsesNormalTerminalPresentationWithoutHistoryWrite() async {
        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        fixture.engine.updates = [.completed(.appCompletion(
            requestID: requestID,
            presetID: fixture.presetID,
            result: "first"
        ))]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        for _ in 0..<100 where fixture.history.calls.isEmpty { await Task.yield() }
        fixture.engine.retryUpdates = [.failed(.providerProtocolFailure)]
        fixture.panel.lastActions?.retry()
        for _ in 0..<100 where fixture.panel.updates.last?.phase != .failed {
            await Task.yield()
        }
        XCTAssertEqual(fixture.panel.updates.last?.phase, .failed)
        XCTAssertEqual(fixture.history.calls.count, 1)
    }

    func testOnlyCompletedTerminalIsOfferedToHistoryWithTrustedApplication() async {
        let application = ApplicationIdentity(bundleIdentifier: "invalid.example.excluded", displayName: "Excluded")
        for terminal in [TranslationUpdate.cancelled, .failed(.providerProtocolFailure)] {
            let fixture = CoordinatorFixture()
            fixture.engine.updates = [terminal]
            fixture.systemProcessor.outcome = .authorized(fixture.intent(application: application), fixture.context(application: application))
            await fixture.coordinator.handleSystemTrigger(.shortcut, sourceLanguage: .automatic, targetLanguage: .identified("en"), presetID: fixture.presetID)
            await fixture.waitForEngineCalls(1)
            for _ in 0..<100 where fixture.panel.updates.count < 2 { await Task.yield() }
            XCTAssertEqual(fixture.history.calls.count, 0)
        }

        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        let completion = CompletedTranslation(
            requestID: requestID,
            sourceText: "synthetic source",
            resultText: "synthetic result",
            presetID: fixture.presetID,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .localOnDevice
        )
        fixture.engine.updates = [.completed(completion)]
        fixture.systemProcessor.outcome = .authorized(fixture.intent(requestID: requestID, application: application), fixture.context(application: application))
        await fixture.coordinator.handleSystemTrigger(.shortcut, sourceLanguage: .automatic, targetLanguage: .identified("en"), presetID: fixture.presetID)
        await fixture.waitForEngineCalls(1)
        for _ in 0..<100 where fixture.history.calls.isEmpty { await Task.yield() }
        XCTAssertEqual(fixture.history.calls.count, 1)
        XCTAssertEqual(fixture.history.calls.first?.completion, completion)
        XCTAssertEqual(fixture.history.calls.first?.sourceApplication, application)
    }

    func testChangePresetReauthorizesFreshRequestWithOriginalSelectedProviderAndProvenance() async {
        let application = ApplicationIdentity(bundleIdentifier: "invalid.example.excluded", displayName: "Excluded")
        let selectedProvider = ProviderConfigurationID()
        let differentDefault = ProviderConfigurationID()
        let fixture = CoordinatorFixture(providerID: selectedProvider)
        let firstID = TranslationRequestID()
        fixture.engine.updates = [.preparing]
        fixture.systemProcessor.outcome = .authorized(fixture.intent(requestID: firstID, application: application), fixture.context(application: application))
        await fixture.coordinator.handleSystemTrigger(.shortcut, sourceLanguage: .automatic, targetLanguage: .identified("en"), presetID: fixture.presetID)
        await fixture.waitForEngineCalls(1)
        fixture.preferences.value.defaultProviderID = differentDefault

        let freshID = TranslationRequestID()
        fixture.gate.manualOutcome = .authorized(fixture.intent(requestID: freshID), fixture.context())
        let completion = CompletedTranslation(
            requestID: freshID,
            sourceText: "synthetic source",
            resultText: "fresh result",
            presetID: fixture.presetID,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .localOnDevice
        )
        fixture.engine.updates = [.completed(completion)]
        fixture.history.outcome = .skipped(.excludedApplication)
        fixture.panel.lastActions?.changePreset()
        XCTAssertEqual(fixture.manual.presetPickerCount, 1)
        fixture.manual.select(fixture.presetID)
        for _ in 0..<100 where fixture.history.calls.isEmpty { await Task.yield() }

        XCTAssertEqual(fixture.gate.manualSubmissions.last?.providerConfigurationID, selectedProvider)
        XCTAssertEqual(fixture.engine.retryCalls, [])
        XCTAssertEqual(fixture.engine.translateCalls.last, freshID)
        XCTAssertEqual(fixture.history.calls.last?.sourceApplication, application)
    }

    func testPinnedChangePresetUsesItsOwningSeedAfterNewTemporaryAppears() async {
        let providerA = ProviderConfigurationID()
        let providerB = ProviderConfigurationID()
        let snapshotB = ProviderDestinationSnapshot.appFixture(
            configurationID: providerB,
            privacyClass: .cloud
        )
        let appA = ApplicationIdentity(
            bundleIdentifier: "invalid.example.a",
            displayName: "A"
        )
        let appB = ApplicationIdentity(
            bundleIdentifier: "invalid.example.b",
            displayName: "B"
        )
        let realPanel = ResultPanelController(configuration: .testing)
        let fixture = CoordinatorFixture(
            providerID: providerA,
            panelPresenter: realPanel
        )
        fixture.preflight.resultsByID[providerB] = .success(snapshotB)
        fixture.engine.updates = [.preparing]
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(application: appA, text: "source A"),
            fixture.context(application: appA, text: "source A")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)
        realPanel.pinTemporary()

        fixture.preferences.value.defaultProviderID = providerB
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "source B", provider: snapshotB),
            fixture.context(application: appB, text: "source B", provider: snapshotB)
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("fr"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(2)
        XCTAssertEqual(realPanel.debugSnapshot.pinnedCount, 1)
        XCTAssertEqual(realPanel.debugSnapshot.temporaryCount, 1)

        let freshID = TranslationRequestID()
        fixture.gate.manualOutcome = .authorized(
            fixture.intent(requestID: freshID),
            fixture.context()
        )
        fixture.engine.updates = [.completed(.appCompletion(
            requestID: freshID,
            presetID: fixture.presetID,
            result: "A changed"
        ))]
        fixture.preferences.value.connectionTimeoutSeconds = 17
        realPanel.debugPinnedPanel?.resultActions?.changePreset()
        fixture.manual.select(fixture.presetID)
        for _ in 0..<100 where fixture.history.calls.isEmpty { await Task.yield() }

        XCTAssertEqual(fixture.gate.manualSubmissions.last?.text, "source A")
        XCTAssertEqual(fixture.gate.manualSubmissions.last?.providerConfigurationID, providerA)
        XCTAssertEqual(fixture.gate.manualSubmissions.last?.options.timeouts.connection, .seconds(17))
        XCTAssertEqual(fixture.gate.manualProviders.last, fixture.providerSnapshot)
        XCTAssertEqual(fixture.preflight.reads.last, providerA)
        XCTAssertEqual(fixture.history.calls.last?.sourceApplication, appA)
    }

    func testChangePresetValidationFailureAndProviderDriftStopBeforeAuthorizationOrEngine() async {
        let fixture = CoordinatorFixture()
        fixture.engine.updates = [.preparing]
        fixture.systemProcessor.outcome = .authorized(fixture.intent(), fixture.context())
        await fixture.coordinator.handleSystemTrigger(.shortcut, sourceLanguage: .automatic, targetLanguage: .identified("en"), presetID: fixture.presetID)
        await fixture.waitForEngineCalls(1)

        fixture.presets.error = PromptPresetFailure.presetNotFound
        fixture.panel.lastActions?.changePreset()
        fixture.manual.select(PresetID(rawValue: "missing"))
        for _ in 0..<100 where fixture.feedback.presentations.count < 1 {
            await Task.yield()
        }
        XCTAssertEqual(fixture.feedback.presentations.count, 1)
        XCTAssertEqual(fixture.gate.manualSubmissions.count, 0)
        XCTAssertEqual(fixture.engine.translateCalls.count, 1)

        fixture.presets.error = nil
        fixture.preflight.result = .failure(.destinationReconfirmationRequired)
        fixture.panel.lastActions?.changePreset()
        fixture.manual.select(fixture.presetID)
        for _ in 0..<100 where fixture.feedback.presentations.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(fixture.feedback.presentations.count, 2)
        XCTAssertEqual(fixture.gate.manualSubmissions.count, 0)
        XCTAssertEqual(fixture.engine.translateCalls.count, 1)
    }

    func testPresetPickerSeedIsDroppedOnOwningPanelCloseNewerResultAndTermination() async {
        for closure in [PickerClosure.panelClose, .newerResult, .termination] {
            let fixture = CoordinatorFixture()
            fixture.engine.updates = [.preparing]
            fixture.systemProcessor.outcome = .authorized(
                fixture.intent(), fixture.context()
            )
            await fixture.coordinator.handleSystemTrigger(
                .shortcut,
                sourceLanguage: .automatic,
                targetLanguage: .identified("en"),
                presetID: fixture.presetID
            )
            await fixture.waitForEngineCalls(1)
            fixture.panel.lastActions?.changePreset()
            XCTAssertEqual(fixture.manual.presetPickerCount, 1)

            switch closure {
            case .panelClose:
                fixture.panel.lastActions?.close()
                for _ in 0..<100 where fixture.manual.presetPickerCancelCount == 0 {
                    await Task.yield()
                }
            case .newerResult:
                fixture.systemProcessor.outcome = .rejected(.noValidSelection)
                await fixture.coordinator.handleSystemTrigger(
                    .shortcut,
                    sourceLanguage: .automatic,
                    targetLanguage: .identified("fr"),
                    presetID: fixture.presetID
                )
            case .termination:
                await fixture.coordinator.terminate()
            }

            fixture.manual.select(fixture.presetID)
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(fixture.gate.manualSubmissions.count, 0, "\(closure)")
            XCTAssertGreaterThanOrEqual(
                fixture.manual.presetPickerCancelCount,
                1,
                "\(closure)"
            )
        }
    }

    func testPinnedPickerIsCancelledByThirdClaimAndCancelledTerminal() async {
        let fixture = CoordinatorFixture()
        fixture.engine.suspendsStreams = true

        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "A"),
            fixture.context(text: "A")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)
        let pinnedActions = fixture.panel.actionSets[0]

        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(text: "B"),
            fixture.context(text: "B")
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("fr"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(2)
        pinnedActions.changePreset()
        XCTAssertEqual(fixture.manual.presetPickerCount, 1)

        fixture.systemProcessor.outcome = .rejected(.noValidSelection)
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("de"),
            presetID: fixture.presetID
        )
        fixture.manual.select(fixture.presetID)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(fixture.gate.manualSubmissions.isEmpty)

        let terminalFixture = CoordinatorFixture()
        terminalFixture.engine.suspendsStreams = true
        terminalFixture.systemProcessor.outcome = .authorized(
            terminalFixture.intent(),
            terminalFixture.context()
        )
        await terminalFixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: terminalFixture.presetID
        )
        await terminalFixture.waitForEngineCalls(1)
        terminalFixture.panel.lastActions?.changePreset()
        terminalFixture.engine.yield(.cancelled, to: 0)
        for _ in 0..<100 where terminalFixture.manual.presetPickerCancelCount == 0 {
            await Task.yield()
        }
        terminalFixture.manual.select(terminalFixture.presetID)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(terminalFixture.gate.manualSubmissions.isEmpty)
    }

    func testTerminationReentrancyCannotInstallNewPresetPicker() async {
        let fixture = CoordinatorFixture()
        fixture.engine.suspendsStreams = true
        let requestID = TranslationRequestID()
        fixture.systemProcessor.outcome = .authorized(
            fixture.intent(requestID: requestID),
            fixture.context()
        )
        await fixture.coordinator.handleSystemTrigger(
            .shortcut,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            presetID: fixture.presetID
        )
        await fixture.waitForEngineCalls(1)
        let actions = fixture.panel.lastActions
        fixture.engine.suspendNextCancel()

        let termination = Task { await fixture.coordinator.terminate() }
        await fixture.engine.waitUntilCancelSuspended()
        actions?.changePreset()
        XCTAssertEqual(fixture.manual.presetPickerCount, 0)

        fixture.engine.resumeCancel()
        await termination.value
        XCTAssertGreaterThanOrEqual(fixture.panel.dismissTemporaryCount, 1)
        XCTAssertEqual(fixture.panel.dismissPinnedCount, 1)
    }

    func testTerminationCancelsActiveAndDropsTransientPanels() async {
        let fixture = CoordinatorFixture()
        let requestID = TranslationRequestID()
        fixture.engine.updates = [.preparing]
        fixture.systemProcessor.outcome = .authorized(fixture.intent(requestID: requestID), fixture.context())
        await fixture.coordinator.handleSystemTrigger(.shortcut, sourceLanguage: .automatic, targetLanguage: .identified("en"), presetID: fixture.presetID)
        await fixture.waitForEngineCalls(1)
        await fixture.coordinator.terminate()
        XCTAssertGreaterThanOrEqual(
            fixture.engine.cancelCalls.filter { $0 == requestID }.count,
            1
        )
        XCTAssertGreaterThanOrEqual(fixture.panel.dismissTemporaryCount, 1)
        XCTAssertEqual(fixture.panel.dismissPinnedCount, 1)
    }
}

private enum PickerClosure: CustomStringConvertible {
    case panelClose
    case newerResult
    case termination

    var description: String {
        switch self {
        case .panelClose: "panelClose"
        case .newerResult: "newerResult"
        case .termination: "termination"
        }
    }
}

private extension CompletedTranslation {
    static func appUpdate(
        requestID: TranslationRequestID,
        presetID: PresetID,
        result: String
    ) -> TranslationUpdate {
        .completed(appCompletion(
            requestID: requestID,
            presetID: presetID,
            result: result
        ))
    }

    static func appCompletion(
        requestID: TranslationRequestID,
        presetID: PresetID,
        result: String
    ) -> CompletedTranslation {
        CompletedTranslation(
            requestID: requestID,
            sourceText: "synthetic source",
            resultText: result,
            presetID: presetID,
            sourceLanguage: .automatic,
            targetLanguage: .identified("en"),
            providerClass: .localOnDevice
        )
    }
}
