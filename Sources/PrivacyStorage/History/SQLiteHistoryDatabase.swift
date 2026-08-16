import CSQLite
import Darwin
import Foundation
import SharedSupport

package struct HistoryDatabaseRow: Equatable, Sendable {
    package let id: TranslationRecordID
    package let envelope: HistoryEnvelope

    package init(id: TranslationRecordID, envelope: HistoryEnvelope) {
        self.id = id
        self.envelope = envelope
    }
}

package struct SQLiteHistoryDatabaseHooks: Sendable {
    package var beforeSQLiteOpen: @Sendable () throws -> Void
    package var sqliteOpenPath: @Sendable (URL) -> URL
    package var beforeFetch: @Sendable () throws -> Void
    package var beforeEnvelopeCopy: @Sendable (Int) throws -> Void
    package var beforeDelete: @Sendable (Int) throws -> Void

    package init(
        beforeSQLiteOpen: @escaping @Sendable () throws -> Void = {},
        sqliteOpenPath: @escaping @Sendable (URL) -> URL = { $0 },
        beforeFetch: @escaping @Sendable () throws -> Void = {},
        beforeEnvelopeCopy: @escaping @Sendable (Int) throws -> Void = { _ in },
        beforeDelete: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) {
        self.beforeSQLiteOpen = beforeSQLiteOpen
        self.sqliteOpenPath = sqliteOpenPath
        self.beforeFetch = beforeFetch
        self.beforeEnvelopeCopy = beforeEnvelopeCopy
        self.beforeDelete = beforeDelete
    }
}

