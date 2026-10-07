import Foundation
import OSLog
import Synchronization

/// Gemini CLI log parser — Swift port of vibe-usage `src/parsers/gemini-cli.js`
/// (main @ c55b82c1; includes the .jsonl session-format migration of df058c50
/// and the cached/reasoning normalization of dc879305; no post-2026-08 fixes).
///
/// Session storage (all under ~/.gemini/tmp):
///   <project_hash>/chats/session-<ts>-<id>.jsonl   (current, v0.39+)
///   <project_hash>/chats/session-<ts>-<id>.json    (legacy, one JSON object)
///   <project_hash>/chats/<parent_id>/<sub_id>.jsonl (subagent sessions, nested)
/// Both extensions are collected, recursing at most two levels below chats/
/// (JS collectChatFiles).
///
/// A .jsonl file opens with a metadata line carrying `directories`; every
/// following line with a string `type` or `role` is a message. A .json file is
/// a single ConversationRecord with a messages[] (or history[]) array. The
/// file's project is the basename of directories[0] ("unknown" when absent).
///
/// Tokens live in msg.tokens.{input,output,cached,thoughts} (TokensSummary,
/// where `input` already includes cached and `output` includes thoughts), so
/// the entry reports the split: input = input − cached, output = output −
/// thoughts. Legacy records with raw API usageMetadata (or `usage`) fall back
/// to promptTokenCount/candidatesTokenCount minus cachedContent/thoughts.
/// Assistant messages with a tokens block emit an entry even when every count
/// is zero (JS pushes unconditionally once extractTokens matches). Cache
/// writes have no distinct field in this store; cacheCreation5m/1h stay 0.
///
/// Documented simplifications vs the JS original:
/// - The JS parser has no `skipped` path: an unreadable or unparseable file is
///   silently dropped (`continue`). Here that logs through OSLog and the file
///   contributes nothing; the source still reports skipped == false.
/// - Timestamps parse as ISO8601 strings (with/without fractional seconds) or
///   epoch-millisecond numbers; JS `new Date(value)` accepts a few more
///   formats Gemini never writes.
/// - JS `Number`-style coercion is restricted to JSON numbers and numeric
///   strings; booleans are treated as missing (repo-wide convention).
struct VibeGeminiCliParser: VibeLogParser {
    let source = "gemini-cli"
    private let baseDir: String

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    init(baseDir: String? = nil, home: String = NSHomeDirectory()) {
        self.baseDir = baseDir ?? Self.defaultBaseDir(home: home)
    }

    static func defaultBaseDir(home: String) -> String {
        home + "/.gemini/tmp"
    }

    // MARK: - Session file discovery (JS findSessionFiles / collectChatFiles)

    private func findSessionFiles() -> [String] {
        guard FileManager.default.fileExists(atPath: baseDir),
              let projects = try? FileManager.default.contentsOfDirectory(atPath: baseDir)
        else { return [] }
        var results: [String] = []
        for entry in projects {
            let path = baseDir + "/" + entry
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            collectChatFiles(path + "/chats", depth: 0, into: &results)
        }
        // Sorted for a deterministic snapshot; JS uses readdir order, which
        // only affects entry ordering, never the aggregates.
        return results.sorted()
    }

