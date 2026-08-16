import CryptoKit
import Foundation
import SharedSupport

package protocol HistoryDatabaseAccess: Sendable {
    func insert(id: TranslationRecordID, envelope: HistoryEnvelope) throws
    func fetchBatch(
        afterID: TranslationRecordID?,
        limit: Int
    ) throws -> [HistoryDatabaseRow]
    func deleteIDsInTransaction(_ ids: [TranslationRecordID]) throws
    func deleteAllInTransaction() throws
    func close() throws
}

package protocol HistoryCiphering: Sendable {
    func seal(
        _ payload: HistoryPayload,
        id: TranslationRecordID
    ) throws -> HistoryEnvelope
    func openBatch(
        _ rows: [HistoryDatabaseRow]
    ) throws -> [DecryptedHistoryRow]
}

package struct HistoryRuntime: Sendable {
    package let database: any HistoryDatabaseAccess
    package let cipher: any HistoryCiphering

    package init(
        database: any HistoryDatabaseAccess,
        cipher: any HistoryCiphering
    ) {
        self.database = database
        self.cipher = cipher
    }
}

package protocol HistoryPersistenceOpening: Sendable {
    func withExisting<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T?
    func withWritable<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T
    func clearAll() throws
}

extension SQLiteHistoryDatabase: HistoryDatabaseAccess {}

extension HistoryCipher: HistoryCiphering {
    package func openBatch(
        _ rows: [HistoryDatabaseRow]
    ) throws -> [DecryptedHistoryRow] {
        try rows.map { row in
            DecryptedHistoryRow(
                id: row.id,
                value: try open(row.envelope, id: row.id)
            )
        }
    }
}

package final class DefaultHistoryPersistence: HistoryPersistenceOpening,
    @unchecked Sendable {
    private let fileURL: URL
    private let keyStore: HistoryKeyStore
    private let directoryIdentity: SecureStoreDirectoryIdentity?
    private let authorityLock: NSLock
    private let databaseFactory: @Sendable (URL) throws -> any HistoryDatabaseAccess

    package init(
        fileURL: URL,
        keyStore: HistoryKeyStore = HistoryKeyStore(),
        directoryIdentity: SecureStoreDirectoryIdentity? = nil,
        databaseFactory: (@Sendable (URL) throws -> any HistoryDatabaseAccess)? = nil
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.directoryIdentity = directoryIdentity
        authorityLock = HistoryAuthorityLock.shared
        self.databaseFactory = databaseFactory ?? {
            try SQLiteHistoryDatabase(
                fileURL: $0,
                directoryIdentity: directoryIdentity
            )
        }
    }

    package func withExisting<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T? {
        try authorityLock.withLock {
            do {
                let hasDatabase = try SQLiteHistoryDatabase.storeEntryExists(
                    at: fileURL,
                    directoryIdentity: directoryIdentity
                )
                guard let keyData = try keyStore.readKey() else {
                    guard !hasDatabase else { throw HistoryFailure.unrecoverable }
                    return nil
                }
                guard hasDatabase, keyData.count == 32 else {
                    throw HistoryFailure.unrecoverable
                }
                return try use(
                    makeRuntime(keyData: keyData),
                    operation: operation
                )
            } catch {
                throw HistoryFailure.unrecoverable
            }
        }
    }

    package func withWritable<T>(
        _ operation: (HistoryRuntime) throws -> T
    ) throws -> T {
        try authorityLock.withLock {
            do {
                let hasDatabase = try SQLiteHistoryDatabase.storeEntryExists(
                    at: fileURL,
                    directoryIdentity: directoryIdentity
                )
                let existingKey = try keyStore.readKey()
                if hasDatabase || existingKey != nil {
                    guard hasDatabase,
                          let existingKey,
                          existingKey.count == 32 else {
                        throw HistoryFailure.unrecoverable
                    }
                    return try use(
                        makeRuntime(keyData: existingKey),
                        operation: operation
                    )
                }

                let material = try keyStore.readOrCreateKey()
                guard material.data.count == 32 else {
                    throw HistoryFailure.unrecoverable
                }
                let runtime: HistoryRuntime
                do {
                    runtime = try makeRuntime(keyData: material.data)
                } catch {
                    if material.createdByCaller {
                        try? SQLiteHistoryDatabase.deleteStoreFiles(
                            at: fileURL,
                            directoryIdentity: directoryIdentity
                        )
                        try? keyStore.deleteKey()
                    }
                    throw HistoryFailure.unrecoverable
                }
                return try use(runtime, operation: operation)
            } catch {
                throw HistoryFailure.unrecoverable
            }
        }
    }

    package func clearAll() throws {
        try authorityLock.withLock {
            do {
                try SQLiteHistoryDatabase.deleteStoreFiles(
                    at: fileURL,
                    directoryIdentity: directoryIdentity
                )
                try keyStore.deleteKey()
            } catch {
                throw HistoryFailure.unrecoverable
            }
        }
    }

    private func makeRuntime(keyData: Data) throws -> HistoryRuntime {
        HistoryRuntime(
            database: try databaseFactory(fileURL),
            cipher: HistoryCipher(key: SymmetricKey(data: keyData))
        )
    }

    private func use<T>(
        _ runtime: HistoryRuntime,
        operation: (HistoryRuntime) throws -> T
    ) throws -> T {
        do {
            let result = try operation(runtime)
            try runtime.database.close()
            return result
        } catch {
            try? runtime.database.close()
            throw HistoryFailure.unrecoverable
        }
    }
}

private enum HistoryAuthorityLock {
    static let shared = NSLock()
}

