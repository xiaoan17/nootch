import Foundation
import OSLog
import Synchronization

/// CodeBuddy Code (Tencent's terminal agent, `@tencent-ai/codebuddy-code`) log
/// parser — Swift port of vibe-usage `src/parsers/codebuddy.js` (introduced in
/// upstream feb7ec4, with the real-record model/dedupe-key fixes of 08c3129).
///
/// The store follows Claude Code's layout:
///   <home>/projects/<compressed-cwd>/<sessionId>.jsonl   (+ nested subagent dirs)
/// where <home> is `$CODEBUDDY_CONFIG_DIR` or ~/.codebuddy. Roots: the
/// VIBE_USAGE_CODEBUDDY_DIRS override (path-list separator ":", tests /
/// relocated trees) replaces discovery; else the single configured/default home.
///
/// Two record shapes live in those transcripts (verified upstream against
/// 2.151.0's own writer and a real store): local turns are
/// `{type:"message", role:"user"|…, content, sessionId, cwd}`, while every
/// successful model call is the API message shape — `{message:{id, model,
/// role:"assistant", usage:{input_tokens, output_tokens,
/// cache_read_input_tokens, cache_creation_input_tokens}}}` — so token
/// accounting reads `message.usage` only. `usage.cache_creation` (the per-TTL
/// breakdown) is written as `null`, so cache writes fold into inputTokens and
/// cannot be priced per TTL (cacheCreation5m/1h stay 0, matching every parser
/// that has no split).
///
/// Timestamps are epoch milliseconds in a numeric `timestamp` field (not
/// Claude's ISO strings).
///
/// Dedupe (08c3129): real call records carry no `message.id`, so the identity
/// chain is `message.id` → `providerData.messageId` → the record's own `id`,
/// keyed as "call:<identity>"; `conversationRequestId` is a *turn* id (one turn
/// can hold several billable calls) and is explicitly not a key. Records with
/// no identity at all are always kept (never merged), and a copied/retried call
/// keeps the highest usageScore payload. Model (08c3129): `message.model` →
/// `providerData.requestModelId` → `providerData.model` → "unknown".
/// Provider routing/tier labels ('auto', 'default', …) are not model ids and
/// server-side pricing matches the model string alone, so they are namespaced
/// with the tool prefix (`codebuddy-auto`) to never bill at another vendor's
/// rate; concrete ids pass through untouched.
///
/// Documented simplifications vs the JS original:
/// - The JS `warnings` array has no VibeParseResult equivalent: an unreadable
///   directory mid-walk logs through OSLog (like the grok parser) and is not
///   fatal, matching the JS warning-only behavior; an unreadable transcript
///   *file* makes the whole source report `{skipped: true}` with empty output,
///   exactly like the JS result, so its previous upload state survives.
/// - JS `Number(value)` accepts booleans and a few more oddities; here
///   booleans are treated as missing (consistent with the other ports).
/// - No best-copy-across-roots resolution (that is claude-code specific): the
///   JS parser reads every transcript under every root and relies on the
///   global dedupe key to collapse copies; the Swift port does the same.
struct VibeCodeBuddyParser: VibeLogParser {
    let source = "codebuddy"
    private let roots: [String]

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    init(
        roots: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory())
    {
        if let roots {
            self.roots = roots
            return
        }
        self.roots = Self.resolveRoots(environment: environment, home: home)
    }

