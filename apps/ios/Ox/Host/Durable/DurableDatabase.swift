import Foundation
import SQLite3

/// Connection owned by one trusted runtime. Called exclusively on its native queue, never the UI/JS queue.
nonisolated final class DurableDatabase {
    private let url: URL
    private var connection: OpaquePointer?
    private var closed = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }
    deinit { if let connection { sqlite3_close_v2(connection) } }

    func perform(_ op: String, sql: String, params: [Any]) throws -> Any {
        if op == "close" {
            if let connection {
                // Close follows the facade's settled transaction queue. Failed-open disposal
                // may still own an uncommitted initialization transaction; never publish it.
                if sqlite3_get_autocommit(connection) == 0 { try check(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)) }
                try check(sqlite3_wal_checkpoint_v2(connection, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil))
                try check(sqlite3_close(connection))
                self.connection = nil
            }
            closed = true
            return NSNull()
        }
        guard !closed else { throw failure("Database closed") }
        if connection == nil { try open() }
        if op == "exec" {
            try check(sqlite3_exec(connection, sql, nil, nil, nil))
            return NSNull()
        }
        guard ["run", "get", "all"].contains(op) else { throw failure("Unknown SQL operation") }
        var statement: OpaquePointer?
        try sql.withCString { text in
            var tail: UnsafePointer<CChar>?
            try check(sqlite3_prepare_v2(connection, text, -1, &statement, &tail))
            if let tail, !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sqlite3_finalize(statement)
                statement = nil
                throw failure("Expected one SQL statement")
            }
        }
        guard let statement else { throw failure("Empty SQL statement") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == params.count else { throw failure("SQL binding count mismatch") }
        for (index, value) in params.enumerated() { try bind(value, at: Int32(index + 1), to: statement) }
        var rows: [[String: Any]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            try check(code, allowed: SQLITE_ROW)
            if op != "run" {
                var row: [String: Any] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    row[String(cString: sqlite3_column_name(statement, column))] = try value(at: column, in: statement)
                }
                rows.append(row)
            }
        }
        if op == "get" { return rows.first.map { $0 as Any } ?? NSNull() }
        return op == "all" ? rows : NSNull()
    }

    private func open() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let code = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        do {
            try check(code)
            try check(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;", nil, nil, nil))
        } catch {
            sqlite3_close_v2(connection)
            connection = nil
            throw error
        }
    }

    private func bind(_ value: Any, at index: Int32, to statement: OpaquePointer) throws {
        let code: Int32
        if value is NSNull { code = sqlite3_bind_null(statement, index) }
        else if let text = value as? String {
            code = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
        } else if let number = value as? NSNumber {
            code = sqlite3_bind_double(statement, index, number.doubleValue)
        } else if let tagged = value as? [String: Any], let text = tagged["integer"] as? String, let integer = Int64(text) {
            code = sqlite3_bind_int64(statement, index, integer)
        } else if let tagged = value as? [String: Any], let bytes = tagged["blob"] as? [UInt8] {
            code = bytes.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : bytes.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
            }
        } else { throw failure("Unsupported SQL binding") }
        try check(code)
    }

    private func value(at column: Int32, in statement: OpaquePointer) throws -> Any {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: return NSNull()
        case SQLITE_INTEGER:
            let integer = sqlite3_column_int64(statement, column)
            if integer < -9_007_199_254_740_991 || integer > 9_007_199_254_740_991 { return ["integer": String(integer)] }
            return integer
        case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let bytes = sqlite3_column_text(statement, column), let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8) else {
                throw failure("Invalid SQLite UTF-8")
            }
            return text
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let bytes = sqlite3_column_blob(statement, column) else { return ["blob": [UInt8]()] }
            return ["blob": Array(Data(bytes: bytes, count: count))]
        default: throw failure("Unsupported SQLite result")
        }
    }

    private func check(_ code: Int32, allowed: Int32 = SQLITE_OK) throws {
        guard code == allowed else { throw failure(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable", code: code) }
    }
    private func failure(_ message: String, code: Int32 = SQLITE_ERROR) -> NSError {
        NSError(domain: "OxDurableSQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
