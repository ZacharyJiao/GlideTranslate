import CSQLite
import Darwin
import Foundation
import SharedSupport
import XCTest

@testable import PrivacyStorage

final class HistoryRecoveryTests: XCTestCase {
    func testCorruptionNeverAppearsAsEmptyAndExplicitClearDoesNotDecrypt() async throws {
        for corruption in 0..<3 {
            var snapshot = PreferencesSnapshot.defaultValue
            snapshot.historyEnabled = true
            let fixture = HistoryServiceFixture(
                preferences: HistoryPreferencesStub(snapshot: snapshot),
                exists: true
            )
            _ = try fixture.seed(index: corruption, timestamp: Date())
            switch corruption {
            case 0:
                fixture.persistence.setOpenFailure(.missingKey)
            case 1:
                fixture.cipher.setFailureMode(.modifiedCiphertext)
            default:
                fixture.cipher.setFailureMode(.unknownVersion)
            }

            do {
                _ = try await fixture.history.search(.all)
                XCTFail("Expected unrecoverable corruption \(corruption)")
            } catch {
                XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
            }
            XCTAssertEqual(fixture.database.deleteTransactionCount, 0)
            XCTAssertEqual(fixture.database.deleteAllCount, 0)

            try await fixture.history.clearAll()
            XCTAssertFalse(fixture.persistence.storeExists)
            XCTAssertEqual(fixture.persistence.clearCount, 1)
            let results = try await fixture.history.search(.all)
            XCTAssertTrue(results.isEmpty)
            XCTAssertEqual(fixture.persistence.createCount, 0)
        }
    }

    func testFirstEnabledWriteAfterClearLazilyCreatesFreshStore() async throws {
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        let fixture = HistoryServiceFixture(
            preferences: HistoryPreferencesStub(snapshot: snapshot),
            exists: true
        )
        _ = try fixture.seed(index: 1, timestamp: Date())

        try await fixture.history.clearAll()
        XCTAssertEqual(fixture.persistence.createCount, 0)

        let outcome = try await fixture.history.recordCompleted(
            historyCompletion(2),
            sourceApplication: nil
        )
        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(fixture.persistence.createCount, 1)
        XCTAssertTrue(fixture.persistence.storeExists)
        XCTAssertEqual(fixture.database.insertCount, 1)
    }

    func testProductionPersistenceClearsDatabaseAndKeyThenRecreatesOnlyOnWrite() async throws {
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        let preferences = HistoryPreferencesStub(snapshot: snapshot)
        let root = historyPhysicalTemporaryDirectory()
            .appendingPathComponent("GlideTranslate-T10-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        let keyBacking = HistoryMemoryKeyStore()
        let persistence = DefaultHistoryPersistence(
            fileURL: fileURL,
            keyStore: HistoryKeyStore(keyStore: keyBacking)
        )
        let history = DefaultTranslationHistory(
            preferences: preferences,
            clock: FixedHistoryClock(date: Date(timeIntervalSince1970: 2_000_000_000)),
            persistence: persistence
        )

        let initialResults = try await history.search(.all)
        XCTAssertTrue(initialResults.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(keyBacking.createCount, 0)

        let firstOutcome = try await history.recordCompleted(
            historyCompletion(10),
            sourceApplication: nil
        )
        XCTAssertEqual(firstOutcome, .stored)
        let storedResults = try await history.search(.all)
        XCTAssertEqual(storedResults.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(keyBacking.createCount, 1)
        let encryptedDatabase = try Data(contentsOf: fileURL)

        try keyBacking.deleteKey(service: "synthetic", account: "synthetic")
        do {
            _ = try await history.search(.all)
            XCTFail("Missing key must not appear as empty valid history")
        } catch {
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), encryptedDatabase)

        try await history.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path + "-journal"))
        XCTAssertNil(keyBacking.key)
        let clearedResults = try await history.search(.all)
        XCTAssertTrue(clearedResults.isEmpty)
        XCTAssertEqual(keyBacking.createCount, 1)

        let secondOutcome = try await history.recordCompleted(
            historyCompletion(11),
            sourceApplication: nil
        )
        XCTAssertEqual(secondOutcome, .stored)
        XCTAssertEqual(keyBacking.createCount, 2)
    }

