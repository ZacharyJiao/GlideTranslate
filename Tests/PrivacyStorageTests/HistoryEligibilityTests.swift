import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class HistoryEligibilityTests: XCTestCase {
    func testEligibilityMatrixRechecksStorageOwnedStateAtAcquisition() async throws {
        let application = ApplicationIdentity(
            bundleIdentifier: "invalid.example.history-excluded",
            displayName: "History Excluded"
        )
        let rows: [(enabled: Bool, excluded: Bool, late: Bool, expected: HistoryWriteOutcome, writes: Int)] = [
            (false, false, false, .skipped(.disabled), 0),
            (true, true, false, .skipped(.excludedApplication), 0),
            (true, false, false, .stored, 1),
            (true, false, true, .skipped(.disabled), 0),
            (true, false, true, .skipped(.excludedApplication), 0)
        ]

        for (index, row) in rows.enumerated() {
            var snapshot = PreferencesSnapshot.defaultValue
            snapshot.historyEnabled = row.enabled
            if row.excluded { snapshot.historyExcludedApplications = [application] }
            let gate = row.late ? AsyncHistoryGate() : nil
            let preferences = HistoryPreferencesStub(snapshot: snapshot, gate: gate)
            let fixture = HistoryServiceFixture(preferences: preferences)

            let operation = Task {
                try await fixture.history.recordCompleted(
                    historyCompletion(index),
                    sourceApplication: application
                )
            }
            if let gate {
                let entered = await gate.waitUntilEntered()
                XCTAssertTrue(entered)
                try await preferences.update { value in
                    if index == 3 {
                        value.historyEnabled = false
                    } else {
                        value.historyExcludedApplications = [application]
                    }
                }
                await gate.open()
            }

            let outcome = try await operation.value
            XCTAssertEqual(outcome, row.expected, "row \(index)")
            XCTAssertEqual(fixture.database.insertCount, row.writes, "row \(index)")
            XCTAssertEqual(fixture.persistence.createCount, row.writes, "row \(index)")
        }
    }

    func testSourceApplicationIsUsedOnlyForEligibility() async throws {
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        let preferences = HistoryPreferencesStub(snapshot: snapshot)
        let fixture = HistoryServiceFixture(preferences: preferences)
        let application = ApplicationIdentity(
            bundleIdentifier: "invalid.example.transient-source",
            displayName: "Transient Source"
        )

        let outcome = try await fixture.history.recordCompleted(
            historyCompletion(99),
            sourceApplication: application
        )
        XCTAssertEqual(outcome, .stored)

        let payloads = fixture.cipher.payloads
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].sourceText, historyCompletion(99).sourceText)
        XCTAssertFalse(String(describing: payloads[0]).contains(application.bundleIdentifier))
        XCTAssertFalse(String(describing: payloads[0]).contains(application.displayName))
    }
}

actor AsyncHistoryGate {
    private var entered = false
    private var openState = false

    func wait() async {
        entered = true
        while !openState { await Task.yield() }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<10_000 {
            if entered { return true }
            await Task.yield()
        }
        return entered
    }

    func open() { openState = true }
}

actor HistoryPreferencesStub: PreferencesStore {
    private var value: PreferencesSnapshot
    private let gate: AsyncHistoryGate?
    private let gateSnapshot: Int
    private var snapshotCount = 0

    init(
        snapshot: PreferencesSnapshot,
        gate: AsyncHistoryGate? = nil,
        gateSnapshot: Int = 1
    ) {
        value = snapshot
        self.gate = gate
        self.gateSnapshot = gateSnapshot
    }

    func snapshot() async throws -> PreferencesSnapshot {
        snapshotCount += 1
        if snapshotCount == gateSnapshot, let gate {
            await gate.wait()
        }
        return value
    }

    func update(
        _ transform: @Sendable (inout PreferencesSnapshot) throws -> Void
    ) async throws {
        try transform(&value)
    }
}

