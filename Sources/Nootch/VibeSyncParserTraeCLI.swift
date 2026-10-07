import Foundation
import Synchronization

/// Trae CLI session-cache parser — Swift port of vibe-usage
/// `src/parsers/trae-cli.js` (introduced upstream in cebb532, with the
/// malformed-timestamp handling of 417c631 and the unique-layer summing of
/// 556b1c5).
///
/// Store layout: each LLM session is a directory under the cache root —
///   ~/Library/Caches/trae-cli/sessions/<sessionId>/
///     session.json   (metadata: cwd, model_name)
///     traces.jsonl   (nested tracing spans, token usage in tags)
///     events.jsonl   (agent_start / agent_end / tool_call / message events)
/// VIBE_USAGE_TRAE_CLI_SESSIONS overrides the root (tests / relocated trees).
///
/// Trae writes each LLM call as several nested spans that share one
/// session-level traceID and copy the same usage onto every layer:
///   model.stream.eino  (authoritative: includes reasoning tokens)
///   model.real_call    (duplicate)
///   model.call         (duplicate)
/// model.generate is a separate failover call (different model), not a
/// duplicate. Counting every layer would 3x; merging by traceID with max()
/// collapses a whole session of sequential calls into one request. Keep one
/// unique layer per call — stream.eino plus generate failovers, falling back
/// to real_call then call for older traces — then SUM (556b1c5). Span
/// startTime is microseconds; events carry an ISO created_at. Malformed
/// timestamps are skipped (417c631).
///
/// Documented simplifications vs the JS original:
/// - JS `Number(tag)` accepts booleans; here booleans are treated as missing
///   (consistent with the other ports).
/// - An unreadable traces/events file throws (the JS stream error rejects
///   parse()); the engine then reports the source as failed rather than
///   uploading a partial snapshot.
struct VibeTraeCLIParser: VibeLogParser {
    let source = "trae-cli"
    private let cacheDirs: [String]

    init(
        cacheDirs: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory())
    {
        if let cacheDirs {
            self.cacheDirs = cacheDirs
            return
        }
        self.cacheDirs = Self.resolveCacheDirs(environment: environment, home: home)
    }

    /// JS findTraeCliDataDirs: the VIBE_USAGE_TRAE_CLI_SESSIONS override (when
    /// the directory exists) replaces discovery; else
    /// ~/Library/Caches/trae-cli/sessions when it exists.
    static func resolveCacheDirs(environment: [String: String], home: String = NSHomeDirectory()) -> [String] {
        if let override = environment["VIBE_USAGE_TRAE_CLI_SESSIONS"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return FileManager.default.fileExists(atPath: override) ? [override] : []
        }
        let path = home + "/Library/Caches/trae-cli/sessions"
        return FileManager.default.fileExists(atPath: path) ? [path] : []
    }

    // MARK: - Span selection (556b1c5)

    static let primaryLLMCategory = "model.stream.eino"
    static let failoverLLMCategory = "model.generate"
    static let fallbackLLMCategories = ["model.real_call", "model.call"]

    /// Pick the unique LLM-call spans from a session's traces. Prefer
    /// model.stream.eino (+ model.generate failovers). If a session has no
    /// primary layer (older traces), fall back to model.real_call, then
    /// model.call (JS selectTraeUsageSpans).
    static func selectTraeUsageSpans(_ spans: [VibeTraeUsageSpan]) -> [VibeTraeUsageSpan] {
        let withUsage = spans.filter { $0.hasUsage }
        let primary = withUsage.filter { $0.category == primaryLLMCategory }
        let failover = withUsage.filter { $0.category == failoverLLMCategory }
        if !primary.isEmpty || !failover.isEmpty { return primary + failover }
        for category in fallbackLLMCategories {
            let subset = withUsage.filter { $0.category == category }
            if !subset.isEmpty { return subset }
        }
        return withUsage
    }

    // MARK: - Per-file scans (mtime/size cached)

    /// Timing event without its project: the project comes from session.json,
    /// which is re-read every sync, so the cached events stay project-free.
    private struct RawEvent: Equatable, Sendable {
        let timestamp: Date
        let role: VibeSessionRole
    }