    /// JS getCodebuddyRoots: VIBE_USAGE_CODEBUDDY_DIRS (path-list separator
    /// ":", entries trimmed) replaces all discovery; else the single root
    /// $CODEBUDDY_CONFIG_DIR or ~/.codebuddy.
    static func resolveRoots(environment: [String: String], home: String = NSHomeDirectory()) -> [String] {
        if let override = environment["VIBE_USAGE_CODEBUDDY_DIRS"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return override.split(separator: ":")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let configured = environment["CODEBUDDY_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
           !configured.isEmpty {
            return [configured]
        }
        return [home + "/.codebuddy"]
    }

    // MARK: - Transcript discovery

    /// Session id of a transcript file, and the project fallback from its
    /// folder (JS fileIdentity): the last dash-component of the first relative
    /// path segment ("private-tmp-cb-probe" → "probe").
    private static func fileIdentity(_ path: String, projectsDir: String) -> (sessionId: String, fallback: String) {
        let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let relative = path.hasPrefix(projectsDir + "/") ? String(path.dropFirst(projectsDir.count + 1)) : ""
        let folder = relative.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let fallback = folder.split(separator: "-", omittingEmptySubsequences: true).last.map(String.init) ?? "unknown"
        return (sessionId, fallback)
    }

    /// Recursive *.jsonl collection under <root>/projects. A missing projects
    /// dir is simply empty; an unreadable existing branch logs a warning and
    /// is skipped (JS findTranscripts warns without failing the source).
    private func findTranscripts(_ root: String) -> (projectsDir: String, files: [String]) {
        let projectsDir = root + "/projects"
        guard FileManager.default.fileExists(atPath: projectsDir) else { return (projectsDir, []) }
        var files: [String] = []
        func walk(_ directory: String) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                Self.logger.warning("codebuddy: cannot read directory \(directory, privacy: .public)")
                return
            }
            for entry in entries {
                let path = directory + "/" + entry
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    walk(path)
                } else if entry.hasSuffix(".jsonl") {
                    files.append(path)
                }
            }
        }
        walk(projectsDir)
        return (projectsDir, files)
    }

    // MARK: - Per-file scan (mtime/size cached)

    private struct UsageRecord: Sendable {
        let dedupeKey: String?
        let usageScore: Double
        let sessionId: String
        var entry: VibeTokenEntry
    }

    private struct ParsedFile: Sendable {
        var keyed: [String: UsageRecord] = [:]
        var anonymous: [UsageRecord] = []
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

    /// Returns nil when the file cannot be read (caller marks the source
    /// skipped; JS sets skipped and discards the source's whole snapshot).
    private func cachedScan(_ path: String, sessionId: String, fallback: String) -> ParsedFile? {
        guard let before = Self.stamp(path) else { return nil }
        if let cached = Self.cache.withLock({ $0[path] }), cached.stamp == before {
            return cached.parsed
        }
        guard let parsed = scan(path, byteLimit: before.size, sessionId: sessionId, fallback: fallback)
        else { return nil }
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

    /// Read only the file size captured during discovery, so a line CodeBuddy
    /// is appending right now is left for the next sync.
    private func scan(_ path: String, byteLimit: Int, sessionId: String, fallback: String) -> ParsedFile? {
        var parsed = ParsedFile()
        let scanned = Self.forEachJSONLine(at: path, byteLimit: byteLimit) { object in
            if let record = Self.usageEntry(object, fallback: fallback, sessionId: sessionId) {
                Self.mergeUsageRecord(into: &parsed, record)
                // The timing event uses readTimestamp (numeric `timestamp`
                // only), not the entry timestamp — a call whose entry time
                // came from message.timestamp still emits no event here, as in JS.
                if let timestamp = Self.readTimestamp(object["timestamp"]) {
                    parsed.events.append(VibeSessionEvent(
                        sessionId: record.sessionId, source: source, project: record.entry.project,
                        timestamp: timestamp, role: .assistant))
                }
                return
            }
            if Self.isHumanPrompt(object), let timestamp = Self.readTimestamp(object["timestamp"]) {
                parsed.events.append(VibeSessionEvent(
                    sessionId: Self.recordSessionId(object, fallback: sessionId),
                    source: source,
                    // JS: projectFromCwd(obj.cwd) || fallback — projectFromCwd's
                    // own default is 'unknown' (a truthy string), so the folder
                    // fallback is unreachable for user events; kept for parity.
                    project: Self.projectFromCwd(object["cwd"], fallback: "unknown"),
                    timestamp: timestamp, role: .user))
            }
        }
        return scanned ? parsed : nil
    }

    // MARK: - Usage mapping

    private static func mergeUsageRecord(into context: inout ParsedFile, _ record: UsageRecord) {
        guard let key = record.dedupeKey else {
            context.anonymous.append(record)
            return
        }
        // Retries/copies of one call share the dedupe key; keep the most
        // complete payload, so a zeroed copy never wins (JS merge behavior).
        if let current = context.keyed[key], current.usageScore >= record.usageScore { return }
        context.keyed[key] = record
    }

    /// One usage-bearing assistant message (JS usageEntry). Cache writes fold
    /// into input — the store writes `usage.cache_creation` as null, so there
    /// is no TTL breakdown to split by. All-zero rows emit nothing.
    private static func usageEntry(
        _ object: [String: Any], fallback: String, sessionId: String
    ) -> UsageRecord? {
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = entryTimestamp(object)
        else { return nil }

        let cacheWrite = toCount(usage["cache_creation_input_tokens"])
        let inputTokens = toCount(usage["input_tokens"]) + cacheWrite
        let outputTokens = toCount(usage["output_tokens"])
        let cachedInputTokens = toCount(usage["cache_read_input_tokens"])
        guard inputTokens > 0 || outputTokens > 0 || cachedInputTokens > 0 else { return nil }

        let providerData = object["providerData"] as? [String: Any]
        let messageId = trimmed(message["id"])
        let providerMessageId = trimmed(providerData?["messageId"])
        let ownId = trimmed(object["id"])
        // The CLI leaves `message.id` empty on some builds and keeps the
        // per-message id in providerData; `conversationRequestId` is a *turn*
        // id (one turn can hold several billable calls), so it is explicitly
        // not a dedup key. Without this chain every call collapses onto one
        // empty key and the session under-counts (upstream 08c3129).
        let identity = !messageId.isEmpty ? messageId : (!providerMessageId.isEmpty ? providerMessageId : ownId)
        let dedupeKey = identity.isEmpty ? nil : "call:\(identity)"

        let rawModel = [message["model"], providerData?["requestModelId"], providerData?["model"]]
            .compactMap { $0 as? String }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "unknown"

        return UsageRecord(
            dedupeKey: dedupeKey,
            usageScore: inputTokens + outputTokens + cachedInputTokens,
            sessionId: recordSessionId(object, fallback: sessionId),
            entry: VibeTokenEntry(
                source: "codebuddy",
                model: normalizeModel(rawModel),
                project: projectFromCwd(object["cwd"], fallback: fallback),
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                reasoningOutputTokens: 0))
    }

    /// Provider routing/tier labels are not model ids; namespace them with the
    /// tool prefix so they can never match another vendor's price (the Qoder
    /// #83 bug). Concrete ids pass through untouched (JS normalizeModel).
    private static let routingTierIds: Set<String> = [
        "auto", "default", "default-model", "fast", "turbo", "lite",
        "ultimate", "performance", "efficient",
    ]

    private static func normalizeModel(_ model: String) -> String {
        routingTierIds.contains(model.lowercased()) ? "codebuddy-\(model.lowercased())" : model
    }

    /// Human prompt? Local user turns only — the CLI marks injected/system
    /// text (JS isHumanPrompt).
    private static func isHumanPrompt(_ object: [String: Any]) -> Bool {
        let role = (object["role"] as? String) ?? ((object["message"] as? [String: Any])?["role"] as? String)
        guard role == "user" else { return false }
        guard let providerData = object["providerData"] as? [String: Any] else { return true }
        for key in ["isMeta", "skipRun", "isSessionSeparator", "isCompactSummary"]
        where isTruthy(providerData[key]) {
            return false
        }
        return true
    }

    private static func recordSessionId(_ object: [String: Any], fallback: String) -> String {
        guard let sessionId = object["sessionId"] as? String, !sessionId.isEmpty else { return fallback }
        return sessionId
    }

    // MARK: - Value coercion

    /// JS usageEntry timestamp: `Number(obj.timestamp) ||
    /// Date.parse(obj.message?.timestamp)` — numeric epoch milliseconds on the
    /// record win (0/NaN fall through), then an ISO string on the message.
    private static func entryTimestamp(_ object: [String: Any]) -> Date? {
        if let milliseconds = jsNumber(object["timestamp"]), milliseconds != 0 {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let message = object["message"] as? [String: Any],
           let string = message["timestamp"] as? String {
            return VibeSyncTime.parse(string)
        }
        return nil
    }

    /// JS readTimestamp: `Number(obj?.timestamp)`, any finite result counts
    /// (including 0 — unlike the entry timestamp chain).
    private static func readTimestamp(_ value: Any?) -> Date? {
        guard let milliseconds = jsNumber(value) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
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

    /// JS toCount: Number(value), kept when finite and positive, else 0.
    private static func toCount(_ value: Any?) -> Double {
        guard let raw = jsNumber(value), raw > 0 else { return 0 }
        return raw
    }

    private static func trimmed(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
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

    /// Last path component of a cwd value, Unix or Windows separators
    /// (JS projectFromCwd).
    private static func projectFromCwd(_ value: Any?, fallback: String) -> String {
        guard let cwd = value as? String else { return fallback }
        var trimmed = cwd.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fallback
    }

    // MARK: - Streaming JSONL

    /// Read one 64KB chunk at a time, at most `byteLimit` bytes; retain only
    /// an unfinished row between reads. Corrupt/non-object lines are skipped,
    /// never fatal — CodeBuddy may be appending the final record while we
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
        var failed = false
        var merged = ParsedFile()

        for root in roots {
            let (projectsDir, files) = findTranscripts(root)
            for file in files {
                let identity = Self.fileIdentity(file, projectsDir: projectsDir)
                guard let parsed = cachedScan(file, sessionId: identity.sessionId, fallback: identity.fallback)
                else {
                    // A transcript that cannot be read means this source's
                    // snapshot is incomplete: skip the source so its previous
                    // upload state survives.
                    failed = true
                    continue
                }
                for record in parsed.anonymous { Self.mergeUsageRecord(into: &merged, record) }
                for record in parsed.keyed.values { Self.mergeUsageRecord(into: &merged, record) }
                result.events.append(contentsOf: parsed.events)
            }
        }

        // JS: skipped returns `{buckets: [], sessions: [], skipped: true}`.
        if failed { return VibeParseResult(skipped: true) }

        // Deterministic order: keyed entries sort by dedupe key so a cached
        // re-parse yields a byte-identical snapshot (Dictionary iteration
        // order differs between fresh scans and cache hits).
        result.entries = merged.anonymous.map(\.entry)
            + merged.keyed.keys.sorted().compactMap { merged.keyed[$0]?.entry }
        return result
    }
}