final class HistoryTestDatabase: HistoryDatabaseAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRows: [TranslationRecordID: HistoryEnvelope] = [:]
    private var recordedDeletedIDs: [TranslationRecordID] = []
    private var recordedInsertCount = 0
    private var recordedDeleteTransactionCount = 0
    private var recordedDeleteAllCount = 0
    private var recordedCloseCount = 0

    var insertCount: Int { lock.withLock { recordedInsertCount } }
    var deletedIDs: [TranslationRecordID] { lock.withLock { recordedDeletedIDs } }
    var deleteTransactionCount: Int { lock.withLock { recordedDeleteTransactionCount } }
    var deleteAllCount: Int { lock.withLock { recordedDeleteAllCount } }
    var closeCount: Int { lock.withLock { recordedCloseCount } }
    var rowCount: Int { lock.withLock { storedRows.count } }

    func seed(id: TranslationRecordID, envelope: HistoryEnvelope) {
        lock.withLock { storedRows[id] = envelope }
    }

    func insert(id: TranslationRecordID, envelope: HistoryEnvelope) throws {
        lock.withLock {
            storedRows[id] = envelope
            recordedInsertCount += 1
        }
    }

    func fetchBatch(
        afterID: TranslationRecordID?,
        limit: Int
    ) throws -> [HistoryDatabaseRow] {
        lock.withLock {
            storedRows
                .map { HistoryDatabaseRow(id: $0.key, envelope: $0.value) }
                .sorted { historyIDString($0.id) < historyIDString($1.id) }
                .filter { row in
                    afterID.map { historyIDString(row.id) > historyIDString($0) } ?? true
                }
                .prefix(min(max(limit, 0), 100))
                .map { $0 }
        }
    }

    func deleteIDsInTransaction(_ ids: [TranslationRecordID]) throws {
        lock.withLock {
            recordedDeleteTransactionCount += 1
            recordedDeletedIDs.append(contentsOf: ids)
            ids.forEach { storedRows.removeValue(forKey: $0) }
        }
    }

    func deleteAllInTransaction() throws {
        lock.withLock {
            recordedDeleteAllCount += 1
            storedRows.removeAll()
        }
    }

    func close() throws {
        lock.withLock { recordedCloseCount += 1 }
    }
}

final class HistoryTestCipher: HistoryCiphering, @unchecked Sendable {
    enum FailureMode { case none, modifiedCiphertext, unknownVersion }

    private let lock = NSLock()
    private var nextValue: UInt64 = 1
    private var storedPayloads: [Data: HistoryPayload] = [:]
    private var recordedMaximumBatch = 0
    private var livePlaintexts = 0
    private var recordedMaximumLivePlaintexts = 0
    private var overlapDetected = false
    private var mode: FailureMode = .none

    var maximumBatchSize: Int { lock.withLock { recordedMaximumBatch } }
    var maximumLivePlaintexts: Int {
        lock.withLock { recordedMaximumLivePlaintexts }
    }
    var plaintextBuffersReleased: Bool {
        lock.withLock { livePlaintexts == 0 && !overlapDetected }
    }
    var payloads: [HistoryPayload] { lock.withLock { Array(storedPayloads.values) } }

    func setFailureMode(_ value: FailureMode) {
        lock.withLock { mode = value }
    }

    func seal(
        _ payload: HistoryPayload,
        id: TranslationRecordID
    ) throws -> HistoryEnvelope {
        lock.withLock {
            var raw = nextValue.bigEndian
            let token = Data(bytes: &raw, count: MemoryLayout<UInt64>.size)
            nextValue += 1
            storedPayloads[token] = payload
            return HistoryEnvelope(version: 1, sealedCombined: token)
        }
    }

    func openBatch(
        _ rows: [HistoryDatabaseRow]
    ) throws -> [DecryptedHistoryRow] {
        try lock.withLock {
            recordedMaximumBatch = max(recordedMaximumBatch, rows.count)
            if livePlaintexts != 0 { overlapDetected = true }
            switch mode {
            case .modifiedCiphertext, .unknownVersion:
                throw HistoryFailure.unrecoverable
            case .none:
                let opened = try rows.map { row -> (TranslationRecordID, HistoryPayload) in
                    guard row.envelope.version == 1,
                          let payload = storedPayloads[row.envelope.sealedCombined] else {
                        throw HistoryFailure.unrecoverable
                    }
                    return (row.id, payload)
                }
                livePlaintexts += rows.count
                recordedMaximumLivePlaintexts = max(
                    recordedMaximumLivePlaintexts,
                    livePlaintexts
                )
                return opened.map { id, payload in
                    return DecryptedHistoryRow(
                        id: id,
                        value: payload,
                        onRelease: { [weak self] in self?.releasePlaintext() }
                    )
                }
            }
        }
    }

