import Foundation
import SQLite3
@testable import Nootch

/// Builds throwaway SQLite fixture databases for the VibeSync parser tests
/// (the write side; the parsers under test only ever read).
final class SQLiteFixture {
    struct Failure: Error, Equatable { let message: String }

    let url: URL
    private var db: OpaquePointer?

    init(at url: URL, sql: String = "", wal: Bool = false) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw Failure(message: "cannot open fixture db at \(url.path)")
        }
        db = handle
        if wal { try exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
        if !sql.isEmpty { try exec(sql) }
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// Close the handle; a WAL fixture kept open simulates a live writer.
    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    deinit { close() }
}

func sqlQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

func makeTempDirectory(_ prefix: String) -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Entries → buckets / events → sessions through the shared aggregation, so
/// assertions match the upstream parsers' bucket-level expectations.
func vibeBuckets(_ result: VibeParseResult) -> [VibeBucket] {
    VibeAggregation.aggregateToBuckets(result.entries, hostname: "test")
}

func vibeSessions(_ result: VibeParseResult) -> [VibeSession] {
    VibeAggregation.extractSessions(result.events)
}
