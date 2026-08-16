import CSQLite
import CryptoKit
import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class SQLiteHistoryDatabaseTests: XCTestCase {
    func testDatabaseContainsOnlyIDAndOpaqueEnvelope() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        let database = try SQLiteHistoryDatabase(fileURL: fixture.fileURL)
        let id = historyRecordID(7)
        let cipher = HistoryCipher(
            key: SymmetricKey(data: Data((0..<32).map(UInt8.init)))
        )
        let envelope = try cipher.seal(.synthetic, id: id)

        try database.insert(id: id, envelope: envelope)

        XCTAssertEqual(try database.schemaColumns(), ["id", "envelope"])
        XCTAssertEqual(try database.userVersion(), 1)
        XCTAssertFalse(try database.hasFTSTable())
        XCTAssertEqual(try database.journalMode(), "delete")
        XCTAssertEqual(try database.synchronousLevel(), 2)
        XCTAssertTrue(try database.foreignKeysEnabled())
        XCTAssertEqual(try database.fetchBatch(afterID: nil, limit: 100), [
            HistoryDatabaseRow(id: id, envelope: envelope)
        ])

        try database.close()

        let rawBytes = try Data(contentsOf: fixture.fileURL)
        for marker in HistorySynthetic.allHistoryMarkers {
            XCTAssertNil(rawBytes.range(of: Data(marker.utf8)), marker)
        }
        XCTAssertEqual(fileMode(fixture.fileURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(fileMode(fixture.fileURL), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path + "-shm"))
    }

    func testPreparedBatchFetchCapsAtOneHundredAndTransactionalDeletes() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        let database = try SQLiteHistoryDatabase(fileURL: fixture.fileURL)
        defer { try? database.close() }
        let ids = (0..<105).map(historyRecordID)

        for (index, id) in ids.enumerated() {
            try database.insert(
                id: id,
                envelope: HistoryEnvelope(
                    version: 1,
                    sealedCombined: Data([UInt8(index % 251), 0xa5])
                )
            )
        }

        let first = try database.fetchBatch(afterID: nil, limit: 1_000)
        let second = try database.fetchBatch(afterID: first.last?.id, limit: 100)
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(second.count, 5)
        XCTAssertEqual(first.map(\.id) + second.map(\.id), ids)
        XCTAssertEqual(try database.fetchBatch(afterID: nil, limit: 0), [])

        try database.deleteIDsInTransaction([ids[0], ids[50], ids[104]])
        let remaining = try fetchAll(database)
        XCTAssertEqual(remaining.count, 102)
        XCTAssertFalse(remaining.map(\.id).contains(ids[0]))
        XCTAssertFalse(remaining.map(\.id).contains(ids[50]))
        XCTAssertFalse(remaining.map(\.id).contains(ids[104]))

        try database.deleteAllInTransaction()
        XCTAssertEqual(try database.fetchBatch(afterID: nil, limit: 100), [])
    }

    func testUnexpectedVersionColumnsAndFTSRemainUnrecoverableWithoutAutoDrop() throws {
        let cases: [[String]] = [
            [
                "CREATE TABLE sentinel(value TEXT NOT NULL)"
            ],
            [
                "CREATE TABLE sentinel(value TEXT NOT NULL)",
                "PRAGMA user_version = 2"
            ],
            [
                "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL, leaked TEXT)",
                "PRAGMA user_version = 1"
            ],
            [
                "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)",
                "CREATE VIRTUAL TABLE secret_search USING fts5(content)",
                "PRAGMA user_version = 1"
            ],
            [
                "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL, leaked TEXT GENERATED ALWAYS AS (hex(envelope)) STORED)",
                "PRAGMA user_version = 1"
            ],
            [
                "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL CHECK(length(envelope) > 0))",
                "PRAGMA user_version = 1"
            ],
            [
                "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL REFERENCES records(id), envelope BLOB NOT NULL)",
                "PRAGMA user_version = 1"
            ],
            [
                "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL UNIQUE)",
                "PRAGMA user_version = 1"
            ],
            [
                "CREATE TABLE records(id TEXT COLLATE NOCASE PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)",
                "PRAGMA user_version = 1"
            ],
            [
                "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL) WITHOUT ROWID",
                "PRAGMA user_version = 1"
            ]
        ]

        for statements in cases {
            let fixture = SQLiteHistoryFixture()
            defer { fixture.remove() }
            try createRawSQLite(at: fixture.fileURL, statements: statements)
            let before = try rawSchemaSnapshot(at: fixture.fileURL)

            XCTAssertThrowsError(try SQLiteHistoryDatabase(fileURL: fixture.fileURL)) {
                error in
                XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
            }

            XCTAssertEqual(try rawSchemaSnapshot(at: fixture.fileURL), before)
        }
    }

    func testCanonicalVersionZeroSchemaIsValidatedAndUpgradedToOne() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        try createRawSQLite(at: fixture.fileURL, statements: [
            "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)"
        ])

        let database = try SQLiteHistoryDatabase(fileURL: fixture.fileURL)
        defer { try? database.close() }

        XCTAssertEqual(try database.userVersion(), 1)
        XCTAssertEqual(try database.schemaColumns(), ["id", "envelope"])
    }

    func testSymbolicLinkDatabaseIsRejectedWithoutTouchingTarget() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let target = fixture.root.appendingPathComponent("target.sqlite")
        let marker = Data([0x53, 0x41, 0x46, 0x45])
        try marker.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(try SQLiteHistoryDatabase(fileURL: fixture.fileURL)) {
            error in
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }
        XCTAssertEqual(try Data(contentsOf: target), marker)
    }

    func testSymlinkedAncestorCannotRedirectDirectoryOrDatabaseCreation() throws {
        for nestedComponents in [["AppSupport"], ["outer", "AppSupport"]] {
            let root = physicalTemporaryDirectory().appendingPathComponent(
                "GlideTranslate-T9-ancestor-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let redirected = root.appendingPathComponent("redirected", isDirectory: true)
            try FileManager.default.createDirectory(
                at: redirected,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
            let linked = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linked,
                withDestinationURL: redirected
            )
            let databaseURL = nestedComponents.reduce(linked) {
                $0.appendingPathComponent($1, isDirectory: true)
            }.appendingPathComponent("history.sqlite")

            XCTAssertThrowsError(try SQLiteHistoryDatabase(fileURL: databaseURL)) {
                error in
                XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
            }
            let redirectedLeaf = nestedComponents.reduce(redirected) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: redirectedLeaf.path)
            )
            XCTAssertEqual(fileMode(redirected), 0o755)
        }
    }

    func testPreparedInodeSubstitutionIsRejectedBeforeDatabaseMutation() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        let substitute = fixture.root.appendingPathComponent("substitute.sqlite")
        let retainedOriginal = fixture.root.appendingPathComponent("retained.sqlite")
        let canonicalStatements = [
            "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)",
            "PRAGMA user_version = 1"
        ]
        try createRawSQLite(at: fixture.fileURL, statements: canonicalStatements)
        try createRawSQLite(at: substitute, statements: canonicalStatements)
        XCTAssertEqual(chmod(substitute.path, mode_t(0o600)), 0)
        let originalBytes = try Data(contentsOf: fixture.fileURL)
        let substituteBytes = try Data(contentsOf: substitute)

        XCTAssertThrowsError(try SQLiteHistoryDatabase(
            fileURL: fixture.fileURL,
            hooks: SQLiteHistoryDatabaseHooks(beforeSQLiteOpen: {
                try FileManager.default.linkItem(
                    at: fixture.fileURL,
                    to: retainedOriginal
                )
                try FileManager.default.removeItem(at: fixture.fileURL)
                try FileManager.default.moveItem(
                    at: substitute,
                    to: fixture.fileURL
                )
            })
        )) { error in
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }

        XCTAssertEqual(try Data(contentsOf: retainedOriginal), originalBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), substituteBytes)
    }

    func testOpenedConnectionCannotBindSubstituteWhilePathReturnsToPreparedInode() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        let substitute = fixture.root.appendingPathComponent("substitute.sqlite")
        let canonicalStatements = [
            "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)",
            "PRAGMA user_version = 1"
        ]
        try createRawSQLite(at: fixture.fileURL, statements: canonicalStatements)
        try createRawSQLite(at: substitute, statements: canonicalStatements)
        XCTAssertEqual(chmod(substitute.path, mode_t(0o600)), 0)
        let originalBytes = try Data(contentsOf: fixture.fileURL)
        let substituteBytes = try Data(contentsOf: substitute)
        let unrelatedDescriptor = RetainedFileDescriptor()
        defer { unrelatedDescriptor.close() }

        XCTAssertThrowsError(try SQLiteHistoryDatabase(
            fileURL: fixture.fileURL,
            hooks: SQLiteHistoryDatabaseHooks(
                sqliteOpenPath: { requested in
                    unrelatedDescriptor.open(requested)
                    return substitute
                }
            )
        )) { error in
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: substitute), substituteBytes)
    }

    func testOversizedEnvelopeIsRejectedBeforeBlobCopy() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        let maximumEncodedEnvelopeByteCount = PrivacyStorageResourceLimits
            .historyEnvelopeEncodedBytes
        try createRawSQLite(at: fixture.fileURL, statements: [
            "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)",
            "INSERT INTO records(id, envelope) VALUES('00000000-0000-0000-0000-000000000001', zeroblob(\(maximumEncodedEnvelopeByteCount + 1)))",
            "PRAGMA user_version = 1"
        ])
        let probe = EnvelopeCopyProbe()
        let database = try SQLiteHistoryDatabase(
            fileURL: fixture.fileURL,
            hooks: SQLiteHistoryDatabaseHooks(beforeEnvelopeCopy: { count in
                probe.observe(count)
            })
        )
        defer { try? database.close() }

        XCTAssertThrowsError(try database.fetchBatch(afterID: nil, limit: 1))
        XCTAssertEqual(probe.observedCounts, [])
    }

    func testDeleteFailureRollsBackWholeTransactionAndLeavesConnectionUsable() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        let database = try SQLiteHistoryDatabase(
            fileURL: fixture.fileURL,
            hooks: SQLiteHistoryDatabaseHooks(beforeDelete: { index in
                if index == 1 { throw HistoryFailure.unrecoverable }
            })
        )
        defer { try? database.close() }
        let ids = (0..<3).map(historyRecordID)
        for id in ids {
            try database.insert(
                id: id,
                envelope: HistoryEnvelope(
                    version: 1,
                    sealedCombined: Data([0x01, 0x02])
                )
            )
        }

        XCTAssertThrowsError(try database.deleteIDsInTransaction(ids))
        XCTAssertEqual(try fetchAll(database).map(\.id), ids)
        XCTAssertFalse(try database.isTransactionActive())

        try database.deleteAllInTransaction()
        XCTAssertEqual(try database.fetchBatch(afterID: nil, limit: 100), [])
    }

    func testCloseWaitsForInFlightUseThenDoubleCloseAndPostCloseFailClosed() throws {
        let fixture = SQLiteHistoryFixture()
        defer { fixture.remove() }
        let fetchEntered = DispatchSemaphore(value: 0)
        let releaseFetch = DispatchSemaphore(value: 0)
        let database = try SQLiteHistoryDatabase(
            fileURL: fixture.fileURL,
            hooks: SQLiteHistoryDatabaseHooks(beforeFetch: {
                fetchEntered.signal()
                releaseFetch.wait()
            })
        )
        try database.insert(
            id: historyRecordID(1),
            envelope: HistoryEnvelope(
                version: 1,
                sealedCombined: Data([0x03, 0x04])
            )
        )

        let fetchSucceeded = DispatchSemaphore(value: 0)
        let fetchFailed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try database.fetchBatch(afterID: nil, limit: 100)
                fetchSucceeded.signal()
            } catch {
                fetchFailed.signal()
            }
        }
        XCTAssertEqual(fetchEntered.wait(timeout: .now() + 1), .success)

        let closeStarted = DispatchSemaphore(value: 0)
        let closeSucceeded = DispatchSemaphore(value: 0)
        let closeFailed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            closeStarted.signal()
            do {
                try database.close()
                closeSucceeded.signal()
            } catch {
                closeFailed.signal()
            }
        }
        XCTAssertEqual(closeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(closeSucceeded.wait(timeout: .now() + 0.05), .timedOut)

        releaseFetch.signal()
        XCTAssertEqual(fetchSucceeded.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(closeSucceeded.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(fetchFailed.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(closeFailed.wait(timeout: .now()), .timedOut)

        XCTAssertNoThrow(try database.close())
        XCTAssertThrowsError(
            try database.fetchBatch(afterID: nil, limit: 100)
        )
        XCTAssertThrowsError(try database.insert(
            id: historyRecordID(2),
            envelope: HistoryEnvelope(
                version: 1,
                sealedCombined: Data([0x05, 0x06])
            )
        ))
    }
}

private final class EnvelopeCopyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    var observedCounts: [Int] { lock.withLock { counts } }

    func observe(_ count: Int) {
        lock.withLock { counts.append(count) }
    }
}

private final class RetainedFileDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    func open(_ url: URL) {
        lock.withLock {
            guard descriptor < 0 else { return }
            descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

private struct SQLiteHistoryFixture {
    let root: URL
    let fileURL: URL

    init() {
        root = physicalTemporaryDirectory()
            .appendingPathComponent("GlideTranslate-T9-\(UUID().uuidString)")
        fileURL = root
            .appendingPathComponent("GlideTranslate", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func physicalTemporaryDirectory() -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    guard let resolved = Darwin.realpath(temporaryPath, nil) else {
        return FileManager.default.temporaryDirectory
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private func historyRecordID(_ value: Int) -> TranslationRecordID {
    let suffix = String(format: "%012d", value)
    return TranslationRecordID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    )
}

private func fetchAll(
    _ database: SQLiteHistoryDatabase
) throws -> [HistoryDatabaseRow] {
    var rows: [HistoryDatabaseRow] = []
    var cursor: TranslationRecordID?
    while true {
        let batch = try database.fetchBatch(afterID: cursor, limit: 100)
        rows.append(contentsOf: batch)
        guard let last = batch.last, batch.count == 100 else { return rows }
        cursor = last.id
    }
}

private func createRawSQLite(at url: URL, statements: [String]) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
        throw HistoryFailure.unrecoverable
    }
    defer { sqlite3_close(connection) }
    for statement in statements {
        guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else {
            throw HistoryFailure.unrecoverable
        }
    }
}

private struct RawSchemaSnapshot: Equatable {
    let definitions: [String]
    let userVersion: Int32
}

private func rawSchemaSnapshot(at url: URL) throws -> RawSchemaSnapshot {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let connection else {
        throw HistoryFailure.unrecoverable
    }
    defer { sqlite3_close(connection) }
    var statement: OpaquePointer?
    let sql = "SELECT type || ':' || name || ':' || COALESCE(sql,'') FROM sqlite_master ORDER BY type, name"
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw HistoryFailure.unrecoverable
    }
    defer { sqlite3_finalize(statement) }
    var definitions: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let value = sqlite3_column_text(statement, 0) else {
            throw HistoryFailure.unrecoverable
        }
        definitions.append(String(cString: value))
    }
    var versionStatement: OpaquePointer?
    guard sqlite3_prepare_v2(
        connection,
        "PRAGMA user_version",
        -1,
        &versionStatement,
        nil
    ) == SQLITE_OK, let versionStatement else {
        throw HistoryFailure.unrecoverable
    }
    defer { sqlite3_finalize(versionStatement) }
    guard sqlite3_step(versionStatement) == SQLITE_ROW else {
        throw HistoryFailure.unrecoverable
    }
    return RawSchemaSnapshot(
        definitions: definitions,
        userVersion: sqlite3_column_int(versionStatement, 0)
    )
}

private func fileMode(_ url: URL) -> mode_t {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { return 0 }
    return status.st_mode & mode_t(0o777)
}