    private struct FileStamp: Equatable, Sendable {
        let size: Int
        let mtime: TimeInterval
    }

    private struct CacheEntry<Payload: Sendable>: Sendable {
        let stamp: FileStamp
        let payload: Payload
    }

    // Sync runs every 30 minutes; unchanged files (the vast majority — events
    // logs alone can exceed 800MB, upstream 556b1c5) are re-stated but never
    // re-read.
    private static let spanCache = Mutex<[String: CacheEntry<[VibeTraeUsageSpan]>]>([:])
    private static let eventCache = Mutex<[String: CacheEntry<[RawEvent]>]>([:])

    private enum ReadError: Error {
        case unreadableFile(String)
    }

    private static func stamp(_ path: String) -> FileStamp? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let size = values.fileSize, let mtime = values.contentModificationDate
        else { return nil }
        return FileStamp(size: size, mtime: mtime.timeIntervalSince1970)
    }

    private static func cached<Payload: Sendable>(
        _ path: String,
        empty: Payload,
        cache: borrowing Mutex<[String: CacheEntry<Payload>]>,
        scan: (String) throws -> Payload
    ) throws -> Payload {
        // JS forEachJsonl skips missing files; do not cache the absence (the
        // file may appear mid-session).
        guard FileManager.default.fileExists(atPath: path) else { return empty }
        guard let before = stamp(path) else { throw ReadError.unreadableFile(path) }
        if let hit = cache.withLock({ $0[path] }), hit.stamp == before { return hit.payload }
        let payload = try scan(path)
        // Commit only if the file did not change mid-read; a changing file is
        // rescanned next sync rather than caching a partial aggregate.
        if stamp(path) == before {
            cache.withLock { entries in
                if entries.count >= 4096, entries[path] == nil, let oldest = entries.keys.first {
                    entries.removeValue(forKey: oldest)
                }
                entries[path] = CacheEntry(stamp: before, payload: payload)
            }
        }
        return payload
    }

    private static func cachedSpans(at path: String) throws -> [VibeTraeUsageSpan] {
        try cached(path, empty: [], cache: spanCache) { try scanSpans(at: $0) }
    }

    private static func cachedEvents(at path: String) throws -> [RawEvent] {
        try cached(path, empty: [], cache: eventCache) { try scanEvents(at: $0) }
    }

    private static func scanSpans(at path: String) throws -> [VibeTraeUsageSpan] {
        var spans: [VibeTraeUsageSpan] = []
        try forEachJSONLine(at: path) { line in
            let tags = tagMap(from: line["tags"])
            let span = VibeTraeUsageSpan(
                category: tags["span.category"] as? String ?? "",
                model: [tags["model.name"], tags["semantic.name"]]
                    .compactMap { $0 as? String }
                    .first { !$0.isEmpty },
                startTime: jsNumber(line["startTime"]) ?? .nan,
                inputTokens: max(0, jsNumber(tags["usage.input_tokens"]) ?? 0),
                outputTokens: max(0, jsNumber(tags["usage.output_tokens"]) ?? 0),
                cacheReadTokens: max(0, jsNumber(tags["usage.cache_read_tokens"]) ?? 0),
                reasoningTokens: max(0, jsNumber(tags["usage.reasoning_tokens"]) ?? 0))
            guard span.hasUsage else { return }
            // 417c631: a malformed startTime must not crash or corrupt the day.
            guard span.startTime.isFinite, span.startTime > 0 else { return }
            spans.append(span)
        }
        return spans
    }

    private static func scanEvents(at path: String) throws -> [RawEvent] {
        var events: [RawEvent] = []
        try forEachJSONLine(at: path) { line in
            guard isTruthy(line["created_at"]), let timestamp = eventDate(line["created_at"]) else { return }
            if isTruthy(line["agent_start"]) {
                events.append(RawEvent(timestamp: timestamp, role: .user))
            } else if isTruthy(line["agent_end"]) || isTruthy(line["tool_call"]) || isAssistantMessage(line) {
                events.append(RawEvent(timestamp: timestamp, role: .assistant))
            }
        }
        return events
    }

    private static func isAssistantMessage(_ line: [String: Any]) -> Bool {
        ((line["message"] as? [String: Any])?["message"] as? [String: Any])?["role"] as? String == "assistant"
    }

    // MARK: - Value coercion

    private static func tagMap(from tags: Any?) -> [String: Any] {
        var map: [String: Any] = [:]
        guard let tags = tags as? [Any] else { return map }
        for case let tag as [String: Any] in tags {
            if let key = tag["key"] as? String, !key.isEmpty, let value = tag["value"] {
                map[key] = value
            }
        }
        return map
    }

    /// JS readJsonSafe: parsed object, or nil on any failure.
    private static func readJSONDictionary(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    /// Last path component of an absolute path, or 'unknown' (JS
    /// projectFromPath; posix basename — Windows separators stay intact).
    private static func projectFromPath(_ value: Any?) -> String {
        guard let path = value as? String, !path.isEmpty else { return "unknown" }
        var trimmed = path
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        let name = trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return name.isEmpty ? "unknown" : name
    }

    /// Event timestamp: ISO strings, or epoch milliseconds for numbers
    /// (JS `new Date(line.created_at)`).
    private static func eventDate(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            return parseISODate(string)
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        default:
            return nil
        }
    }

    /// JS `new Date(string)` restricted to ISO-8601 shapes (with or without
    /// fractional seconds / numeric offsets).
    private static func parseISODate(_ string: String) -> Date? {
        if let parsed = VibeSyncTime.parse(string) { return parsed }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: string) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
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

    private static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case .none, is NSNull:
            return false
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : number.doubleValue != 0
        case let string as String:
            return !string.isEmpty
        default:
            return true
        }
    }

    // MARK: - Streaming JSONL

    /// Stream a JSONL file line by line (556b1c5: streaming, so an 800MB+
    /// events.jsonl cannot hit memory limits), skipping blank and malformed
    /// lines. Throws on I/O failure (the JS stream error rejects parse()).
    private static func forEachJSONLine(at path: String, consume: ([String: Any]) -> Void) throws {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var pending = Data()
        pending.reserveCapacity(256 * 1024)
        // Data indices are not guaranteed zero-based after removeFirst, so
        // track the cursor as a collection index, never as an integer offset.
        var start = pending.startIndex
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
        while true {
            let chunk = try file.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
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
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        var result = VibeParseResult()
        for cacheDir in cacheDirs {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) else { continue }
            for sessionId in children.sorted() {
                let sessionPath = cacheDir + "/" + sessionId
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sessionPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                let sessionJson = Self.readJSONDictionary(at: sessionPath + "/session.json")
                let metadata = sessionJson?["metadata"] as? [String: Any]
                let project = Self.projectFromPath(metadata?["cwd"])
                // JS: sessionJson.metadata?.model_name || 'trae-unknown'.
                let configuredModel = (metadata?["model_name"] as? String) ?? ""
                let fallbackModel = configuredModel.isEmpty ? "trae-unknown" : configuredModel

                for span in Self.selectTraeUsageSpans(try Self.cachedSpans(at: sessionPath + "/traces.jsonl")) {
                    result.entries.append(VibeTokenEntry(
                        source: source, model: span.model ?? fallbackModel, project: project,
                        // Trae startTime is microseconds; Date expects seconds.
                        timestamp: Date(timeIntervalSince1970: span.startTime / 1_000_000),
                        inputTokens: span.inputTokens, outputTokens: span.outputTokens,
                        cachedInputTokens: span.cacheReadTokens,
                        reasoningOutputTokens: span.reasoningTokens))
                }

                for event in try Self.cachedEvents(at: sessionPath + "/events.jsonl") {
                    result.events.append(VibeSessionEvent(
                        sessionId: sessionId, source: source, project: project,
                        timestamp: event.timestamp, role: event.role))
                }
            }
        }
        return result
    }
}

/// One tracing span's token usage (JS {category, model, startTime, usage}).
/// startTime is microseconds since the epoch, as Trae writes it.
struct VibeTraeUsageSpan: Equatable, Sendable {
    var category: String
    var model: String?
    var startTime: Double
    var inputTokens: Double
    var outputTokens: Double
    var cacheReadTokens: Double
    var reasoningTokens: Double

    var hasUsage: Bool {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens > 0
    }
}
