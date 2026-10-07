import Foundation
import OSLog
import Synchronization

/// Qwen Code log parser — Swift port of vibe-usage `src/parsers/qwen-code.js`
/// (main @ c55b82c1; Qwen Code is a Gemini CLI fork, added upstream in
/// aa581e6e; no post-2026-08 fixes).
///
/// JSONL at ~/.qwen/tmp/<project_id>/chats/<sessionId>.jsonl (chats/ is read
/// flat, no recursion). Every line with a valid `timestamp` and type
/// 'user'/'assistant' is a session event; assistant lines carrying
/// `usageMetadata` produce entries. Token fields:
/// usageMetadata.{promptTokenCount, candidatesTokenCount,
/// cachedContentTokenCount, thoughtsTokenCount} — promptTokenCount INCLUDES
/// cachedContentTokenCount and candidatesTokenCount includes thoughts, so the
/// entry reports input = prompt − cached, output = candidates − thoughts
/// (no clamping, JS keeps negatives). Cache writes have no distinct field;
/// cacheCreation5m/1h stay 0.
///
/// An entry is emitted only when promptTokenCount or candidatesTokenCount is
/// present (JS `== null` gate); a record with both missing contributes its
/// timing event but no entry. Records with a truthy `uuid` dedupe globally
/// across files (first occurrence wins — copied sessions count once); the
/// timing event is emitted before the dedupe gate, exactly like the JS order.
///
/// Project: the last component of the record's `cwd`; without a usable cwd,
/// the <project_id> path segment under the qwen tmp dir; else "unknown"
/// (JS extractProject).
///
/// Documented simplifications vs the JS original:
/// - The JS parser has no `skipped` path: an unreadable file is silently
///   dropped (`continue`). Here that logs through OSLog; the source still
///   reports skipped == false.
/// - Timestamps parse as ISO8601 strings (with/without fractional seconds) or
///   epoch-millisecond numbers; JS `new Date(value)` accepts a few more
///   formats Qwen never writes.
/// - JS `Number`-style coercion is restricted to JSON numbers and numeric
///   strings; booleans are treated as missing (repo-wide convention).
struct VibeQwenCodeParser: VibeLogParser {
    let source = "qwen-code"
    private let baseDir: String

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    init(baseDir: String? = nil, home: String = NSHomeDirectory()) {
        self.baseDir = baseDir ?? Self.defaultBaseDir(home: home)
    }

    static func defaultBaseDir(home: String) -> String {
        home + "/.qwen/tmp"
    }

    // MARK: - Session file discovery (JS findSessionFiles)