package actor DefaultTranslationHistory: TranslationHistory {
    private static let batchLimit = 100
    private static let searchLimit = 200
    private static let previewLimit = 512
    private let preferences: any PreferencesStore
    private let clock: any AppClock
    private let persistence: any HistoryPersistenceOpening
    private var closedForReset = false
    private var operationLocked = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    package init(
        preferences: any PreferencesStore,
        clock: any AppClock,
        persistence: any HistoryPersistenceOpening
    ) {
        self.preferences = preferences
        self.clock = clock
        self.persistence = persistence
    }

    package init(
        preferences: any PreferencesStore,
        clock: any AppClock,
        fileURL: URL,
        keyStore: HistoryKeyStore = HistoryKeyStore(),
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) {
        self.init(
            preferences: preferences,
            clock: clock,
            persistence: DefaultHistoryPersistence(
                fileURL: fileURL,
                keyStore: keyStore,
                directoryIdentity: directoryIdentity
            )
        )
    }

    package func recordCompleted(
        _ completion: CompletedTranslation,
        sourceApplication: ApplicationIdentity?
    ) async throws -> HistoryWriteOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        do {
            try ensureOpen()
            let current = try await preferences.snapshot()
            guard current.historyEnabled else {
                return .skipped(.disabled)
            }
            if let sourceApplication,
               current.historyExcludedApplications.contains(sourceApplication) {
                return .skipped(.excludedApplication)
            }

            let id = TranslationRecordID()
            let payload = HistoryPayload(
                completion: completion,
                timestamp: clock.date
            )
            try persistence.withWritable { runtime in
                let envelope = try runtime.cipher.seal(payload, id: id)
                try runtime.database.insert(id: id, envelope: envelope)
            }
            try await performMaintenanceLocked()
            return .stored
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    package func search(
        _ query: HistoryQuery
    ) async throws -> [HistorySummary] {
        await acquireOperation()
        defer { releaseOperation() }
        do {
            try ensureOpen()
            guard let summaries = try persistence.withExisting({ runtime in
                var summaries: [HistorySummary] = []
                try forEachDecryptedBatch(in: runtime) { decrypted in
                for row in decrypted where matches(row.value, query: query) {
                    summaries.append(HistorySummary(
                        id: row.id,
                        timestamp: row.value.timestamp,
                        presetID: row.value.presetID,
                        sourcePreview: preview(row.value.sourceText),
                        resultPreview: preview(row.value.resultText)
                        ))
                    }
                    summaries.sort(by: summaryNewestFirst)
                    if summaries.count > Self.searchLimit {
                        summaries.removeLast(summaries.count - Self.searchLimit)
                    }
                }
                return summaries
            }) else { return [] }
            return summaries
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    package func performMaintenance() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try await performMaintenanceLocked()
    }

    private func performMaintenanceLocked() async throws {
        do {
            try ensureOpen()
            let current = try await preferences.snapshot()
            let currentDate = clock.date
            _ = try persistence.withExisting { runtime in
                var values: [HistoryRetentionValue] = []
                try forEachDecryptedBatch(in: runtime) { decrypted in
                    values.append(contentsOf: decrypted.map {
                        HistoryRetentionValue(
                            id: $0.id,
                            timestamp: $0.value.timestamp
                        )
                    })
                }
                let deletionIDs = HistoryRetention.deletionIDs(
                    from: values,
                    now: currentDate,
                    retentionDays: current.historyRetentionDays,
                    maximumCount: current.historyMaximumCount
                )
                if !deletionIDs.isEmpty {
                    try runtime.database.deleteIDsInTransaction(deletionIDs)
                }
            }
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    package func delete(_ id: TranslationRecordID) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        do {
            try ensureOpen()
            _ = try persistence.withExisting { runtime in
                try runtime.database.deleteIDsInTransaction([id])
            }
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    package func clearAll() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        do {
            try ensureOpen()
            try persistence.clearAll()
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    package func closeForReset() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        closedForReset = true
    }

    package func deleteStoreAndKeyForReset() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard closedForReset else { throw HistoryFailure.unrecoverable }
        do {
            try persistence.clearAll()
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    private func ensureOpen() throws {
        guard !closedForReset else { throw HistoryFailure.unrecoverable }
    }

    private func acquireOperation() async {
        guard operationLocked else {
            operationLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationLocked = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func forEachDecryptedBatch(
        in runtime: HistoryRuntime,
        operation: ([DecryptedHistoryRow]) throws -> Void
    ) throws {
        var cursor: TranslationRecordID?
        while true {
            let rows = try runtime.database.fetchBatch(
                afterID: cursor,
                limit: Self.batchLimit
            )
            guard !rows.isEmpty else { return }
            do {
                let decrypted = try runtime.cipher.openBatch(rows)
                guard decrypted.count == rows.count else {
                    throw HistoryFailure.unrecoverable
                }
                try operation(decrypted)
            }
            guard rows.count == Self.batchLimit,
                  let last = rows.last else { return }
            cursor = last.id
        }
    }

    private func matches(
        _ payload: HistoryPayload,
        query: HistoryQuery
    ) -> Bool {
        switch query {
        case .all:
            return true
        case .contains(let rawQuery):
            let query = normalized(rawQuery)
            return query.isEmpty
                || normalized(payload.sourceText).contains(query)
                || normalized(payload.resultText).contains(query)
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func preview(_ value: String) -> String {
        String(value.prefix(Self.previewLimit))
    }

    private func summaryNewestFirst(
        _ lhs: HistorySummary,
        _ rhs: HistorySummary
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        return HistoryRetention.databaseID(lhs.id)
            < HistoryRetention.databaseID(rhs.id)
    }
}