    private func releasePlaintext() {
        lock.withLock { livePlaintexts -= 1 }
    }
}

final class HistoryTestPersistence: HistoryPersistenceOpening, @unchecked Sendable {
    enum OpenFailure { case none, missingKey }

    private let lock = NSLock()
    let database: HistoryTestDatabase
    let cipher: HistoryTestCipher
    private var exists: Bool
    private var failure: OpenFailure = .none
    private var recordedCreateCount = 0
    private var recordedClearCount = 0

    init(
        database: HistoryTestDatabase,
        cipher: HistoryTestCipher,
        exists: Bool = false
    ) {
        self.database = database
        self.cipher = cipher
        self.exists = exists
    }

    var createCount: Int { lock.withLock { recordedCreateCount } }
    var clearCount: Int { lock.withLock { recordedClearCount } }
    var storeExists: Bool { lock.withLock { exists } }

    func setOpenFailure(_ value: OpenFailure) { lock.withLock { failure = value } }

    func withExisting<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T? {
        try lock.withLock {
            guard failure == .none else { throw HistoryFailure.unrecoverable }
            guard exists else { return nil }
            let runtime = HistoryRuntime(database: database, cipher: cipher)
            let result = try operation(runtime)
            try database.close()
            return result
        }
    }

    func withWritable<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T {
        try lock.withLock {
            guard failure == .none else { throw HistoryFailure.unrecoverable }
            if !exists {
                exists = true
                recordedCreateCount += 1
            }
            let runtime = HistoryRuntime(database: database, cipher: cipher)
            let result = try operation(runtime)
            try database.close()
            return result
        }
    }

    func clearAll() throws {
        lock.withLock {
            exists = false
            failure = .none
            recordedClearCount += 1
        }
    }
}

struct HistoryServiceFixture {
    let database: HistoryTestDatabase
    let cipher: HistoryTestCipher
    let persistence: HistoryTestPersistence
    let history: DefaultTranslationHistory

    init(
        preferences: HistoryPreferencesStub,
        clock: any AppClock = FixedHistoryClock(date: Date(timeIntervalSince1970: 2_000_000_000)),
        exists: Bool = false
    ) {
        database = HistoryTestDatabase()
        cipher = HistoryTestCipher()
        persistence = HistoryTestPersistence(
            database: database,
            cipher: cipher,
            exists: exists
        )
        history = DefaultTranslationHistory(
            preferences: preferences,
            clock: clock,
            persistence: persistence
        )
    }

    @discardableResult
    func seed(
        index: Int,
        timestamp: Date,
        source: String? = nil,
        result: String? = nil
    ) throws -> TranslationRecordID {
        let id = historyRecordIDForT10(index)
        let completion = CompletedTranslation(
            requestID: TranslationRequestID(
                rawValue: UUID(uuidString: "10000000-0000-0000-0000-\(String(format: "%012d", index))")!
            ),
            sourceText: source ?? "source-\(index)",
            resultText: result ?? "result-\(index)",
            presetID: PresetID(rawValue: "preset-\(index % 3)"),
            sourceLanguage: .automatic,
            targetLanguage: .identified("target-\(index % 2)"),
            providerClass: .cloud
        )
        let payload = HistoryPayload(completion: completion, timestamp: timestamp)
        let envelope = try cipher.seal(payload, id: id)
        database.seed(id: id, envelope: envelope)
        return id
    }
}

struct FixedHistoryClock: AppClock {
    let date: Date
    var now: ContinuousClock.Instant { ContinuousClock.now }
    func sleep(for duration: Duration) async throws {}
}

func historyCompletion(_ index: Int) -> CompletedTranslation {
    CompletedTranslation(
        requestID: TranslationRequestID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-\(String(format: "%012d", index))")!
        ),
        sourceText: "history-source-\(index)",
        resultText: "history-result-\(index)",
        presetID: PresetID(rawValue: "preset-\(index)"),
        sourceLanguage: .automatic,
        targetLanguage: .identified("target-\(index)"),
        providerClass: .localOnDevice
    )
}

func historyRecordIDForT10(_ index: Int) -> TranslationRecordID {
    TranslationRecordID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index))")!
    )
}

func historyIDString(_ id: TranslationRecordID) -> String {
    id.rawValue.uuidString.lowercased()
}
