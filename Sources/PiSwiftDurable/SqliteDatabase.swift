import Foundation
import SQLite3

/// A SQLite error with the result code and the connection's error text.
public struct SqliteError: Error, Equatable, CustomStringConvertible {
    public let resultCode: Int32
    public let message: String

    public init(resultCode: Int32, message: String) {
        self.resultCode = resultCode
        self.message = message
    }

    public var description: String { message }
}

/// The linked SQLite library cannot create the STRICT tables in the durable schema.
public struct SqliteVersionError: Error, Equatable, CustomStringConvertible {
    public let foundVersion: Int32
    public let foundVersionText: String
    public var description: String {
        "Durable SQLite requires SQLite 3.37.0 or newer; found \(foundVersionText) (\(foundVersion))"
    }
}

/// A failed rollback does not give the guarantees of the original transaction error.
public struct SqliteRollbackError: Error, CustomStringConvertible {
    public let transactionError: any Error
    public let rollbackError: any Error
    public var description: String { "SQLite transaction failed and rollback failed" }
}

internal enum SqliteFacadeError: Error, Equatable, CustomStringConvertible {
    case closed
    case inactiveTransaction
    case transactionHandleRequired
    case invalidMigrations
    case missingSchema
    case newerSchema(found: Int, supported: Int)

    var description: String {
        switch self {
        case .closed: "SQLite database is closed"
        case .inactiveTransaction: "SQLite transaction handle is no longer active"
        case .transactionHandleRequired: "SQLite operations inside a transaction must use its handle"
        case .invalidMigrations: "Durable SQLite migrations must have contiguous versions starting at 1"
        case .missingSchema: "Durable SQLite schema metadata is missing"
        case let .newerSchema(found, supported):
            "Durable SQLite schema version \(found) is newer than supported version \(supported)"
        }
    }
}

internal enum SqliteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var textValue: String? {
        guard case let .text(value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}

internal typealias SqliteRow = [String: SqliteValue]

/// Synchronous access to one connection. The storage actor owns this non-Sendable object.
/// Transaction callbacks must use their handle. The handle expires before commit or rollback.
internal protocol SqliteExecutor: AnyObject {
    func exec(_ sql: String) throws
    func run(_ sql: String, _ params: [SqliteValue]) throws
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow?
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow]
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T
    func close() throws
}

internal extension SqliteExecutor {
    func run(_ sql: String) throws { try run(sql, []) }
    func get(_ sql: String) throws -> SqliteRow? { try get(sql, []) }
    func all(_ sql: String) throws -> [SqliteRow] { try all(sql, []) }
}

/// Apple SQLite3 implementation. Its pointer and statement cache stay inside the storage actor.
internal final class AppleSqliteDatabase: SqliteExecutor {
    private var connection: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var transactionActive = false
    /// Test hook: count successful prepares by SQL text, including cache misses only.
    private(set) var prepareCounts: [String: Int] = [:]

