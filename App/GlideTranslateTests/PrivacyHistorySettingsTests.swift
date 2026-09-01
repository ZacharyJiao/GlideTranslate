import AppKit
import Foundation
import PrivacyStorage
import SharedSupport
import SwiftUI
import TranslationCore
import XCTest

@testable import GlideTranslate

@MainActor
final class PrivacyHistorySettingsTests: XCTestCase {
    func testHistoryGroupsByDayAndUsesRecognizableSourceEntryTitles() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 31,
            hour: 10
        ))!
        let sameDay = calendar.date(byAdding: .hour, value: -1, to: firstDay)!
        let previousDay = calendar.date(byAdding: .day, value: -1, to: firstDay)!
        let first = SettingsHistoryRecord(
            id: TranslationRecordID(),
            timestamp: firstDay,
            presetID: PresetID(rawValue: "synthetic"),
            sourcePreview: "First source sentence. Second sentence should not lead.",
            resultPreview: "result"
        )
        let second = SettingsHistoryRecord(
            id: TranslationRecordID(),
            timestamp: sameDay,
            presetID: PresetID(rawValue: "synthetic"),
            sourcePreview: String(repeating: "leading source preview ", count: 12),
            resultPreview: "result"
        )
        let third = SettingsHistoryRecord(
            id: TranslationRecordID(),
            timestamp: previousDay,
            presetID: PresetID(rawValue: "synthetic"),
            sourcePreview: "Previous day.",
            resultPreview: "result"
        )

        let groups = HistoryView.groupedRecords(
            [second, third, first],
            calendar: calendar
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].records.map(\.id), [first.id, second.id])
        XCTAssertEqual(groups[1].records.map(\.id), [third.id])
        XCTAssertEqual(first.entryTitle, "First source sentence.")
        XCTAssertTrue(second.entryTitle.hasPrefix("leading source preview"))
        XCTAssertTrue(second.entryTitle.hasSuffix("…"))
        XCTAssertLessThanOrEqual(second.entryTitle.count, 81)
    }

    func testHistoryLayoutKeepsSidebarAndDetailWithinStableBounds() {
        XCTAssertEqual(HistoryLayout.sidebarMinimumWidth, 220)
        XCTAssertEqual(HistoryLayout.sidebarIdealWidth, 260)
        XCTAssertEqual(HistoryLayout.sidebarMaximumWidth, 320)
        XCTAssertEqual(HistoryLayout.detailMinimumWidth, 360)
        XCTAssertLessThan(
            HistoryLayout.sidebarMinimumWidth,
            HistoryLayout.sidebarIdealWidth
        )
        XCTAssertLessThan(
            HistoryLayout.sidebarIdealWidth,
            HistoryLayout.sidebarMaximumWidth
        )
    }

    func testHistoryExpandsNewestGroupAfterFirstAsyncLoad() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let newest = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 31,
            hour: 10
        ))!
        let older = calendar.date(byAdding: .day, value: -1, to: newest)!
        let records = [
            SettingsHistoryRecord(
                id: TranslationRecordID(),
                timestamp: older,
                presetID: PresetID(rawValue: "synthetic"),
                sourcePreview: "Older",
                resultPreview: "result"
            ),
            SettingsHistoryRecord(
                id: TranslationRecordID(),
                timestamp: newest,
                presetID: PresetID(rawValue: "synthetic"),
                sourcePreview: "Newest",
                resultPreview: "result"
            ),
        ]

        XCTAssertEqual(
            HistoryView.expandedDaysAfterLoad(
                current: [],
                records: records,
                calendar: calendar
            ),
            [calendar.startOfDay(for: newest)]
        )
        XCTAssertEqual(
            HistoryView.selectionAfterLoad(current: nil, records: records),
            records[1].id
        )
    }

    func testHistoryEscapeDismissesWindowAndCleansHistoryCache() async {
        let fixture = U8Fixture()
        let record = SettingsHistoryRecord(
            id: TranslationRecordID(),
            timestamp: Date(),
            presetID: PresetID(rawValue: "synthetic"),
            sourcePreview: "source",
            resultPreview: "result"
        )
        await fixture.history.setRecords([record])
        await fixture.model.openHistory()
        XCTAssertEqual(fixture.model.historyRecords, [record])

        var closeCount = 0
        let host = NSHostingView(
            rootView: HistoryView(viewModel: fixture.model) {
                closeCount += 1
            }
        )
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        let createdWindow = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        createdWindow.contentView = host
        createdWindow.makeKeyAndOrderFront(nil)
        createdWindow.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: createdWindow.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )
        if let escape {
            createdWindow.sendEvent(escape)
        }
        for _ in 0..<10 {
            await Task.yield()
            if closeCount == 1 { break }
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(fixture.model.historyRecords.isEmpty)
        createdWindow.orderOut(nil)
        createdWindow.contentView = nil
    }

    func testPrivacyHistoryRowsAreExact() {
        XCTAssertEqual(PrivacyHistorySettingsContract.rows, [
            .initial(enabled: false, recordsShown: 0),
            .enable(explainsFutureWritesAndRetention: true),
            .disable(existingRecordsRemain: true),
            .retentionBounds(minimum: 1, maximum: 365),
            .maximumCountBounds(minimum: 1, maximum: 10_000),
            .search(decryptedCachePersisted: false),
            .excludeApplication(storedInPreferencesOnly: true),
            .deleteOne(confirm: true),
            .clearAll(confirm: true),
            .unrecoverable(showsDeleteAndRestart: true, appearsEmpty: false),
            .diagnostics(previewBeforeSave: true),
            .reset(confirm: true),
        ])
    }

    func testHistoryPreferencesRoundTripAndRejectOutOfRangeWithoutWrites() async {
        let fixture = U8Fixture()
        await fixture.model.setHistoryEnabled(true)
        await fixture.model.setHistoryEnabled(false)
        await fixture.model.setHistoryRetentionDays(365)
        await fixture.model.setHistoryMaximumCount(10_000)
        let application = ApplicationIdentity(
            bundleIdentifier: "example.synthetic",
            displayName: "Synthetic"
        )
        await fixture.model.setHistoryExcludedApplications([application])
        XCTAssertFalse(fixture.model.snapshot.historyEnabled)
        XCTAssertEqual(fixture.model.snapshot.historyRetentionDays, 365)
        XCTAssertEqual(fixture.model.snapshot.historyMaximumCount, 10_000)
        XCTAssertEqual(fixture.model.snapshot.historyExcludedApplications, [application])
        let writes = await fixture.preferences.writes()

        await fixture.model.setHistoryRetentionDays(0)
        await fixture.model.setHistoryMaximumCount(10_001)
        let writesAfterInvalidValues = await fixture.preferences.writes()
        XCTAssertEqual(writesAfterInvalidValues, writes)
        XCTAssertEqual(fixture.model.safeError, .invalidValue)
    }

    func testHistoryOpenMaintainsBeforeSearchAndCacheIsMemoryOnly() async {
        let fixture = U8Fixture()
        let record = SettingsHistoryRecord(
            id: TranslationRecordID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            presetID: PresetID(rawValue: "synthetic"),
            presetDisplayName: "My Private Preset",
            sourcePreview: "source preview",
            resultPreview: "result preview"
        )
        await fixture.history.setRecords([record])

        await fixture.model.searchHistory("too early")
        let prematureEffects = await fixture.history.recordedEffects()
        XCTAssertEqual(prematureEffects, [])
        await fixture.model.openHistory()
        let openEffects = await fixture.history.recordedEffects()
        XCTAssertEqual(openEffects, [.maintenance, .search])
        XCTAssertEqual(fixture.model.historyRecords, [record])
        XCTAssertEqual(fixture.model.historyRecords.first?.presetDisplayName,
                       "My Private Preset")
        XCTAssertEqual(fixture.model.historyState, .loaded)

        fixture.model.clearHistoryViewCache()
        XCTAssertTrue(fixture.model.historyRecords.isEmpty)
        XCTAssertEqual(fixture.model.historyState, .idle)
    }

    func testDeleteClearAndUnrecoverableRecoveryAreExplicit() async {
        let fixture = U8Fixture()
        let record = SettingsHistoryRecord(
            id: TranslationRecordID(),
            timestamp: Date(),
            presetID: PresetID(rawValue: "synthetic"),
            sourcePreview: "source",
            resultPreview: "result"
        )
        await fixture.history.setRecords([record])
        await fixture.model.openHistory()
        await fixture.model.deleteHistoryRecord(record.id)
        XCTAssertTrue(fixture.model.historyRecords.isEmpty)
        await fixture.model.clearHistory()
        let destructiveEffects = await fixture.history.recordedEffects()
        XCTAssertEqual(destructiveEffects, [
            .maintenance, .search, .delete, .clear,
        ])

        let broken = U8Fixture(historyFailure: .historyUnrecoverable)
        await broken.model.openHistory()
        XCTAssertEqual(broken.model.historyState, .unrecoverable)
        await broken.model.deleteUnrecoverableHistoryAndRestart()
        XCTAssertEqual(broken.model.historyState, .deleteAndRestartCompleted)
        let recoveryEffects = await broken.history.recordedEffects()
        XCTAssertEqual(recoveryEffects, [.maintenance, .clear])
    }

    func testProductionHistoryAdapterNormalizesRealFailuresToRecoveryState() async {
        let fixture = U8Fixture(
            history: ProductionSettingsHistoryManager(history: U8FailingTranslationHistory())
        )

        await fixture.model.openHistory()

        XCTAssertEqual(fixture.model.historyState, .unrecoverable)
        XCTAssertEqual(fixture.model.safeError, .historyUnavailable)
    }

    func testDiagnosticsPreviewAndResetAreOneShotAndRefreshOnce() async {
        let cancelled = U8Fixture(diagnosticApproval: false)
        await cancelled.model.startDiagnostics()
        await cancelled.model.startDiagnostics()
        XCTAssertEqual(cancelled.diagnostics.effects, [.preview])
        XCTAssertEqual(cancelled.model.diagnosticsOutcome, .previewCancelled)

        let fixture = U8Fixture()
        XCTAssertEqual(fixture.reset.count, 0)
        XCTAssertEqual(fixture.refresh.count, 0)
        await fixture.model.confirmReset()
        await fixture.model.confirmReset()
        XCTAssertEqual(fixture.reset.count, 1)
        XCTAssertEqual(fixture.refresh.count, 1)
        XCTAssertEqual(fixture.refresh.preservedReports, [.completed])
        XCTAssertEqual(fixture.model.resetReport, .completed)
    }

    func testResetReportSurvivesReplacementFailure() async {
        let report = ResetReport.partialFailure([.deleteProviderVault])
        let fixture = U8Fixture(resetReport: report)
        fixture.refresh.failAfterReset = true

        await fixture.model.confirmReset()

        XCTAssertEqual(fixture.reset.count, 1)
        XCTAssertEqual(fixture.model.resetReport, report)
        XCTAssertEqual(fixture.model.safeError, .runtimeRefreshUnavailable)
    }

    func testResetDoesNotReadRetiredPreferencesAndInvalidatesPromptLoads() async {
        let fixture = U8Fixture()
        let custom = try! await fixture.prompts.duplicateBuiltIn(
            PresetID(rawValue: "accurate-translation")
        )
        try! await fixture.prompts.save(custom)
        await fixture.prompts.suspendNextCustomLoad()
        let load = Task { await fixture.model.loadPromptPresets() }
        await fixture.prompts.waitForSuspendedCustomLoad()
        await fixture.preferences.rejectFutureSnapshots()

        await fixture.model.confirmReset()
        await fixture.prompts.resumeCustomLoad()
        await load.value

        XCTAssertTrue(fixture.model.customPrompts.isEmpty)
        let snapshotReads = await fixture.preferences.snapshotReads()
        XCTAssertEqual(snapshotReads, 0)
        XCTAssertEqual(fixture.model.safeError, nil)
    }

}

private struct U8SyntheticHistoryError: Error {}

private actor U8FailingTranslationHistory: TranslationHistory {
    func recordCompleted(
        _ completion: CompletedTranslation,
        sourceApplication: ApplicationIdentity?
    ) async throws -> HistoryWriteOutcome { throw U8SyntheticHistoryError() }
    func search(_ query: HistoryQuery) async throws -> [HistorySummary] {
        throw U8SyntheticHistoryError()
    }
    func performMaintenance() async throws { throw U8SyntheticHistoryError() }
    func delete(_ id: TranslationRecordID) async throws { throw U8SyntheticHistoryError() }
    func clearAll() async throws { throw U8SyntheticHistoryError() }
}
