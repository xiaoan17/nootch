import Foundation
import SQLite3

// Shared read-only SQLite access for the Vibe Usage parsers — Swift port of
// vibe-usage `src/parsers/sqlite.js` plus the JS value-coercion helpers from
// `src/parsers/fs-utils.js` that every SQLite parser relies on.
//
// Differences from the JS original:
// - JS prefers `node:sqlite` and falls back to shelling out to the `sqlite3`
//   CLI; on macOS the system libsqlite3 is always available, so there is no
//   CLI fallback and therefore no "sqlite3 unavailable" error path.
// - Databases are opened read-only (SQLITE_OPEN_READONLY). On a
//   "database is locked" error the DB and its -wal/-shm companions are copied
//   to a temp dir and re-queried as a writable snapshot with
//   `PRAGMA query_only = ON`, so WAL shared-memory setup can happen in the
//   copy without ever mutating the source application's database.

enum VibeSQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)

    /// JS `String(value)` for the shapes our allow-listed queries can return;
    /// nil mirrors JS null/undefined (the caller's `||` fallback applies).
    var jsString: String? {
        switch self {
        case .null: return nil
        case .text(let string): return string
        case .integer(let value): return String(value)
        case .double(let value): return VibeSQLite.jsNumberString(value)
        }
    }

    /// JS `Number(value)`: numbers pass through, text is parsed (empty or
    /// whitespace-only text is 0, unparseable text is NaN), null is 0.
    var jsNumber: Double {
        switch self {
        case .null: return 0
        case .integer(let value): return Double(value)
        case .double(let value): return value
        case .text(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }
            return Double(trimmed) ?? .nan
        }
    }
}

/// One result row with SELECT-order columns, mirroring the plain objects that
/// `db.prepare(sql).all()` returns (column name → value).
struct VibeSQLiteRow: Sendable {
    let columns: [String]
    let values: [VibeSQLiteValue]

    subscript(column: String) -> VibeSQLiteValue {
        guard let index = columns.firstIndex(of: column) else { return .null }
        return values[index]
    }

    /// JSON.stringify-equivalent serialization used as a cross-store
    /// deduplication identity (mcode). Column order is preserved like the JS
    /// object key order; numbers print the way JS prints them (no trailing
    /// ".0" for integral values).
    var canonicalJSON: String {
        var out = "{"
        for (index, column) in columns.enumerated() {
            if index > 0 { out.append(",") }
            out.append(VibeSQLite.jsJSONString(column))
            out.append(":")
            switch values[index] {
            case .null: out.append("null")
            case .integer(let value): out.append(String(value))
            case .double(let value): out.append(VibeSQLite.jsNumberString(value))
            case .text(let string): out.append(VibeSQLite.jsJSONString(string))
            }
        }
        out.append("}")
        return out
    }
}

struct VibeSQLiteError: Error, Equatable {
    let message: String

    /// Mirrors sqlite.js isLockError: the SQLITE_BUSY message text.
    var isLockError: Bool {
        message.range(of: "database is locked", options: .caseInsensitive) != nil
    }
}

