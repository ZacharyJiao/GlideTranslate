import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class HistoryRetentionTests: XCTestCase {
    func testRetentionDecryptsBatchesAndDeletesIDsTransactionally() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        snapshot.historyRetentionDays = 30
        snapshot.historyMaximumCount = 800
        let preferences = HistoryPreferencesStub(snapshot: snapshot)
        let fixture = HistoryServiceFixture(
            preferences: preferences,
            clock: FixedHistoryClock(date: now),
            exists: true
        )
        var expectedDeleted = Set<TranslationRecordID>()

        for index in 0..<1_000 {
            let timestamp: Date
            if index < 127 {
                timestamp = now.addingTimeInterval(-31 * 86_400)
            } else {
                timestamp = now.addingTimeInterval(TimeInterval(index - 1_000))
            }
            let id = try fixture.seed(index: index, timestamp: timestamp)
            if index < 200 { expectedDeleted.insert(id) }
        }

        try await fixture.history.performMaintenance()

        XCTAssertLessThanOrEqual(fixture.cipher.maximumBatchSize, 100)
        XCTAssertLessThanOrEqual(fixture.cipher.maximumLivePlaintexts, 100)
        XCTAssertTrue(fixture.cipher.plaintextBuffersReleased)
        XCTAssertEqual(Set(fixture.database.deletedIDs), expectedDeleted)
        XCTAssertEqual(fixture.database.deleteTransactionCount, 1)
        XCTAssertEqual(fixture.database.rowCount, 800)
    }

    func testThirtyDayBoundaryIsInclusiveAndDisabledHistoryStillMaintains() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = false
        snapshot.historyRetentionDays = 30
        let fixture = HistoryServiceFixture(
            preferences: HistoryPreferencesStub(snapshot: snapshot),
            clock: FixedHistoryClock(date: now),
            exists: true
        )
        let boundary = try fixture.seed(
            index: 1,
            timestamp: now.addingTimeInterval(-30 * 86_400)
        )
        let expired = try fixture.seed(
            index: 2,
            timestamp: now.addingTimeInterval(-30 * 86_400 - 0.001)
        )

        try await fixture.history.performMaintenance()

        XCTAssertEqual(fixture.database.deletedIDs, [expired])
        XCTAssertEqual(fixture.database.rowCount, 1)
        XCTAssertNotEqual(boundary, expired)
    }

    func testMaximumCountUsesNewestTimestampThenUUIDTieBreak() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        snapshot.historyMaximumCount = 1_000
        let fixture = HistoryServiceFixture(
            preferences: HistoryPreferencesStub(snapshot: snapshot),
            clock: FixedHistoryClock(date: now),
            exists: true
        )
        for index in 0..<1_002 {
            _ = try fixture.seed(index: index, timestamp: now)
        }

        try await fixture.history.performMaintenance()

        XCTAssertEqual(
            Set(fixture.database.deletedIDs),
            Set([historyRecordIDForT10(1_000), historyRecordIDForT10(1_001)])
        )
        XCTAssertEqual(fixture.database.rowCount, 1_000)
    }

    func testSearchFoldsCaseAndDiacriticsBoundsPreviewsAndOrdersNewestFirst() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        let fixture = HistoryServiceFixture(
            preferences: HistoryPreferencesStub(snapshot: snapshot),
            clock: FixedHistoryClock(date: now),
            exists: true
        )
        for index in 0..<205 {
            _ = try fixture.seed(
                index: index,
                timestamp: now.addingTimeInterval(TimeInterval(index)),
                source: index == 204
                    ? String(repeating: "é", count: 600) + " NÉÉDLE"
                    : "NÉÉDLE source \(index)",
                result: "result \(index)"
            )
        }

        let results = try await fixture.history.search(.contains("needle"))

        XCTAssertEqual(results.count, 200)
        XCTAssertEqual(results.first?.id, historyRecordIDForT10(204))
        XCTAssertEqual(results.last?.id, historyRecordIDForT10(5))
        XCTAssertEqual(results.first?.sourcePreview.count, 512)
        XCTAssertTrue(results.allSatisfy {
            $0.sourcePreview.count <= 512 && $0.resultPreview.count <= 512
        })
        XCTAssertLessThanOrEqual(fixture.cipher.maximumBatchSize, 100)
        XCTAssertTrue(fixture.cipher.plaintextBuffersReleased)
    }

    func testSearchMatchesAndBoundsResultWithEqualTimestampUUIDOrder() async throws {
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = HistoryServiceFixture(
            preferences: HistoryPreferencesStub(snapshot: snapshot),
            clock: FixedHistoryClock(date: timestamp),
            exists: true
        )
        _ = try fixture.seed(
            index: 11,
            timestamp: timestamp,
            source: "source without match",
            result: "needle result"
        )
        _ = try fixture.seed(
            index: 10,
            timestamp: timestamp,
            source: "another source without match",
            result: String(repeating: "x", count: 600) + " needle"
        )

        let results = try await fixture.history.search(.contains("needle"))

        XCTAssertEqual(results.map(\.id), [
            historyRecordIDForT10(10), historyRecordIDForT10(11)
        ])
        XCTAssertEqual(results[0].resultPreview.count, 512)
        XCTAssertTrue(results[0].sourcePreview.contains("without match"))
        XCTAssertTrue(fixture.cipher.plaintextBuffersReleased)
    }

    func testSuccessfulRecordRereadsPreferencesAndRunsMaintenance() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        snapshot.historyRetentionDays = 365
        snapshot.historyMaximumCount = 10_000
        let gate = AsyncHistoryGate()
        let preferences = HistoryPreferencesStub(
            snapshot: snapshot,
            gate: gate,
            gateSnapshot: 2
        )
        let fixture = HistoryServiceFixture(
            preferences: preferences,
            clock: FixedHistoryClock(date: now),
            exists: true
        )
        let expired = try fixture.seed(
            index: 0,
            timestamp: now.addingTimeInterval(-31 * 86_400)
        )
        _ = try fixture.seed(index: 1, timestamp: now.addingTimeInterval(-1))
        let countExpiredA = try fixture.seed(
            index: 2,
            timestamp: now.addingTimeInterval(-2)
        )
        let countExpiredB = try fixture.seed(
            index: 3,
            timestamp: now.addingTimeInterval(-3)
        )

        let operation = Task {
            try await fixture.history.recordCompleted(
                historyCompletion(50),
                sourceApplication: nil
            )
        }
        let maintenanceEntered = await gate.waitUntilEntered()
        XCTAssertTrue(maintenanceEntered)
        try await preferences.update {
            $0.historyRetentionDays = 30
            $0.historyMaximumCount = 2
        }
        await gate.open()

        let outcome = try await operation.value
        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(Set(fixture.database.deletedIDs), Set([
            expired, countExpiredA, countExpiredB
        ]))
        XCTAssertEqual(fixture.database.deleteTransactionCount, 1)
        XCTAssertEqual(fixture.database.rowCount, 2)
    }

    func testSingleDeleteClearAllAndEmptySearchDoNotRecreateStorage() async throws {
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        let fixture = HistoryServiceFixture(
            preferences: HistoryPreferencesStub(snapshot: snapshot),
            exists: true
        )
        let first = try fixture.seed(index: 1, timestamp: Date())
        _ = try fixture.seed(index: 2, timestamp: Date())

        try await fixture.history.delete(first)
        XCTAssertEqual(fixture.database.deletedIDs, [first])
        XCTAssertEqual(fixture.database.deleteTransactionCount, 1)

        try await fixture.history.clearAll()
        XCTAssertEqual(fixture.persistence.clearCount, 1)
        XCTAssertFalse(fixture.persistence.storeExists)
        let results = try await fixture.history.search(.all)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(fixture.persistence.createCount, 0)
    }
}