package final class SQLiteHistoryDatabase: @unchecked Sendable {
    private static let canonicalTableSQL = "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)"
    private static let createTableSQL = "CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY NOT NULL, envelope BLOB NOT NULL)"
    private let lock = NSLock()
    private let fileURL: URL
    private let hooks: SQLiteHistoryDatabaseHooks
    private let directoryIdentity: SecureStoreDirectoryIdentity?
    private var connection: OpaquePointer?

    package init(
        fileURL: URL,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil,
        hooks: SQLiteHistoryDatabaseHooks = SQLiteHistoryDatabaseHooks()
    ) throws {
        self.fileURL = fileURL
        self.directoryIdentity = directoryIdentity
        self.hooks = hooks
        let directoryDescriptor = try Self.prepareDirectory(
            fileURL.deletingLastPathComponent(),
            expectedIdentity: directoryIdentity
        )
        defer { Darwin.close(directoryDescriptor) }
        let fileDescriptor = try Self.prepareDatabaseFile(
            named: fileURL.lastPathComponent,
            in: directoryDescriptor
        )
        defer { Darwin.close(fileDescriptor) }
        let preparedIdentity = try Self.fileIdentity(fileDescriptor)
        do {
            try hooks.beforeSQLiteOpen()
        } catch {
            throw HistoryFailure.unrecoverable
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_NOFOLLOW
        let sqliteOpenPath = hooks.sqliteOpenPath(fileURL)
        guard sqlite3_open_v2(sqliteOpenPath.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw HistoryFailure.unrecoverable
        }
        connection = opened

        do {
            try Self.verifyPath(fileURL, matches: preparedIdentity)
            try Self.verifySQLiteMainFile(
                opened,
                path: fileURL,
                matches: preparedIdentity
            )
            _ = sqlite3_busy_timeout(opened, 1_000)
            guard try Self.stringValue(opened, sql: "PRAGMA journal_mode = DELETE")
                .lowercased() == "delete" else {
                throw HistoryFailure.unrecoverable
            }
            try Self.execute(opened, sql: "PRAGMA synchronous = FULL")
            try Self.execute(opened, sql: "PRAGMA foreign_keys = ON")
            try Self.initializeOrValidateSchema(opened)
        } catch {
            sqlite3_close_v2(opened)
            connection = nil
            throw HistoryFailure.unrecoverable
        }
    }

    deinit {
        if let connection { sqlite3_close_v2(connection) }
    }

    package func insert(
        id: TranslationRecordID,
        envelope: HistoryEnvelope
    ) throws {
        let encoded = try Self.encode(envelope)
        try withConnection { connection in
            let statement = try Self.prepare(
                connection,
                sql: "INSERT INTO records(id, envelope) VALUES(?1, ?2)"
            )
            defer { sqlite3_finalize(statement) }
            try Self.bind(Self.databaseID(id), to: statement, at: 1)
            try Self.bind(encoded, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw HistoryFailure.unrecoverable
            }
        }
    }

    package func fetchBatch(
        afterID: TranslationRecordID?,
        limit: Int
    ) throws -> [HistoryDatabaseRow] {
        guard limit > 0 else { return [] }
        let cappedLimit = min(limit, 100)
        return try withConnection { connection in
            let sql: String
            if afterID == nil {
                sql = "SELECT id, envelope FROM records ORDER BY id ASC LIMIT ?1"
            } else {
                sql = "SELECT id, envelope FROM records WHERE id > ?1 ORDER BY id ASC LIMIT ?2"
            }
            let statement = try Self.prepare(connection, sql: sql)
            defer { sqlite3_finalize(statement) }
            if let afterID {
                try Self.bind(Self.databaseID(afterID), to: statement, at: 1)
                guard sqlite3_bind_int(statement, 2, Int32(cappedLimit)) == SQLITE_OK else {
                    throw HistoryFailure.unrecoverable
                }
            } else {
                guard sqlite3_bind_int(statement, 1, Int32(cappedLimit)) == SQLITE_OK else {
                    throw HistoryFailure.unrecoverable
                }
            }
            try hooks.beforeFetch()

            var rows: [HistoryDatabaseRow] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    rows.append(try Self.row(
                        from: statement,
                        beforeEnvelopeCopy: hooks.beforeEnvelopeCopy
                    ))
                case SQLITE_DONE:
                    return rows
                default:
                    throw HistoryFailure.unrecoverable
                }
            }
        }
    }

    package func deleteIDsInTransaction(
        _ ids: [TranslationRecordID]
    ) throws {
        try withConnection { connection in
            try Self.transaction(connection) {
                let statement = try Self.prepare(
                    connection,
                    sql: "DELETE FROM records WHERE id = ?1"
                )
                defer { sqlite3_finalize(statement) }
                for (index, id) in ids.enumerated() {
                    guard sqlite3_reset(statement) == SQLITE_OK,
                          sqlite3_clear_bindings(statement) == SQLITE_OK else {
                        throw HistoryFailure.unrecoverable
                    }
                    try hooks.beforeDelete(index)
                    try Self.bind(Self.databaseID(id), to: statement, at: 1)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw HistoryFailure.unrecoverable
                    }
                }
            }
        }
    }

    package func deleteAllInTransaction() throws {
        try withConnection { connection in
            try Self.transaction(connection) {
                try Self.execute(connection, sql: "DELETE FROM records")
            }
        }
    }

    package func schemaColumns() throws -> [String] {
        try withConnection { try Self.schemaMetadata($0).map(\.name) }
    }

    package func userVersion() throws -> Int {
        try withConnection {
            Int(try Self.integerValue($0, sql: "PRAGMA user_version"))
        }
    }

    package func hasFTSTable() throws -> Bool {
        try withConnection { try Self.hasFTSTable($0) }
    }

    package func journalMode() throws -> String {
        try withConnection {
            try Self.stringValue($0, sql: "PRAGMA journal_mode").lowercased()
        }
    }

    package func synchronousLevel() throws -> Int {
        try withConnection {
            Int(try Self.integerValue($0, sql: "PRAGMA synchronous"))
        }
    }

    package func foreignKeysEnabled() throws -> Bool {
        try withConnection {
            try Self.integerValue($0, sql: "PRAGMA foreign_keys") == 1
        }
    }

    package func isTransactionActive() throws -> Bool {
        try withConnection { sqlite3_get_autocommit($0) == 0 }
    }

    package func close() throws {
        try lock.withLock {
            guard let connection else { return }
            guard sqlite3_close(connection) == SQLITE_OK else {
                throw HistoryFailure.unrecoverable
            }
            self.connection = nil
            guard let directoryDescriptor = try Self.openExistingDirectory(
                fileURL.deletingLastPathComponent(),
                expectedIdentity: directoryIdentity
            ) else {
                throw HistoryFailure.unrecoverable
            }
            defer { Darwin.close(directoryDescriptor) }
            for suffix in ["-wal", "-shm"] {
                var status = stat()
                let result = fstatat(
                    directoryDescriptor,
                    fileURL.lastPathComponent + suffix,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                )
                guard result != 0, errno == ENOENT else {
                    throw HistoryFailure.unrecoverable
                }
            }
        }
    }

    package static func storeEntryExists(
        at fileURL: URL,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> Bool {
        let openedDirectory = try openExistingDirectory(
            fileURL.deletingLastPathComponent(),
            expectedIdentity: directoryIdentity
        )
        guard let directoryDescriptor = openedDirectory else {
            if directoryIdentity != nil { throw HistoryFailure.unrecoverable }
            return false
        }
        defer { Darwin.close(directoryDescriptor) }
        let name = fileURL.lastPathComponent
        guard validStoreName(name) else { throw HistoryFailure.unrecoverable }
        var status = stat()
        if fstatat(
            directoryDescriptor,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return true
        }
        guard errno == ENOENT else { throw HistoryFailure.unrecoverable }
        return false
    }

    package static func deleteStoreFiles(
        at fileURL: URL,
        directoryIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws {
        let openedDirectory = try openExistingDirectory(
            fileURL.deletingLastPathComponent(),
            expectedIdentity: directoryIdentity
        )
        guard let directoryDescriptor = openedDirectory else {
            if directoryIdentity != nil { throw HistoryFailure.unrecoverable }
            return
        }
        defer { Darwin.close(directoryDescriptor) }
        let name = fileURL.lastPathComponent
        guard validStoreName(name) else { throw HistoryFailure.unrecoverable }
        for suffix in ["", "-journal", "-wal", "-shm"] {
            if unlinkat(directoryDescriptor, name + suffix, 0) != 0,
               errno != ENOENT {
                throw HistoryFailure.unrecoverable
            }
        }
    }

    private func withConnection<T>(
        _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try lock.withLock {
            guard let connection else { throw HistoryFailure.unrecoverable }
            do {
                return try operation(connection)
            } catch {
                throw HistoryFailure.unrecoverable
            }
        }
    }

    private static func initializeOrValidateSchema(
        _ connection: OpaquePointer
    ) throws {
        let version = try integerValue(connection, sql: "PRAGMA user_version")
        guard version == 0 || version == 1 else {
            throw HistoryFailure.unrecoverable
        }
        if version == 0 {
            try transaction(connection) {
                try execute(connection, sql: createTableSQL)
                try validateMinimalSchema(connection)
                try execute(connection, sql: "PRAGMA user_version = 1")
            }
        } else {
            try validateMinimalSchema(connection)
        }
    }

    private static func validateMinimalSchema(
        _ connection: OpaquePointer
    ) throws {
        let metadata = try schemaMetadata(connection)
        guard metadata == [
            SchemaColumn(name: "id", type: "TEXT", notNull: true, primaryKey: true, hidden: 0),
            SchemaColumn(name: "envelope", type: "BLOB", notNull: true, primaryKey: false, hidden: 0)
        ] else {
            throw HistoryFailure.unrecoverable
        }
        guard try stringValue(
            connection,
            sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='records'"
        ) == canonicalTableSQL else {
            throw HistoryFailure.unrecoverable
        }
        let tables = try textColumn(
            connection,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        guard tables == ["records"], !(try hasFTSTable(connection)) else {
            throw HistoryFailure.unrecoverable
        }
        let extraObjects = try integerValue(
            connection,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('view','trigger') OR (type='index' AND sql IS NOT NULL)"
        )
        guard extraObjects == 0 else { throw HistoryFailure.unrecoverable }
        guard try indexMetadata(connection) == [
            SchemaIndex(
                name: "sqlite_autoindex_records_1",
                unique: true,
                origin: "pk",
                partial: false
            )
        ], try rowCount(
            connection,
            sql: "PRAGMA foreign_key_list(records)"
        ) == 0, try tableFlags(connection) == SchemaTableFlags(
            columnCount: 2,
            withoutRowID: false,
            strict: false
        ) else {
            throw HistoryFailure.unrecoverable
        }
    }

    private static func schemaMetadata(
        _ connection: OpaquePointer
    ) throws -> [SchemaColumn] {
        let statement = try prepare(connection, sql: "PRAGMA table_xinfo(records)")
        defer { sqlite3_finalize(statement) }
        var values: [SchemaColumn] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawName = sqlite3_column_text(statement, 1),
                      let rawType = sqlite3_column_text(statement, 2),
                      sqlite3_column_type(statement, 4) == SQLITE_NULL else {
                    throw HistoryFailure.unrecoverable
                }
                values.append(SchemaColumn(
                    name: String(cString: rawName),
                    type: String(cString: rawType).uppercased(),
                    notNull: sqlite3_column_int(statement, 3) == 1,
                    primaryKey: sqlite3_column_int(statement, 5) == 1,
                    hidden: sqlite3_column_int(statement, 6)
                ))
            case SQLITE_DONE:
                return values
            default:
                throw HistoryFailure.unrecoverable
            }
        }
    }

    private static func hasFTSTable(_ connection: OpaquePointer) throws -> Bool {
        try integerValue(
            connection,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND lower(COALESCE(sql,'')) LIKE 'create virtual table%using fts%'"
        ) != 0
    }

    private static func indexMetadata(
        _ connection: OpaquePointer
    ) throws -> [SchemaIndex] {
        let statement = try prepare(connection, sql: "PRAGMA index_list(records)")
        defer { sqlite3_finalize(statement) }
        var values: [SchemaIndex] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawName = sqlite3_column_text(statement, 1),
                      let rawOrigin = sqlite3_column_text(statement, 3) else {
                    throw HistoryFailure.unrecoverable
                }
                values.append(SchemaIndex(
                    name: String(cString: rawName),
                    unique: sqlite3_column_int(statement, 2) == 1,
                    origin: String(cString: rawOrigin),
                    partial: sqlite3_column_int(statement, 4) == 1
                ))
            case SQLITE_DONE:
                return values
            default:
                throw HistoryFailure.unrecoverable
            }
        }
    }

    private static func tableFlags(
        _ connection: OpaquePointer
    ) throws -> SchemaTableFlags {
        let statement = try prepare(connection, sql: "PRAGMA table_list(records)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoryFailure.unrecoverable
        }
        let flags = SchemaTableFlags(
            columnCount: Int(sqlite3_column_int(statement, 3)),
            withoutRowID: sqlite3_column_int(statement, 4) == 1,
            strict: sqlite3_column_int(statement, 5) == 1
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryFailure.unrecoverable
        }
        return flags
    }

    private static func rowCount(
        _ connection: OpaquePointer,
        sql: String
    ) throws -> Int {
        let statement = try prepare(connection, sql: sql)
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                count += 1
            case SQLITE_DONE:
                return count
            default:
                throw HistoryFailure.unrecoverable
            }
        }
    }

    private static func transaction(
        _ connection: OpaquePointer,
        operation: () throws -> Void
    ) throws {
        try execute(connection, sql: "BEGIN IMMEDIATE")
        do {
            try operation()
            try execute(connection, sql: "COMMIT")
        } catch {
            try? execute(connection, sql: "ROLLBACK")
            throw HistoryFailure.unrecoverable
        }
    }

    private static func execute(
        _ connection: OpaquePointer,
        sql: String
    ) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryFailure.unrecoverable
        }
    }

    private static func prepare(
        _ connection: OpaquePointer,
        sql: String
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw HistoryFailure.unrecoverable
        }
        return statement
    }

    private static func integerValue(
        _ connection: OpaquePointer,
        sql: String
    ) throws -> Int64 {
        let statement = try prepare(connection, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoryFailure.unrecoverable
        }
        let value = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryFailure.unrecoverable
        }
        return value
    }

    private static func stringValue(
        _ connection: OpaquePointer,
        sql: String
    ) throws -> String {
        let statement = try prepare(connection, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else {
            throw HistoryFailure.unrecoverable
        }
        let value = String(cString: raw)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryFailure.unrecoverable
        }
        return value
    }

    private static func textColumn(
        _ connection: OpaquePointer,
        sql: String
    ) throws -> [String] {
        let statement = try prepare(connection, sql: sql)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let raw = sqlite3_column_text(statement, 0) else {
                    throw HistoryFailure.unrecoverable
                }
                values.append(String(cString: raw))
            case SQLITE_DONE:
                return values
            default:
                throw HistoryFailure.unrecoverable
            }
        }
    }

    private static func bind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        let result = value.withCString { raw in
            sqlite3_bind_text(
                statement,
                index,
                raw,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else { throw HistoryFailure.unrecoverable }
    }

    private static func bind(
        _ value: Data,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else { throw HistoryFailure.unrecoverable }
    }

    private static func row(
        from statement: OpaquePointer,
        beforeEnvelopeCopy: (Int) throws -> Void
    ) throws -> HistoryDatabaseRow {
        guard let rawID = sqlite3_column_text(statement, 0) else {
            throw HistoryFailure.unrecoverable
        }
        let storedID = String(cString: rawID)
        guard let uuid = UUID(uuidString: storedID),
              storedID == databaseID(TranslationRecordID(rawValue: uuid)),
              sqlite3_column_type(statement, 1) == SQLITE_BLOB else {
            throw HistoryFailure.unrecoverable
        }
        let byteCount = Int(sqlite3_column_bytes(statement, 1))
        guard byteCount > 0,
              byteCount <= PrivacyStorageResourceLimits
                .historyEnvelopeEncodedBytes,
              let rawEnvelope = sqlite3_column_blob(statement, 1) else {
            throw HistoryFailure.unrecoverable
        }
        try beforeEnvelopeCopy(byteCount)
        let encoded = Data(bytes: rawEnvelope, count: byteCount)
        let envelope: HistoryEnvelope
        do {
            envelope = try PropertyListDecoder().decode(
                HistoryEnvelope.self,
                from: encoded
            )
        } catch {
            throw HistoryFailure.unrecoverable
        }
        return HistoryDatabaseRow(
            id: TranslationRecordID(rawValue: uuid),
            envelope: envelope
        )
    }

    private static func encode(_ envelope: HistoryEnvelope) throws -> Data {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(envelope)
            guard data.count <= PrivacyStorageResourceLimits
                .historyEnvelopeEncodedBytes else {
                throw HistoryFailure.unrecoverable
            }
            return data
        } catch {
            throw HistoryFailure.unrecoverable
        }
    }

    private static func databaseID(_ id: TranslationRecordID) -> String {
        id.rawValue.uuidString.lowercased()
    }

    private static func prepareDirectory(
        _ directory: URL,
        expectedIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> Int32 {
        if let expectedIdentity {
            guard let descriptor = try openExistingDirectory(
                directory,
                expectedIdentity: expectedIdentity
            ) else {
                throw HistoryFailure.unrecoverable
            }
            return descriptor
        }
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path != "/" else {
            throw HistoryFailure.unrecoverable
        }
        var current = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else { throw HistoryFailure.unrecoverable }
        do {
            for component in directory.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.isEmpty else {
                    throw HistoryFailure.unrecoverable
                }
                var next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if next < 0, errno == ENOENT {
                    guard Darwin.mkdirat(current, component, mode_t(0o700)) == 0 else {
                        throw HistoryFailure.unrecoverable
                    }
                    next = Darwin.openat(
                        current,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw HistoryFailure.unrecoverable
                }
                var status = stat()
                guard fstat(next, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFDIR else {
                    Darwin.close(next)
                    throw HistoryFailure.unrecoverable
                }
                Darwin.close(current)
                current = next
            }
            var status = stat()
            guard fstat(current, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == getuid(),
                  fchmod(current, mode_t(0o700)) == 0,
                  fstat(current, &status) == 0,
                  (status.st_mode & mode_t(0o077)) == 0 else {
                throw HistoryFailure.unrecoverable
            }
            return current
        } catch {
            Darwin.close(current)
            throw HistoryFailure.unrecoverable
        }
    }

    private static func openExistingDirectory(
        _ directory: URL,
        expectedIdentity: SecureStoreDirectoryIdentity? = nil
    ) throws -> Int32? {
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path != "/" else {
            throw HistoryFailure.unrecoverable
        }
        var current = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else { throw HistoryFailure.unrecoverable }
        do {
            for component in directory.pathComponents.dropFirst() {
                guard component != ".", component != "..", !component.isEmpty else {
                    throw HistoryFailure.unrecoverable
                }
                let next = Darwin.openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if next < 0, errno == ENOENT {
                    Darwin.close(current)
                    return nil
                }
                guard next >= 0 else { throw HistoryFailure.unrecoverable }
                Darwin.close(current)
                current = next
            }
            var status = stat()
            guard fstat(current, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == getuid(),
                  (status.st_mode & mode_t(0o077)) == 0 else {
                throw HistoryFailure.unrecoverable
            }
            do {
                try expectedIdentity?.validate(current)
            } catch {
                throw HistoryFailure.unrecoverable
            }
            return current
        } catch {
            Darwin.close(current)
            throw HistoryFailure.unrecoverable
        }
    }

    private static func validStoreName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func prepareDatabaseFile(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw HistoryFailure.unrecoverable
        }
        var descriptor = Darwin.openat(
            directoryDescriptor,
            name,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            descriptor = Darwin.openat(
                directoryDescriptor,
                name,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw HistoryFailure.unrecoverable }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == getuid(),
                  fchmod(descriptor, mode_t(0o600)) == 0,
                  fstat(descriptor, &status) == 0,
                  (status.st_mode & mode_t(0o077)) == 0 else {
                throw HistoryFailure.unrecoverable
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw HistoryFailure.unrecoverable
        }
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw HistoryFailure.unrecoverable
        }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private static func verifyPath(
        _ fileURL: URL,
        matches expected: FileIdentity
    ) throws {
        var status = stat()
        guard lstat(fileURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & mode_t(0o077)) == 0,
              FileIdentity(device: status.st_dev, inode: status.st_ino) == expected else {
            throw HistoryFailure.unrecoverable
        }
    }

    private static func verifySQLiteMainFile(
        _ connection: OpaquePointer,
        path fileURL: URL,
        matches expected: FileIdentity
    ) throws {
        guard let rawFilename = sqlite3_db_filename(connection, "main"),
              String(cString: rawFilename) == fileURL.path else {
            throw HistoryFailure.unrecoverable
        }
        var hasMoved: Int32 = 1
        guard sqlite3_file_control(
            connection,
            "main",
            SQLITE_FCNTL_HAS_MOVED,
            &hasMoved
        ) == SQLITE_OK,
        hasMoved == 0 else {
            throw HistoryFailure.unrecoverable
        }
        try verifyPath(fileURL, matches: expected)
    }
}

private struct SchemaColumn: Equatable {
    let name: String
    let type: String
    let notNull: Bool
    let primaryKey: Bool
    let hidden: Int32
}

private struct SchemaIndex: Equatable {
    let name: String
    let unique: Bool
    let origin: String
    let partial: Bool
}

private struct SchemaTableFlags: Equatable {
    let columnCount: Int
    let withoutRowID: Bool
    let strict: Bool
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}