    /// <baseDir>/<project>/chats/*.jsonl, read flat (no recursion).
    private func findSessionFiles() -> [String] {
        guard FileManager.default.fileExists(atPath: baseDir),
              let projects = try? FileManager.default.contentsOfDirectory(atPath: baseDir)
        else { return [] }
        var results: [String] = []
        for entry in projects {
            let projectDir = baseDir + "/" + entry
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let chatsDir = projectDir + "/chats"
            guard FileManager.default.fileExists(atPath: chatsDir),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: chatsDir)
            else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = chatsDir + "/" + file
                var fileIsDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &fileIsDirectory),
                   !fileIsDirectory.boolValue {
                    results.append(path)
                }
            }
        }
        // Sorted for a deterministic snapshot; JS uses readdir order, which
        // only affects which copy of a uuid-duplicated record wins.
        return results.sorted()
    }

    /// JS extractProject: last component of cwd; without a usable cwd, the
    /// <project_id> segment of the file path under the qwen tmp dir.
    private func extractProject(cwd: Any?, filePath: String) -> String {
        if let cwd = Self.jsTruthy(cwd) as? String {
            let parts = cwd.split(separator: "/", omittingEmptySubsequences: true)
            if let last = parts.last { return String(last) }
        }
        let prefix = baseDir + "/"
        if filePath.hasPrefix(prefix) {
            let relative = String(filePath.dropFirst(prefix.count))
            if let projectId = relative.split(separator: "/", omittingEmptySubsequences: true).first {
                return String(projectId)
            }
        }
        return "unknown"
    }

    // MARK: - Per-file scan (mtime/size cached)

    private struct UsageRecord: Sendable {
        /// Truthy obj.uuid — the global cross-file dedupe key (nil: never merged).
        let uuid: String?
        var entry: VibeTokenEntry
    }

    private struct ParsedFile: Sendable {
        var records: [UsageRecord] = []
        var events: [VibeSessionEvent] = []
    }

    private struct FileStamp: Equatable, Sendable {
        let size: Int
        let mtime: TimeInterval
    }

    private struct CacheEntry: Sendable {
        let stamp: FileStamp
        let parsed: ParsedFile
    }

    // Sync runs every 30 minutes; unchanged session files (the vast majority)
    // are re-stated but never re-read, so a full pass costs one directory
    // walk plus reads of files appended since the last run.
    private static let cache = Mutex<[String: CacheEntry]>([:])

    private static func stamp(_ path: String) -> FileStamp? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let size = values.fileSize, let mtime = values.contentModificationDate
        else { return nil }
        return FileStamp(size: size, mtime: mtime.timeIntervalSince1970)
    }

    /// Returns nil when the file cannot be read (caller logs and skips the
    /// file; the JS parser's readFileSync failure is a bare `continue`).
    private func cachedScan(_ path: String) -> ParsedFile? {
        guard let before = Self.stamp(path) else { return nil }
        if let cached = Self.cache.withLock({ $0[path] }), cached.stamp == before {
            return cached.parsed
        }
        guard let parsed = scan(path, byteLimit: before.size) else { return nil }
        // Commit only if the file did not change mid-read; a changing file is
        // rescanned next sync rather than caching a partial aggregate.
        if Self.stamp(path) == before {
            Self.cache.withLock { entries in
                if entries.count >= 4096, entries[path] == nil, let oldest = entries.keys.first {
                    entries.removeValue(forKey: oldest)
                }
                entries[path] = CacheEntry(stamp: before, parsed: parsed)
            }
        }
        return parsed
    }

    /// Read only the file size captured during discovery, so a line Qwen is
    /// appending right now is left for the next sync.
    private func scan(_ path: String, byteLimit: Int) -> ParsedFile? {
        var parsed = ParsedFile()
        let scanned = Self.forEachJSONLine(at: path, byteLimit: byteLimit) { object in
            // JS gates every line on a present, parseable timestamp first.
            guard let rawTimestamp = Self.jsTruthy(object["timestamp"]),
                  let timestamp = Self.jsDate(rawTimestamp)
            else { return }

            let type = object["type"] as? String
            if type == "user" || type == "assistant" {
                parsed.events.append(VibeSessionEvent(
                    sessionId: path, source: source,
                    project: extractProject(cwd: object["cwd"], filePath: path),
                    timestamp: timestamp,
                    role: type == "user" ? .user : .assistant))
            }

            guard type == "assistant",
                  let usage = object["usageMetadata"] as? [String: Any],
                  // JS: `usage.promptTokenCount == null && usage.candidatesTokenCount == null`
                  // skips the entry — a present zero still counts as present.
                  usage["promptTokenCount"] != nil && !(usage["promptTokenCount"] is NSNull)
                    || usage["candidatesTokenCount"] != nil && !(usage["candidatesTokenCount"] is NSNull)
            else { return }

            let cached = Self.firstTruthyNumber(usage["cachedContentTokenCount"])
            let thoughts = Self.firstTruthyNumber(usage["thoughtsTokenCount"])
            let uuid = Self.jsTruthy(object["uuid"]) as? String
            parsed.records.append(UsageRecord(
                uuid: uuid,
                entry: VibeTokenEntry(
                    source: "qwen-code",
                    model: Self.jsTruthy(object["model"]) as? String ?? "unknown",
                    project: extractProject(cwd: object["cwd"], filePath: path),
                    timestamp: timestamp,
                    inputTokens: Self.firstTruthyNumber(usage["promptTokenCount"]) - cached,
                    outputTokens: Self.firstTruthyNumber(usage["candidatesTokenCount"]) - thoughts,
                    cachedInputTokens: cached,
                    reasoningOutputTokens: thoughts)))
        }
        return scanned ? parsed : nil
    }

    // MARK: - Value coercion

    /// The value if it is JS-truthy (not null/undefined, not 0/NaN, not "",
    /// not false), else nil.
    private static func jsTruthy(_ value: Any?) -> Any? {
        switch value {
        case .none, is NSNull:
            return nil
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? value : nil }
            let raw = number.doubleValue
            return raw != 0 && !raw.isNaN ? value : nil
        case let string as String:
            return string.isEmpty ? nil : value
        default:
            return value
        }
    }

    /// JS Number(value) restricted to JSON numbers and numeric strings;
    /// booleans/missing values are no number at all.
    private static func jsNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return 0 }  // Number("") === 0
            guard let raw = Double(trimmed), raw.isFinite else { return nil }
            return raw
        default:
            return nil
        }
    }

    /// JS `a || b || 0` for numbers: the first truthy (non-zero, non-NaN)
    /// coercion wins; everything falsy lands on 0.
    private static func firstTruthyNumber(_ values: Any?...) -> Double {
        for value in values {
            if let number = jsNumber(value), number != 0 { return number }
        }
        return 0
    }

    /// JS `new Date(value)`: epoch milliseconds for numbers, ISO8601 for
    /// strings (with/without fractional seconds).
    private static func jsDate(_ value: Any) -> Date? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        case let string as String:
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
                ?? (try? Date.ISO8601FormatStyle().parse(string))
        default:
            return nil
        }
    }

    // MARK: - Streaming JSONL

    /// Read one 64KB chunk at a time, at most `byteLimit` bytes; retain only
    /// an unfinished row between reads. Corrupt/non-object lines are skipped,
    /// never fatal — Qwen may be appending the final record while we snapshot
    /// it. Message contents are parsed and immediately discarded; only counts
    /// and timestamps are kept. Returns false on I/O failure.
    private static func forEachJSONLine(
        at path: String, byteLimit: Int, consume: ([String: Any]) -> Void
    ) -> Bool {
        guard byteLimit > 0 else { return true }
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? file.close() }
        var pending = Data()
        pending.reserveCapacity(256 * 1024)
        // Data indices are not guaranteed zero-based after removeFirst, so
        // track the cursor as a collection index, never as an integer offset.
        var start = pending.startIndex
        var remaining = byteLimit
        func parse(_ data: Data) {
            autoreleasepool {
                guard let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty,
                    let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { return }
                consume(object)
            }
        }
        while remaining > 0 {
            let chunk: Data
            do { chunk = try file.read(upToCount: min(64 * 1024, remaining)) ?? Data() } catch { return false }
            if chunk.isEmpty { break }
            remaining -= chunk.count
            pending.append(chunk)
            var end = start
            var index = start
            while index < pending.endIndex {
                if pending[index] == 10 {
                    parse(Data(pending[end..<index]))
                    end = pending.index(after: index)
                }
                index = pending.index(after: index)
            }
            start = end
            if pending.distance(from: pending.startIndex, to: start) > 1_048_576 {
                pending.removeFirst(pending.distance(from: pending.startIndex, to: start))
                start = pending.startIndex
            }
        }
        // readline flushes a final newline-less line when the stream ends.
        if start < pending.endIndex { parse(Data(pending[start...])) }
        return true
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        var result = VibeParseResult()
        var seenUuids = Set<String>()
        for file in findSessionFiles() {
            guard let parsed = cachedScan(file) else {
                // JS: readFileSync failure is a bare `continue`; the source
                // has no skipped path.
                Self.logger.warning("qwen-code: cannot read session file \(file, privacy: .public)")
                continue
            }
            result.events.append(contentsOf: parsed.events)
            for record in parsed.records {
                // JS: a truthy uuid dedupes globally, first occurrence wins;
                // uuid-less records are always kept.
                if let uuid = record.uuid {
                    guard seenUuids.insert(uuid).inserted else { continue }
                }
                result.entries.append(record.entry)
            }
        }
        return result
    }
}
