import CSQLite
import Foundation

public enum PersistenceError: Error, Equatable, Sendable {
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(Int64)
    case corruptData(String)
    case closed
}

enum SQLValue {
    case null, integer(Int64), text(String), blob(Data)
    var int: Int64? { if case .integer(let value) = self { value } else { nil } }
    var data: Data? { if case .blob(let value) = self { value } else { nil } }
}

/// One row of a statement being stepped (see `SQLiteConnection.scan`): columns are read where
/// SQLite keeps them, without a copy of the whole row. Valid only inside the call that gives it.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    /// The bytes of a BLOB column (empty when it is not one), usable only inside `body`.
    func withBlob<T>(_ column: Int32, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, let pointer = sqlite3_column_blob(statement, column) else {
            return try body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return try body(UnsafeRawBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))))
    }
}

/// Ownership never escapes SQLiteStore. After initialization, all access is actor-isolated.
/// SQLite FULLMUTEX also protects the native handle. A statement is reset before each call returns.
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    /// Statements already compiled, by their SQL. The store runs the same few dozen statements for
    /// every edit; compiling each one again every time was most of the work of the short ones.
    /// SQLite compiles a kept statement again by itself when the schema changes.
    private var statements: [String: OpaquePointer] = [:]
    private static let statementLimit = 128

    init(path: String) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let pointer { sqlite3_close_v2(pointer) }
            throw PersistenceError.sqlite(code: code, message: message)
        }
        handle = pointer
        sqlite3_busy_timeout(pointer, 5_000)
        do {
            try execute("PRAGMA foreign_keys = ON")
        } catch {
            finalizeStatements()
            sqlite3_close_v2(pointer)
            handle = nil
            throw error
        }
    }

    deinit {
        finalizeStatements()
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() throws {
        guard let handle else { return }
        // A connection with statements still alive refuses to close.
        finalizeStatements()
        let code = sqlite3_close(handle)
        guard code == SQLITE_OK else { throw failure(code) }
        self.handle = nil
    }

    private func finalizeStatements() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
    }

    func script(_ sql: String) throws {
        guard let handle else { throw PersistenceError.closed }
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }

    /// The compiled statement for `sql`, kept for the next call.
    private func prepared(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw PersistenceError.closed }
        if let kept = statements[sql] { return kept }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { throw failure(prepare) }
        if statements.count >= Self.statementLimit { finalizeStatements() }
        statements[sql] = statement
        return statement
    }

    private func bind(_ parameters: [SQLValue], to statement: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == parameters.count else {
            throw PersistenceError.corruptData("SQL binding count mismatch")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch parameter {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                guard value.utf8.count <= Int(Int32.max) else { throw PersistenceError.corruptData("Text exceeds SQLite limit") }
                code = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
            case .blob(let value):
                guard value.count <= Int(Int32.max) else { throw PersistenceError.corruptData("Blob exceeds SQLite limit") }
                if value.isEmpty { code = sqlite3_bind_zeroblob(statement, index, 0) }
                else { code = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) } }
            }
            guard code == SQLITE_OK else { throw failure(code) }
        }
    }

    @discardableResult
    func execute(_ sql: String, _ parameters: [SQLValue] = []) throws -> [[SQLValue]] {
        let statement = try prepared(sql)
        // Reset on every way out: a statement left mid-way would keep its read lock, and its
        // bound values (a note's text) would stay in memory until the next call.
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(parameters, to: statement)
        var rows: [[SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure(code) }
            var row: [SQLValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let pointer = sqlite3_column_blob(statement, column) { row.append(.blob(Data(bytes: pointer, count: count))) }
                    else { row.append(.blob(Data())) }
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let pointer = sqlite3_column_text(statement, column) {
                        row.append(.text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)))
                    } else { row.append(.text("")) }
                case SQLITE_NULL: row.append(.null)
                default: throw PersistenceError.corruptData("Unexpected SQL value type")
                }
            }
            rows.append(row)
        }
    }

    /// Steps through the rows of a query without keeping them: `row` reads what it needs from
    /// each one. For queries over many rows (every stored vector), where an array of copied rows
    /// would be most of the cost. The statement is this call's own, so `row` may run other
    /// statements on the connection.
    func scan(_ sql: String, _ parameters: [SQLValue] = [], row: (SQLiteRow) throws -> Void) throws {
        guard let handle else { throw PersistenceError.closed }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { throw failure(prepare) }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure(code) }
            try row(SQLiteRow(statement: statement))
        }
    }

    func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure(_ code: Int32) -> PersistenceError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database closed")
    }
}