    private func collectChatFiles(_ directory: String, depth: Int, into results: inout [String]) {
        // chats/ + nested subagent dirs is as deep as it goes (JS depth guard).
        guard depth <= 2,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return }
        for entry in entries {
            let path = directory + "/" + entry
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                collectChatFiles(path, depth: depth + 1, into: &results)
            } else if entry.hasSuffix(".jsonl") || entry.hasSuffix(".json") {
                results.append(path)
            }
        }
    }

    // MARK: - Per-file scan (mtime/size cached)

    /// One classified message, reduced to the fields the result needs; the
    /// file-level project is attached after the scan (JS resolves
    /// `directories` from the whole file before processing any message).
    private struct MessageRecord: Sendable {
        let role: VibeSessionRole
        let timestamp: Date
        let model: String
        let tokens: (input: Double, output: Double, cached: Double, reasoning: Double)?
    }

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
    /// file; the JS parser's readRecords returns null and moves on).
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

    private func scan(_ path: String, byteLimit: Int) -> ParsedFile? {
        if path.hasSuffix(".jsonl") {
            return scanJSONL(path, byteLimit: byteLimit)
        }
        return scanLegacyJSON(path, byteLimit: byteLimit)
    }

    /// .jsonl: line 1 is session metadata (carries `directories`); each
    /// following line with a string `type` or `role` is one message.
    private func scanJSONL(_ path: String, byteLimit: Int) -> ParsedFile? {
        var directories: [Any]?
        var messages: [MessageRecord] = []
        let scanned = Self.forEachJSONLine(at: path, byteLimit: byteLimit) { object in
            // The metadata line carries directories; message lines carry a
            // `type`. The first line with a directories array wins (JS).
            if directories == nil, let value = object["directories"] as? [Any] {
                directories = value
            }
            guard (object["type"] as? String) != nil || (object["role"] as? String) != nil,
                  let record = Self.messageRecord(object)
            else { return }
            messages.append(record)
        }
        guard scanned else { return nil }
        return assemble(messages: messages, directories: directories, sessionId: path)
    }

    /// Legacy .json: a single ConversationRecord with a messages[] array
    /// (history[] on even older builds).
    private func scanLegacyJSON(_ path: String, byteLimit: Int) -> ParsedFile? {
        guard byteLimit > 0,
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return nil }
        defer { try? file.close() }
        let data: Data
        do { data = try file.read(upToCount: byteLimit) ?? Data() } catch { return nil }
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // JS `data.messages || data.history || []`; a non-array value is
        // treated as empty here (JS would throw iterating it).
        let rawMessages = (object["messages"] as? [Any]) ?? (object["history"] as? [Any]) ?? []
        let messages = rawMessages.compactMap { ($0 as? [String: Any]).flatMap(Self.messageRecord) }
        return assemble(
            messages: messages,
            directories: object["directories"] as? [Any],
            sessionId: path)
    }

    /// Attach the file-level project and split records into entries/events
    /// (JS: events for every classified message, entries for assistant
    /// messages that carry tokens — pushed even when all counts are zero).
    private func assemble(
        messages: [MessageRecord], directories: [Any]?, sessionId: String
    ) -> ParsedFile {
        let project = Self.projectFromDirectories(directories)
        var parsed = ParsedFile()
        for record in messages {
            parsed.events.append(VibeSessionEvent(
                sessionId: sessionId, source: source, project: project,
                timestamp: record.timestamp, role: record.role))
            guard record.role == .assistant, let tokens = record.tokens else { continue }
            parsed.entries.append(VibeTokenEntry(
                source: source,
                model: record.model,
                project: project,
                timestamp: record.timestamp,
                inputTokens: tokens.input,
                outputTokens: tokens.output,
                cachedInputTokens: tokens.cached,
                reasoningOutputTokens: tokens.reasoning))
        }
        return parsed
    }

    // MARK: - Message mapping

    /// JS classifyRole + timestamp gate: model/assistant messages are recorded
    /// as type 'gemini', user turns as 'user'; info/error/warning are system
    /// noise and skipped. `role` is a fallback for older formats. Records
    /// without a valid `timestamp`/`createTime` are dropped entirely.
    private static func messageRecord(_ object: [String: Any]) -> MessageRecord? {
        guard let role = classifyRole(object) else { return nil }
        guard let stamp = jsTruthy(object["timestamp"]) ?? jsTruthy(object["createTime"]),
              let timestamp = jsDate(stamp)
        else { return nil }
        let tokens: (input: Double, output: Double, cached: Double, reasoning: Double)? =
            role == .assistant ? extractTokens(object) : nil
        let model = jsTruthy(object["model"]) as? String ?? "unknown"
        return MessageRecord(role: role, timestamp: timestamp, model: model, tokens: tokens)
    }

    /// JS classifyRole: `msg.type ?? msg.role` — a present non-null `type`
    /// wins even when it is not a string (which then matches nothing).
    private static func classifyRole(_ message: [String: Any]) -> VibeSessionRole? {
        let type = (message["type"] is NSNull) ? nil : message["type"]
        let role = (message["role"] is NSNull) ? nil : message["role"]
        guard let value = (type ?? role) as? String else { return nil }
        switch value {
        case "user": return .user
        case "gemini", "model", "assistant": return .assistant
        default: return nil
        }
    }

    /// JS extractTokens. TokensSummary counts are inclusive, so cached/thoughts
    /// are split out by subtraction (no clamping — JS keeps negatives).
    private static func extractTokens(
        _ message: [String: Any]
    ) -> (input: Double, output: Double, cached: Double, reasoning: Double)? {
        if let raw = jsTruthy(message["tokens"]) {
            let tokens = raw as? [String: Any] ?? [:]
            let cached = firstTruthyNumber(tokens["cached"])
            let thoughts = firstTruthyNumber(tokens["thoughts"])
            return (firstTruthyNumber(tokens["input"]) - cached,
                    firstTruthyNumber(tokens["output"]) - thoughts,
                    cached, thoughts)
        }
        if let raw = jsTruthy(message["usageMetadata"]) ?? jsTruthy(message["usage"]) {
            let usage = raw as? [String: Any] ?? [:]
            let cached = firstTruthyNumber(usage["cachedContentTokenCount"])
            let thoughts = firstTruthyNumber(usage["thoughtsTokenCount"])
            return (firstTruthyNumber(usage["promptTokenCount"], usage["input_tokens"]) - cached,
                    firstTruthyNumber(usage["candidatesTokenCount"], usage["output_tokens"]) - thoughts,
                    cached, thoughts)
        }
        return nil
    }

    /// JS projectFromDirectories: basename of the first directory (trailing
    /// slashes stripped), "unknown" when the list or its first element is
    /// missing. Posix basename semantics: only "/" separates components.
    private static func projectFromDirectories(_ directories: [Any]?) -> String {
        guard let first = directories?.first, let value = jsTruthy(first) else { return "unknown" }
        var string = String(describing: value)
        while string.hasSuffix("/") || string.hasSuffix("\\") { string.removeLast() }
        let base = string.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return base.isEmpty ? "unknown" : base
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
    /// never fatal — Gemini may be appending the final record while we
    /// snapshot it. Message contents are parsed and immediately discarded;
    /// only counts and timestamps are kept. Returns false on I/O failure.
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
        for file in findSessionFiles() {
            guard let parsed = cachedScan(file) else {
                // JS readRecords returns null on read/parse failure and the
                // file is simply dropped; the source has no skipped path.
                Self.logger.warning("gemini-cli: cannot read session file \(file, privacy: .public)")
                continue
            }
            result.entries.append(contentsOf: parsed.entries)
            result.events.append(contentsOf: parsed.events)
        }
        return result
    }
}