    func testProductionClearRejectsSymlinkedAncestorWithoutDeletingRedirectedFileOrKey() throws {
        let root = historyPhysicalTemporaryDirectory()
            .appendingPathComponent("GlideTranslate-T10-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let redirect = root.appendingPathComponent("redirect", isDirectory: true)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: redirect,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(redirect.path, mode_t(0o700)), 0)
        let redirectedDatabase = redirect.appendingPathComponent("history.sqlite")
        let marker = Data("redirected-history-marker".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: redirectedDatabase.path,
            contents: marker
        ))
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: redirect)
        let keyBacking = HistoryMemoryKeyStore(initialKey: Data(repeating: 0x45, count: 32))
        let persistence = DefaultHistoryPersistence(
            fileURL: link.appendingPathComponent("history.sqlite"),
            keyStore: HistoryKeyStore(keyStore: keyBacking)
        )

        XCTAssertThrowsError(try persistence.clearAll()) { error in
            XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
        }
        XCTAssertEqual(try Data(contentsOf: redirectedDatabase), marker)
        XCTAssertNotNil(keyBacking.key)
        XCTAssertEqual(keyBacking.deleteCount, 0)
    }

    func testCaseMutatedAndAliasedDatabaseIDsAreUnrecoverableUntilExplicitClear() async throws {
        for duplicateAlias in [false, true] {
            let fixture = try ProductionHistoryFixture()
            defer { fixture.remove() }
            _ = try await fixture.history.recordCompleted(
                historyCompletion(70),
                sourceApplication: nil
            )
            try mutateHistoryIDCase(at: fixture.fileURL, duplicate: duplicateAlias)
            let beforeRead = try Data(contentsOf: fixture.fileURL)

            do {
                _ = try await fixture.history.search(.all)
                XCTFail("Noncanonical database ID must be unrecoverable")
            } catch {
                XCTAssertEqual(error as? HistoryFailure, .unrecoverable)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), beforeRead)

            try await fixture.history.clearAll()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
            XCTAssertNil(fixture.keyBacking.key)
        }
    }

    func testPathScopedAuthorityLockSerializesActiveWriteAndClearAcrossInstances() throws {
        let fixture = try ProductionHistoryFixture()
        defer { fixture.remove() }
        let first = fixture.persistence()
        let second = fixture.persistence()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let clearStarted = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { writeFinished.signal() }
            try? first.withWritable { runtime in
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                let id = historyRecordIDForT10(80)
                let payload = HistoryPayload(
                    completion: historyCompletion(80),
                    timestamp: Date(timeIntervalSince1970: 2_000_000_000)
                )
                let envelope = try runtime.cipher.seal(payload, id: id)
                try runtime.database.insert(id: id, envelope: envelope)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            clearStarted.signal()
            try? second.clearAll()
            clearFinished.signal()
        }
        XCTAssertEqual(clearStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 0.05), .timedOut)

        release.signal()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keyBacking.key)
    }

    func testAuthorityLockSerializesCaseAliasedPathsResolvingToSameInode() throws {
        let fixture = try ProductionHistoryFixture()
        defer { fixture.remove() }
        let canonical = fixture.persistence()
        let aliasedURL = fixture.root
            .appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        let aliased = DefaultHistoryPersistence(
            fileURL: aliasedURL,
            keyStore: HistoryKeyStore(keyStore: fixture.keyBacking)
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let clearStarted = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { writeFinished.signal() }
            try? canonical.withWritable { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let canonicalIdentity = try historyFileIdentity(
            fixture.fileURL.deletingLastPathComponent()
        )
        let aliasIdentity: HistoryTestFileIdentity
        do {
            aliasIdentity = try historyFileIdentity(
                aliasedURL.deletingLastPathComponent()
            )
        } catch {
            release.signal()
            _ = writeFinished.wait(timeout: .now() + 1)
            throw XCTSkip("The active test volume is case-sensitive")
        }
        XCTAssertEqual(aliasIdentity, canonicalIdentity)

        DispatchQueue.global().async {
            clearStarted.signal()
            try? aliased.clearAll()
            clearFinished.signal()
        }
        XCTAssertEqual(clearStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(clearFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keyBacking.key)
    }

    func testFirstWriteCompensationCompletesBeforeSecondInstanceCreatesAuthority() throws {
        let fixture = try ProductionHistoryFixture()
        defer { fixture.remove() }
        let factoryEntered = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let failing = DefaultHistoryPersistence(
            fileURL: fixture.fileURL,
            keyStore: HistoryKeyStore(keyStore: fixture.keyBacking),
            databaseFactory: { fileURL in
                factoryEntered.signal()
                _ = releaseFactory.wait(timeout: .now() + 2)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard chmod(
                    fileURL.deletingLastPathComponent().path,
                    mode_t(0o700)
                ) == 0,
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data("partial".utf8)
                ),
                chmod(fileURL.path, mode_t(0o600)) == 0 else {
                    throw HistoryFailure.unrecoverable
                }
                throw HistoryFailure.unrecoverable
            }
        )
        let succeeding = fixture.persistence()

        DispatchQueue.global().async {
            _ = try? failing.withWritable { _ in () }
            firstFinished.signal()
        }
        XCTAssertEqual(factoryEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            secondStarted.signal()
            _ = try? succeeding.withWritable { _ in () }
            secondFinished.signal()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.05), .timedOut)

        releaseFactory.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(fixture.keyBacking.createCount, 2)
        XCTAssertNotNil(fixture.keyBacking.key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }
}

private struct ProductionHistoryFixture {
    let root: URL
    let fileURL: URL
    let keyBacking: HistoryMemoryKeyStore
    let preferences: HistoryPreferencesStub
    let history: DefaultTranslationHistory

    init() throws {
        var snapshot = PreferencesSnapshot.defaultValue
        snapshot.historyEnabled = true
        root = historyPhysicalTemporaryDirectory()
            .appendingPathComponent("GlideTranslate-T10-production-\(UUID().uuidString)")
        fileURL = root
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        keyBacking = HistoryMemoryKeyStore()
        preferences = HistoryPreferencesStub(snapshot: snapshot)
        history = DefaultTranslationHistory(
            preferences: preferences,
            clock: FixedHistoryClock(date: Date(timeIntervalSince1970: 2_000_000_000)),
            persistence: DefaultHistoryPersistence(
                fileURL: fileURL,
                keyStore: HistoryKeyStore(keyStore: keyBacking)
            )
        )
    }

    func persistence() -> DefaultHistoryPersistence {
        DefaultHistoryPersistence(
            fileURL: fileURL,
            keyStore: HistoryKeyStore(keyStore: keyBacking)
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class HistoryMemoryKeyStore: SymmetricKeyStoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var recordedCreateCount = 0
    private var recordedDeleteCount = 0

    init(initialKey: Data? = nil) { storedKey = initialKey }

    var key: Data? { lock.withLock { storedKey } }
    var createCount: Int { lock.withLock { recordedCreateCount } }
    var deleteCount: Int { lock.withLock { recordedDeleteCount } }

    func readKey(service: String, account: String) throws -> Data? {
        lock.withLock { storedKey }
    }

    func readOrCreateKey(
        service: String,
        account: String
    ) throws -> SymmetricKeyMaterial {
        lock.withLock {
            if let storedKey {
                return SymmetricKeyMaterial(
                    data: storedKey,
                    createdByCaller: false
                )
            }
            let value = Data(repeating: UInt8(recordedCreateCount + 1), count: 32)
            storedKey = value
            recordedCreateCount += 1
            return SymmetricKeyMaterial(data: value, createdByCaller: true)
        }
    }

    func deleteKey(service: String, account: String) throws {
        lock.withLock {
            storedKey = nil
            recordedDeleteCount += 1
        }
    }
}

private func historyPhysicalTemporaryDirectory() -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    guard let resolved = Darwin.realpath(temporaryPath, nil) else {
        return FileManager.default.temporaryDirectory
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private func mutateHistoryIDCase(at url: URL, duplicate: Bool) throws {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &connection,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
        nil
    ) == SQLITE_OK, let connection else {
        throw HistoryFailure.unrecoverable
    }
    defer { sqlite3_close_v2(connection) }
    let sql = duplicate
        ? "INSERT INTO records(id, envelope) SELECT upper(id), envelope FROM records"
        : "UPDATE records SET id = upper(id)"
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
        throw HistoryFailure.unrecoverable
    }
}

private struct HistoryTestFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private func historyFileIdentity(_ url: URL) throws -> HistoryTestFileIdentity {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        throw HistoryFailure.unrecoverable
    }
    return HistoryTestFileIdentity(device: status.st_dev, inode: status.st_ino)
}