enum VibeSQLite {
    /// Run a read-only query with optional parameter binding (?1, ?2, ...).
    static func query(
        databasePath path: String,
        sql: String,
        parameters: [VibeSQLiteValue] = [],
        readOnly: Bool = true
    ) throws -> [VibeSQLiteRow] {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = handle
        else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
                ?? "unable to open database file"
            if let handle { sqlite3_close(handle) }
            throw VibeSQLiteError(message: message)
        }
        defer { sqlite3_close(db) }
        // Writable handles exist only for disposable snapshots whose WAL
        // shared-memory metadata may need initialization; the connection
        // itself stays read-only (sqlite.js does the same).
        if !readOnly {
            _ = try execute(db, sql: "PRAGMA query_only = ON", parameters: [])
        }
        return try execute(db, sql: sql, parameters: parameters)
    }

    private static func execute(
        _ db: OpaquePointer,
        sql: String,
        parameters: [VibeSQLiteValue]
    ) throws -> [VibeSQLiteRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VibeSQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, parameter) in parameters.enumerated() {
            let slot = Int32(index + 1)
            let status: Int32
            switch parameter {
            case .null: status = sqlite3_bind_null(statement, slot)
            case .integer(let value): status = sqlite3_bind_int64(statement, slot, value)
            case .double(let value): status = sqlite3_bind_double(statement, slot, value)
            case .text(let string):
                status = sqlite3_bind_text(statement, slot, string, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else {
                throw VibeSQLiteError(message: String(cString: sqlite3_errmsg(db)))
            }
        }
        var rows: [VibeSQLiteRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw VibeSQLiteError(message: String(cString: sqlite3_errmsg(db)))
            }
            let count = Int(sqlite3_column_count(statement))
            var columns: [String] = []
            var values: [VibeSQLiteValue] = []
            columns.reserveCapacity(count)
            values.reserveCapacity(count)
            for column in 0..<Int32(count) {
                columns.append(sqlite3_column_name(statement, column).map { String(cString: $0) } ?? "")
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    values.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT:
                    values.append(.double(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    values.append(.text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""))
                case SQLITE_BLOB:
                    // None of the allow-listed queries select blobs; decode
                    // lossy UTF-8 so the row shape stays intact if one appears.
                    let length = Int(sqlite3_column_bytes(statement, column))
                    let bytes = sqlite3_column_blob(statement, column)
                        .map { UnsafeBufferPointer(start: $0.assumingMemoryBound(to: UInt8.self), count: length) }
                        .map(Array.init) ?? []
                    values.append(.text(String(decoding: bytes, as: UTF8.self)))
                default:
                    values.append(.null)
                }
            }
            rows.append(VibeSQLiteRow(columns: columns, values: values))
        }
        return rows
    }

    /// Run a query; if the source app holds a write lock on the database, copy
    /// the DB (plus its -wal/-shm companions) to a temp dir and re-query the
    /// snapshot. Mirrors sqlite.js queryDbJsonSnapshotOnLock.
    static func querySnapshotOnLock(
        databasePath path: String,
        sql: String,
        parameters: [VibeSQLiteValue] = [],
        tempPrefix: String = "vibe-usage-sqlite"
    ) throws -> [VibeSQLiteRow] {
        do {
            return try query(databasePath: path, sql: sql, parameters: parameters)
        } catch let error as VibeSQLiteError where error.isLockError {
            return try querySnapshot(databasePath: path, sql: sql, parameters: parameters, tempPrefix: tempPrefix)
        }
    }

    static func querySnapshot(
        databasePath path: String,
        sql: String,
        parameters: [VibeSQLiteValue] = [],
        tempPrefix: String
    ) throws -> [VibeSQLiteRow] {
        let fileManager = FileManager.default
        let snapshotDir = fileManager.temporaryDirectory
            .appendingPathComponent("\(tempPrefix)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: snapshotDir) }
        let snapshotPath = snapshotDir.appendingPathComponent((path as NSString).lastPathComponent).path
        try fileManager.copyItem(atPath: path, toPath: snapshotPath)
        for suffix in ["-shm", "-wal"] {
            let companion = path + suffix
            if fileManager.fileExists(atPath: companion) {
                try fileManager.copyItem(atPath: companion, toPath: snapshotPath + suffix)
            }
        }
        return try query(databasePath: snapshotPath, sql: sql, parameters: parameters, readOnly: false)
    }

    /// Schema guard shared by the Devin/mcode parsers: every allow-listed
    /// column must exist. Mirrors the JS dbHasColumns helper.
    static func hasColumns(
        databasePath path: String,
        table: String,
        columns required: [String],
        tempPrefix: String
    ) throws -> Bool {
        // `table` is a compile-time constant at every call site; PRAGMA does
        // not accept bound parameters.
        let info = try querySnapshotOnLock(
            databasePath: path, sql: "PRAGMA table_info(\(table))", tempPrefix: tempPrefix)
        let present = Set(info.compactMap { $0["name"].jsString })
        return required.allSatisfy(present.contains)
    }

    // MARK: - JS-compatible number formatting

    /// Shortest JS-style number text: integral values print without ".0".
    static func jsNumberString(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    static func jsJSONString(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.append(Character(scalar))
                }
            }
        }
        out.append("\"")
        return out
    }

    // MARK: - JS value coercion (fs-utils.js toCount / timestamp sniffing)

    /// JS toCount: finite positive number, else 0.
    static func toCount(_ value: VibeSQLiteValue) -> Double {
        let number = value.jsNumber
        return number.isFinite && number > 0 ? number : 0
    }

    /// mcode's toNonNegative: finite non-negative number, else 0.
    static func toNonNegative(_ value: VibeSQLiteValue) -> Double {
        let number = value.jsNumber
        return number.isFinite && number >= 0 ? number : 0
    }

    /// Unix timestamp with ms/seconds sniffing (values below 1e12 are
    /// seconds). When `requirePositive` is set, non-positive numbers fall
    /// through to the string branch like the JS `number > 0` guard.
    static func sniffedUnixDate(_ value: VibeSQLiteValue, requirePositive: Bool) -> Date? {
        let number = value.jsNumber
        if number.isFinite, (!requirePositive || number > 0) {
            return Date(timeIntervalSince1970: (number < 1e12 ? number * 1000 : number) / 1000)
        }
        if case .text(let string) = value {
            return VibeSyncTime.parse(string)
        }
        return nil
    }

    // MARK: - Project name helpers (fs-utils.js)

    /// JS projectFromPath: last POSIX path component, trailing slashes trimmed.
    static func projectFromPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "unknown" }
        var trimmed = path
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "unknown" : name
    }

    /// JS projectFromCwd: last component of a cwd value, both Unix and
    /// Windows separators.
    static func projectFromCwd(_ cwd: String?, fallback: String = "unknown") -> String {
        guard let cwd else { return fallback }
        var trimmed = cwd.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        if trimmed.isEmpty { return fallback }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fallback
    }

    // MARK: - Fingerprinting for the per-DB parse caches

    struct FileStamp: Equatable, Sendable {
        let size: Int
        let mtime: TimeInterval
    }

    /// DB file plus its WAL companions: a write that only appends to the -wal
    /// still invalidates the cache.
    struct DatabaseFingerprint: Equatable, Sendable {
        let db: FileStamp?
        let wal: FileStamp?
        let shm: FileStamp?
    }

    static func stamp(_ path: String) -> FileStamp? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let size = values.fileSize, let mtime = values.contentModificationDate
        else { return nil }
        return FileStamp(size: size, mtime: mtime.timeIntervalSince1970)
    }

    static func fingerprint(databasePath path: String) -> DatabaseFingerprint {
        DatabaseFingerprint(db: stamp(path), wal: stamp(path + "-wal"), shm: stamp(path + "-shm"))
    }
}
