import Foundation
import OSLog
import Synchronization

/// GitHub Copilot CLI log parser — Swift port of vibe-usage
/// `src/parsers/copilot-cli.js` (main @ c55b82c1; parser added in e189fb40;
/// no post-2026-08 fixes).
///
/// Layout: ~/.copilot/session-state/<sessionId>/events.jsonl — one event per
/// line. `session.start` / `session.resume` carry data.context.gitRoot/cwd and
/// set the session's project (posix basename, "unknown" before the first such
/// event); `user.message` / `assistant.message` are the timing events;
/// `session.shutdown` carries the usage summary in data.modelMetrics, keyed
/// by model id. The session id is the *directory* name, not the file path.
///
/// Entry mapping per model in a shutdown summary: inputTokens =
/// max(0, inputTokens − cacheReadTokens) (Copilot reports cache reads
/// separately), outputTokens = outputTokens, cachedInputTokens =
/// cacheReadTokens, reasoning = 0. cacheWriteTokens only participates in the
/// all-zero gate (a cache-write-only model still emits an entry); the writes
/// themselves are already part of the reported input for this schema, and
/// cacheCreation5m/1h stay 0. A model whose four counters are all zero is
/// skipped; a modelMetrics entry without a `usage` object is skipped.
///
/// Documented simplifications vs the JS original:
/// - The JS parser has no `skipped` path: an unreadable file is silently
///   dropped (`continue`). Here that logs through OSLog; the source still
///   reports skipped == false.
/// - Timestamps parse as ISO8601 strings (with/without fractional seconds) or
///   epoch-millisecond numbers; JS `new Date(value)` accepts a few more
///   formats Copilot never writes.
/// - JS `Number`-style coercion is restricted to JSON numbers and numeric
///   strings; booleans are treated as missing (repo-wide convention).
/// - modelMetrics is iterated in sorted model order (JS uses insertion
///   order); the aggregates are identical either way.
struct VibeCopilotCliParser: VibeLogParser {
    let source = "copilot-cli"
    private let baseDir: String

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    init(baseDir: String? = nil, home: String = NSHomeDirectory()) {
        self.baseDir = baseDir ?? Self.defaultBaseDir(home: home)
    }

    static func defaultBaseDir(home: String) -> String {
        home + "/.copilot/session-state"
    }

    // MARK: - Event file discovery (JS findEventFiles)

    /// Every <baseDir>/<sessionId>/events.jsonl; the session id is the
    /// directory name.
    private func findEventFiles() -> [(path: String, sessionId: String)] {
        guard FileManager.default.fileExists(atPath: baseDir),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: baseDir)
        else { return [] }
        var results: [(String, String)] = []
        for entry in entries {
            let path = baseDir + "/" + entry
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let eventsFile = path + "/events.jsonl"
            if FileManager.default.fileExists(atPath: eventsFile) {
                results.append((eventsFile, entry))
            }
        }
        // Sorted for a deterministic snapshot; JS uses readdir order, which
        // only affects entry ordering, never the aggregates.
        return results.sorted { $0.0 < $1.0 }
    }

    /// JS getProjectFromContext: gitRoot wins over cwd (both `||`-truthy),
    /// then posix basename; anything empty is "unknown".
    private static func projectFromContext(_ context: [String: Any]?) -> String {
        let path = jsTruthy(context?["gitRoot"]) ?? jsTruthy(context?["cwd"])
        guard let raw = path else { return "unknown" }
        var string = String(describing: raw)
        while string.hasSuffix("/") { string.removeLast() }
        let base = string.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return base.isEmpty ? "unknown" : base
    }

    // MARK: - Per-file scan (mtime/size cached)

    private struct ParsedFile: Sendable {
        var entries: [VibeTokenEntry] = []
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

    // Sync runs every 30 minutes; unchanged event logs (the vast majority)
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
    private func cachedScan(_ path: String, sessionId: String) -> ParsedFile? {
        guard let before = Self.stamp(path) else { return nil }
        if let cached = Self.cache.withLock({ $0[path] }), cached.stamp == before {
            return cached.parsed
        }
        guard let parsed = scan(path, byteLimit: before.size, sessionId: sessionId) else { return nil }
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

    /// Read only the file size captured during discovery, so a line Copilot is
    /// appending right now is left for the next sync.
    private func scan(_ path: String, byteLimit: Int, sessionId: String) -> ParsedFile? {
        var parsed = ParsedFile()
        var currentProject = "unknown"
        let scanned = Self.forEachJSONLine(at: path, byteLimit: byteLimit) { object in
            let type = object["type"] as? String
            let timestamp = Self.jsTruthy(object["timestamp"]).flatMap(Self.jsDate)

            // Project context updates apply with or without a valid timestamp
            // (JS assigns before the timestamp checks).
            if type == "session.start" || type == "session.resume" {
                let data = object["data"] as? [String: Any]
                currentProject = Self.projectFromContext(data?["context"] as? [String: Any])
            }

            if let timestamp, type == "user.message" || type == "assistant.message" {
                parsed.events.append(VibeSessionEvent(
                    sessionId: sessionId, source: source, project: currentProject,
                    timestamp: timestamp,
                    role: type == "user.message" ? .user : .assistant))
            }

            guard type == "session.shutdown", let timestamp else { return }
            let data = object["data"] as? [String: Any]
            guard let modelMetrics = data?["modelMetrics"] as? [String: Any] else { return }
            for model in modelMetrics.keys.sorted() {
                guard let metrics = modelMetrics[model] as? [String: Any],
                      let usage = metrics["usage"] as? [String: Any]
                else { continue }
                let totalInput = Self.firstTruthyNumber(usage["inputTokens"])
                let cachedRead = Self.firstTruthyNumber(usage["cacheReadTokens"])
                let cacheWrite = Self.firstTruthyNumber(usage["cacheWriteTokens"])
                let output = Self.firstTruthyNumber(usage["outputTokens"])
                // JS strict zero gate: all four counters exactly 0 → skip.
                if totalInput == 0, cachedRead == 0, cacheWrite == 0, output == 0 { continue }
                parsed.entries.append(VibeTokenEntry(
                    source: "copilot-cli",
                    model: model,
                    project: currentProject,
                    timestamp: timestamp,
                    // Copilot reports cache reads separately; cache writes are
                    // already part of the reported input for this schema.
                    inputTokens: max(0, totalInput - cachedRead),
                    outputTokens: output,
                    cachedInputTokens: cachedRead,
                    reasoningOutputTokens: 0))
            }
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
    /// never fatal — Copilot may be appending the final record while we
    /// snapshot it. Event payloads are parsed and immediately discarded; only
    /// counts and timestamps are kept. Returns false on I/O failure.
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
        for (path, sessionId) in findEventFiles() {
            guard let parsed = cachedScan(path, sessionId: sessionId) else {
                // JS: readFileSync failure is a bare `continue`; the source
                // has no skipped path.
                Self.logger.warning("copilot-cli: cannot read event file \(path, privacy: .public)")
                continue
            }
            result.entries.append(contentsOf: parsed.entries)
            result.events.append(contentsOf: parsed.events)
        }
        return result
    }
}