    init(path: String, walAutoCheckpointPages: Int = 1_000, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        let version = sqlite3_libversion_number()
        guard version >= 3_037_000 else {
            throw SqliteVersionError(foundVersion: version, foundVersionText: String(cString: sqlite3_libversion()))
        }
        if path != ":memory:" {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result))
            if let opened { sqlite3_close_v2(opened) }
            throw SqliteError(resultCode: result, message: message)
        }
        connection = opened
        do {
            try check(sqlite3_busy_timeout(opened, busyTimeoutMilliseconds))
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA synchronous = NORMAL")
            try exec("PRAGMA wal_autocheckpoint = \(walAutoCheckpointPages)")
        } catch {
            try? close()
            throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let connection { sqlite3_close_v2(connection) }
    }

    func exec(_ sql: String) throws {
        try requireOutsideTransaction()
        try execute(sql)
    }

    func run(_ sql: String, _ params: [SqliteValue]) throws {
        try requireOutsideTransaction()
        try executeRun(sql, params)
    }

    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        try requireOutsideTransaction()
        return try executeGet(sql, params)
    }

    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
        try requireOutsideTransaction()
        return try executeAll(sql, params)
    }

    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        try requireOutsideTransaction()
        try execute("BEGIN IMMEDIATE")
        transactionActive = true
        let handle = TransactionHandle(database: self)
        defer { transactionActive = false }
        do {
            let result = try body(handle)
            handle.active = false
            try execute("COMMIT")
            return result
        } catch {
            handle.active = false
            do {
                try execute("ROLLBACK")
            } catch let rollbackError {
                throw SqliteRollbackError(transactionError: error, rollbackError: rollbackError)
            }
            throw error
        }
    }

    func close() throws {
        guard let connection else { return }
        try requireOutsideTransaction()
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        var checkpointError: (any Error)?
        do { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        catch { checkpointError = error }
        let result = sqlite3_close_v2(connection)
        let closeError = result == SQLITE_OK ? nil : makeError(result)
        self.connection = nil
        if let checkpointError { throw checkpointError }
        if let closeError { throw closeError }
    }

    private func requireOutsideTransaction() throws {
        guard connection != nil else { throw SqliteFacadeError.closed }
        guard !transactionActive else { throw SqliteFacadeError.transactionHandleRequired }
    }

    private func execute(_ sql: String) throws {
        guard let connection else { throw SqliteFacadeError.closed }
        try check(sqlite3_exec(connection, sql, nil, nil, nil))
    }

    private func statement(_ sql: String, _ params: [SqliteValue]) throws -> OpaquePointer {
        guard let connection else { throw SqliteFacadeError.closed }
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            let result = sqlite3_prepare_v2(connection, sql, -1, &prepared, nil)
            guard result == SQLITE_OK, let prepared else {
                if let prepared { sqlite3_finalize(prepared) }
                throw makeError(result == SQLITE_OK ? SQLITE_MISUSE : result)
            }
            statement = prepared
            statements[sql] = statement
            prepareCounts[sql, default: 0] += 1
        }
        // Reset can report the preceding step's error; that error has already been returned.
        sqlite3_reset(statement)
        try check(sqlite3_clear_bindings(statement))
        guard sqlite3_bind_parameter_count(statement) == params.count else {
            throw SqliteError(resultCode: SQLITE_RANGE, message: "SQLite binding count does not match statement parameters")
        }
        do {
            for (offset, value) in params.enumerated() {
                try bind(value, index: Int32(offset + 1), statement: statement)
            }
        } catch {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            throw error
        }
        return statement
    }

    private func bind(_ value: SqliteValue, index: Int32, statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result: Int32
        switch value {
        case .null: result = sqlite3_bind_null(statement, index)
        case let .integer(value): result = sqlite3_bind_int64(statement, index, value)
        case let .real(value): result = sqlite3_bind_double(statement, index, value)
        case let .text(value):
            guard value.utf8.count <= Int(Int32.max) else {
                throw SqliteError(resultCode: SQLITE_TOOBIG, message: "SQLite text value is too large")
            }
            result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
        case let .blob(value):
            guard value.count <= Int(Int32.max) else {
                throw SqliteError(resultCode: SQLITE_TOOBIG, message: "SQLite blob value is too large")
            }
            if value.isEmpty {
                result = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
            }
        }
        try check(result)
    }

    private func executeRun(_ sql: String, _ params: [SqliteValue]) throws {
        let statement = try statement(sql, params)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw makeError(result) }
    }

    private func executeGet(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        let statement = try statement(sql, params)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw makeError(result) }
        return readRow(statement)
    }

    private func executeAll(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
        let statement = try statement(sql, params)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        var rows: [SqliteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw makeError(result) }
            rows.append(readRow(statement))
        }
    }

    private func readRow(_ statement: OpaquePointer) -> SqliteRow {
        var row: SqliteRow = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            let value: SqliteValue
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: value = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT: value = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                let count = Int(sqlite3_column_bytes(statement, index))
                if let bytes = sqlite3_column_text(statement, index) {
                    value = .text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
                } else { value = .text("") }
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                if let bytes = sqlite3_column_blob(statement, index) {
                    value = .blob(Data(bytes: bytes, count: count))
                } else { value = .blob(Data()) }
            default: value = .null
            }
            row[name] = value
        }
        return row
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw makeError(result) }
    }

    private func makeError(_ result: Int32) -> SqliteError {
        let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result))
        return SqliteError(resultCode: result, message: message)
    }

    private final class TransactionHandle: SqliteExecutor {
        private let database: AppleSqliteDatabase
        var active = true
        init(database: AppleSqliteDatabase) { self.database = database }
        private func requireActive() throws {
            guard active else { throw SqliteFacadeError.inactiveTransaction }
        }
        func exec(_ sql: String) throws {
            try requireActive()
            try database.execute(sql)
        }
        func run(_ sql: String, _ params: [SqliteValue]) throws {
            try requireActive()
            try database.executeRun(sql, params)
        }
        func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
            try requireActive()
            return try database.executeGet(sql, params)
        }
        func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
            try requireActive()
            return try database.executeAll(sql, params)
        }
        func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
            try requireActive()
            throw SqliteFacadeError.transactionHandleRequired
        }
        func close() throws {
            try requireActive()
            throw SqliteFacadeError.transactionHandleRequired
        }
    }
}
