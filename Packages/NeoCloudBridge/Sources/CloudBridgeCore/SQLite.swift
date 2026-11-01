import Foundation
import SQLite3

/// The narrow slice of the system SQLite C API this package needs.
///
/// The app links the SQLite that ships with the OS (`import SQLite3` on Apple platforms): no bundle
/// is copied, no version is pinned, and there is no third-party dependency to audit. Values go in
/// through bound parameters only — no statement in this package interpolates text into SQL.
public final class SQLiteDatabase {
    public struct Failure: Error, CustomStringConvertible {
        public let code: Int32
        public let message: String
        public let sql: String?
        public var description: String { "sqlite \(code): \(message)" + (sql.map { " — \($0)" } ?? "") }
    }

    private var handle: OpaquePointer?
    private var transactionDepth = 0

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close_v2(db) }
            throw Failure(code: result, message: message, sql: nil)
        }
        handle = db
        // A write that blocks on another connection would surface as a mysterious hang; a bounded
        // wait turns it into an error the store can retry.
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { close() }

    /// Release the file handle. Tests call this before deleting their temporary directory: unlinking
    /// a database that is still open corrupts nothing but does upset SQLite.
    public func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "execute failed"
            if let errorPointer { sqlite3_free(errorPointer) }
            throw Failure(code: result, message: message, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw Failure(code: SQLITE_MISUSE, message: "database is closed", sql: sql) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw Failure(code: result, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return SQLiteStatement(handle: statement, database: handle, sql: sql)
    }

    /// Run `body` inside `BEGIN IMMEDIATE … COMMIT`. Any thrown error rolls the whole thing back:
    /// "the draft was cleared but nothing was queued" is the failure mode this prevents.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let value = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return value
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

public final class SQLiteStatement {
    private let handle: OpaquePointer
    private let database: OpaquePointer
    private let sql: String
    private var didStep = false

    init(handle: OpaquePointer, database: OpaquePointer, sql: String) {
        self.handle = handle
        self.database = database
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    private func failure(_ code: Int32) -> SQLiteDatabase.Failure {
        SQLiteDatabase.Failure(code: code, message: String(cString: sqlite3_errmsg(database)), sql: sql)
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    public func bind(_ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(handle, index, value, -1, transient) }
        else { sqlite3_bind_null(handle, index) }
    }

    public func bind(_ index: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(handle, index, value) } else { sqlite3_bind_null(handle, index) }
    }

    public func bind(_ index: Int32, _ value: Int?) { bind(index, value.map(Int64.init)) }

    public func bind(_ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(handle, index, value) } else { sqlite3_bind_null(handle, index) }
    }

    public func bind(_ index: Int32, _ value: Data?) {
        if let value {
            _ = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), transient)
            }
        } else {
            sqlite3_bind_null(handle, index)
        }
    }

    @discardableResult public func step() throws -> Bool {
        let result = sqlite3_step(handle)
        didStep = true
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure(result)
        }
    }

    /// Step a statement that returns no rows (`INSERT`, `UPDATE`, `DELETE`).
    public func run() throws {
        guard try step() == false else { throw failure(SQLITE_MISUSE) }
    }

    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        didStep = false
    }

    public func text(_ index: Int32) -> String? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL, let pointer = sqlite3_column_text(handle, index)
        else { return nil }
        return String(cString: pointer)
    }

    public func int(_ index: Int32) -> Int64? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(handle, index)
    }

    public func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(handle, index)
    }

    public func blob(_ index: Int32) -> Data? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0, let pointer = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}
