import Foundation
import OSLog
import Synchronization

/// WorkBuddy log parser — Swift port of vibe-usage `src/parsers/workbuddy.js`
/// (introduced upstream in cb255fb, with the current-store / function_call
/// fixes of ebe797e).
///
/// Store layout: `<home>/projects/<encoded-cwd>/<session>.jsonl` under two
/// roots — the current ~/.workbuddy-ai and the legacy ~/.workbuddy (ebe797e).
/// The VIBE_USAGE_WORKBUDDY_DIRS override (path-list separator ":") replaces
/// discovery for tests/relocated trees; entries may name either the WorkBuddy
/// home or its projects/ directory — both forms normalize to the projects dir
/// (src/workbuddy-roots.js).
///
/// Billable records (ebe797e): completed assistant messages
/// ({type:"message", role:"assistant", status:"completed"|"complete"|"success"})
/// and usage-bearing function calls ({type:"function_call", providerData:{…}}).
/// Usage reads providerData.usage, then message.usage; providerData.rawUsage
/// supplies the OpenAI-shaped fallbacks. WorkBuddy's aggregate input/output
/// fields include cache reads/reasoning, so the exclusive counts are
/// rawUsage.prompt_cache_miss_tokens when positive, else input − cached, and
/// output − reasoning. Entries dedupe by record id across files/roots keeping
/// the highest-token copy; `conversationRequestId` is a turn id and never a
/// dedup key. Sessions are reported only when they contain a user prompt.
///
/// Documented simplifications vs the JS original:
/// - The JS `warnings` array has no VibeParseResult equivalent: warnings log
///   through OSLog and set the result's `skipped` flag while the parsed data
///   is still returned, exactly like the JS `{buckets, sessions, skipped: true}`.
/// - JS `Number(value)` accepts booleans and a few more oddities; here
///   booleans are treated as missing (consistent with the other ports).
struct VibeWorkBuddyParser: VibeLogParser {
    let source = "workbuddy"
    private let projectDirs: [String]

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")
    private static let maxWarnings = 20

    init(
        projectDirs: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory())
    {
        if let projectDirs {
            self.projectDirs = projectDirs
            return
        }
        self.projectDirs = Self.resolveProjectDirs(environment: environment, home: home)
    }

    /// JS findWorkbuddyDataDirs + the parser's projects/ normalization:
    /// VIBE_USAGE_WORKBUDDY_DIRS (path-list separator ":", entries trimmed)
    /// replaces discovery; else ~/.workbuddy-ai/projects and ~/.workbuddy/projects.
    /// Entries naming the home get "/projects" appended; duplicates collapse.
    static func resolveProjectDirs(environment: [String: String], home: String = NSHomeDirectory()) -> [String] {
        let raw: [String]
        if let override = environment["VIBE_USAGE_WORKBUDDY_DIRS"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            raw = override.split(separator: ":")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            raw = [home + "/.workbuddy-ai/projects", home + "/.workbuddy/projects"]
        }
        var seen = Set<String>()
        var dirs: [String] = []
        for root in raw {
            let normalized = URL(fileURLWithPath: root).lastPathComponent == "projects" ? root : root + "/projects"
            if seen.insert(normalized).inserted { dirs.append(normalized) }
        }
        return dirs
    }

    // MARK: - Transcript discovery

    /// Per-parse warning collector: any warning flags the source skipped (the
    /// snapshot may be incomplete) while parsed data is still returned (JS).
    private final class WarnContext {
        private(set) var skipped = false
        private var seen = Set<String>()
        func warn(_ message: String) {
            skipped = true
            if seen.count < VibeWorkBuddyParser.maxWarnings, seen.insert(message).inserted {
                VibeWorkBuddyParser.logger.warning("\(message, privacy: .public)")
            }
        }
    }

    /// Recursive *.jsonl collection under a projects dir. A missing dir is
    /// simply empty (ENOENT); an unreadable existing branch warns and is
    /// skipped (JS findJsonlFiles).
    private static func findJsonlFiles(_ directory: String, ctx: WarnContext) -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            if !FileManager.default.fileExists(atPath: directory) { return [] }
            ctx.warn("workbuddy: cannot read a data directory")
            return []
        }
        var files: [String] = []
        for name in children.sorted() {
            let path = directory + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                files.append(contentsOf: findJsonlFiles(path, ctx: ctx))
            } else if name.hasSuffix(".jsonl") {
                files.append(path)
            }
        }
        return files
    }

    // MARK: - Per-file scan (mtime/size cached)

    private struct Usage: Equatable, Sendable {
        var inputTokens: Double
        var outputTokens: Double
        var cachedInputTokens: Double
        var reasoningOutputTokens: Double
        var score: Double
    }

    private struct EntryCandidate: Equatable, Sendable {
        let id: String
        let score: Double
        var entry: VibeTokenEntry
    }

    private struct EventCandidate: Equatable, Sendable {
        let id: String?
        let sessionId: String
        let timestamp: Date
        let role: VibeSessionRole
    }

    /// Everything one transcript contributes: usage candidates and timing
    /// events (project applied at merge time — the last record cwd wins for
    /// the whole file, JS behavior) plus that final project.
    private struct ParsedFile: Equatable, Sendable {
        var project: String
        var entries: [EntryCandidate] = []
        var events: [EventCandidate] = []
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

    /// Returns the parsed file and whether the read ran to completion. A
    /// partial read (I/O error mid-stream) keeps the records consumed so far,
    /// matching the JS for-await loop that has already yielded them.
    private static func scan(_ path: String, byteLimit: Int, projectsDir: String) -> (ParsedFile, Bool) {
        var parsed = ParsedFile(project: projectFromFile(path, projectsDir: projectsDir))
        let fallbackSessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let complete = forEachJSONLine(at: path, byteLimit: byteLimit) { record in
            if let cwdProject = projectFromRecord(record) { parsed.project = cwdProject }
            let timestamp = timestampFor(record)
            let id = recordId(record)
            let role = roleFor(record)
            let sessionId = sessionIdFor(record, fallback: fallbackSessionId)
            let completedAssistant = isCompletedAssistant(record)
            let usage = isUsageRecord(record) ? usageFor(record) : nil

            let eventRole: VibeSessionRole?
            if role == .user {
                eventRole = .user
            } else if completedAssistant || (record["type"] as? String == "function_call" && usage != nil) {
                eventRole = .assistant
            } else {
                eventRole = nil
            }
            if let timestamp, let eventRole {
                parsed.events.append(EventCandidate(id: id, sessionId: sessionId, timestamp: timestamp, role: eventRole))
            }
            guard let id, let timestamp, let usage else { return }
            parsed.entries.append(EntryCandidate(
                id: id, score: usage.score,
                entry: VibeTokenEntry(
                    source: "workbuddy", model: modelFor(record), project: "", timestamp: timestamp,
                    inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                    cachedInputTokens: usage.cachedInputTokens,
                    reasoningOutputTokens: usage.reasoningOutputTokens)))
        }
        return (parsed, complete)
    }

    // MARK: - Record mapping

    private static func recordId(_ record: [String: Any]) -> String? {
        switch record["id"] {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let trimmed = number.stringValue.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    private enum RecordRole: Equatable {
        case user
        case assistant
    }

    /// JS roleFor: record.role ?? record.message?.role; 'assistant_message'
    /// counts as assistant.
    private static func roleFor(_ record: [String: Any]) -> RecordRole? {
        let role = (record["role"] as? String) ?? ((record["message"] as? [String: Any])?["role"] as? String)
        switch role {
        case "user": return .user
        case "assistant", "assistant_message": return .assistant
        default: return nil
        }
    }

    private static func isCompletedAssistant(_ record: [String: Any]) -> Bool {
        guard record["type"] as? String == "message", roleFor(record) == .assistant else { return false }
        let message = record["message"] as? [String: Any]
        let status = ((record["status"] ?? message?["status"] ?? record["state"] ?? message?["state"]) as? String ?? "")
            .lowercased()
        return status == "completed" || status == "complete" || status == "success"
    }

    private static func isUsageRecord(_ record: [String: Any]) -> Bool {
        isCompletedAssistant(record)
            || (record["type"] as? String == "function_call" && record["providerData"] is [String: Any])
    }

    private static func modelFor(_ record: [String: Any]) -> String {
        let providerData = record["providerData"] as? [String: Any] ?? [:]
        for value in [providerData["requestModelId"], record["requestModelName"],
                      providerData["requestModelName"], providerData["model"]] {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "unknown"
    }

    /// First non-null value among keys (JS `??` chains skip only null/undefined).
    private static func firstNonNull(_ dictionary: [String: Any]?, _ keys: [String]) -> Any? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key], !(value is NSNull) { return value }
        }
        return nil
    }

    /// JS firstDetailValue: details may be one object or an array of them.
    private static func firstDetailValue(_ details: Any?, keys: [String]) -> Double {
        let list: [Any]
        if let array = details as? [Any] {
            list = array
        } else if let details {
            list = [details]
        } else {
            list = []
        }
        for case let detail as [String: Any] in list {
            for key in keys {
                if let value = detail[key], !(value is NSNull) { return finite(value) }
            }
        }
        return 0
    }

    /// JS usageFor. WorkBuddy's aggregate input/output fields include cache
    /// reads/reasoning: prefer the provider's exclusive cache-miss field when
    /// available, else subtract the included parts. All-zero rows emit nothing.
    private static func usageFor(_ record: [String: Any]) -> Usage? {
        let providerData = record["providerData"] as? [String: Any] ?? [:]
        let message = record["message"] as? [String: Any]
        let primary = (providerData["usage"] as? [String: Any]) ?? (message?["usage"] as? [String: Any])
        let raw = providerData["rawUsage"] as? [String: Any]
        guard primary != nil || raw != nil else { return nil }

        let inputDetails = firstNonNull(primary, ["input_details", "inputDetails", "inputTokensDetails"])
            ?? firstNonNull(raw, ["prompt_tokens_details"])
        let outputDetails = firstNonNull(primary, ["output_details", "outputDetails", "outputTokensDetails"])
            ?? firstNonNull(raw, ["completion_tokens_details"])
        // JS `a || b`: a zero detail value falls through to the flat fields.
        let detailCached = firstDetailValue(inputDetails, keys: ["cached_tokens", "cachedTokens"])
        let fallbackCached = finite(
            firstNonNull(primary, ["cachedInputTokens", "cache_read_input_tokens", "cacheReadInputTokens"])
                ?? firstNonNull(raw, ["prompt_cache_hit_tokens", "cache_read_input_tokens"]))
        let cachedInputTokens = detailCached > 0 ? detailCached : fallbackCached
        let detailReasoning = firstDetailValue(outputDetails, keys: ["reasoning_tokens", "reasoningTokens"])
        let fallbackReasoning = finite(
            firstNonNull(primary, ["reasoningOutputTokens", "completion_thinking_tokens", "reasoning_tokens", "reasoningTokens"])
                ?? firstNonNull(raw, ["completion_thinking_tokens"]))
        let reasoningOutputTokens = detailReasoning > 0 ? detailReasoning : fallbackReasoning
        let inclusiveInput = finite(
            firstNonNull(primary, ["inputTokens", "input_tokens"]) ?? firstNonNull(raw, ["prompt_tokens"]))
        let inclusiveOutput = finite(
            firstNonNull(primary, ["outputTokens", "output_tokens"]) ?? firstNonNull(raw, ["completion_tokens"]))
        let cacheMiss = finite(firstNonNull(raw, ["prompt_cache_miss_tokens"]))

        let inputTokens = cacheMiss > 0 ? cacheMiss : max(0, inclusiveInput - cachedInputTokens)
        let outputTokens = max(0, inclusiveOutput - reasoningOutputTokens)
        let score = inputTokens + outputTokens + cachedInputTokens + reasoningOutputTokens
        guard score > 0 else { return nil }
        return Usage(
            inputTokens: inputTokens, outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens, reasoningOutputTokens: reasoningOutputTokens,
            score: score)
    }

    /// JS timestampFor: the first non-null of the chain is coerced; a value
    /// that fails to parse does NOT fall through to the next key.
    private static func timestampFor(_ record: [String: Any]) -> Date? {
        let message = record["message"] as? [String: Any]
        for raw in [record["completedAt"], record["completed_at"], record["timestamp"],
                    record["createdAt"], record["created_at"], message?["createdAt"]] {
            if let raw, !(raw is NSNull) { return dateFrom(raw) }
        }
        return nil
    }

    private static func sessionIdFor(_ record: [String: Any], fallback: String) -> String {
        switch record["sessionId"] ?? record["session_id"] {
        case let string as String:
            // JS: String(id).trim() === '' falls back, but a surviving id is
            // kept untrimmed.
            return string.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : string
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.stringValue
        default:
            return fallback
        }
    }

    /// Project fallback from the transcript's folder: first path component
    /// relative to the projects dir (JS projectFromFile).
    private static func projectFromFile(_ path: String, projectsDir: String) -> String {
        guard path.hasPrefix(projectsDir + "/") else { return "unknown" }
        return path.dropFirst(projectsDir.count + 1)
            .split(separator: "/", omittingEmptySubsequences: true)
            .first.map(String.init) ?? "unknown"
    }

    /// Last path component of the record's cwd, Unix or Windows separators,
    /// drive letters dropped (JS projectFromRecord).
    private static func projectFromRecord(_ record: [String: Any]) -> String? {
        guard let cwd = (record["cwd"] as? String)?.trimmingCharacters(in: .whitespaces),
              !cwd.isEmpty else { return nil }
        var trimmed = cwd
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { $0.range(of: #"^[a-zA-Z]:$"#, options: .regularExpression) == nil }
            .last
    }

    // MARK: - Value coercion

    /// JS dateFrom: numbers below 1e12 are epoch seconds, above epoch
    /// milliseconds; strings are ISO dates.
    private static func dateFrom(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw < 1e12 ? raw : raw / 1000)
        case let string as String where !string.trimmingCharacters(in: .whitespaces).isEmpty:
            return parseISODate(string)
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

    /// JS finite: Number(value), kept when finite and >= 0, else 0.
    private static func finite(_ value: Any?) -> Double {
        guard let raw = jsNumber(value), raw >= 0 else { return 0 }
        return raw
    }

    // MARK: - Streaming JSONL

    /// Read one 64KB chunk at a time, at most `byteLimit` bytes; retain only
    /// an unfinished row between reads. Corrupt/non-object lines are skipped,
    /// never fatal — WorkBuddy may be appending the final record while we
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
        let ctx = WarnContext()
        // JS Map semantics: dedupe by record id keeping the highest-token
        // copy; overwrite keeps the original insertion position.
        var entriesById: [String: EntryCandidate] = [:]
        var idOrder: [String] = []
        var eventsByKey: [String: VibeSessionEvent] = [:]
        var eventOrder: [String] = []

        for projectsDir in projectDirs {
            for file in Self.findJsonlFiles(projectsDir, ctx: ctx) {
                guard let stamp = Self.stamp(file) else {
                    ctx.warn("workbuddy: cannot stat a session file")
                    continue
                }
                let parsed: ParsedFile
                if let cached = Self.cache.withLock({ $0[file] }), cached.stamp == stamp {
                    parsed = cached.parsed
                } else {
                    let (scanned, complete) = Self.scan(file, byteLimit: stamp.size, projectsDir: projectsDir)
                    if !complete { ctx.warn("workbuddy: cannot read a session file") }
                    parsed = scanned
                    // Commit only a fully-read, unchanged file; a file WorkBuddy
                    // is appending to right now is rescanned next sync.
                    if complete, Self.stamp(file) == stamp {
                        Self.cache.withLock { entries in
                            if entries.count >= 4096, entries[file] == nil, let oldest = entries.keys.first {
                                entries.removeValue(forKey: oldest)
                            }
                            entries[file] = CacheEntry(stamp: stamp, parsed: scanned)
                        }
                    }
                }

                for var candidate in parsed.entries {
                    candidate.entry.project = parsed.project
                    if let current = entriesById[candidate.id] {
                        if candidate.score > current.score { entriesById[candidate.id] = candidate }
                    } else {
                        entriesById[candidate.id] = candidate
                        idOrder.append(candidate.id)
                    }
                }
                for candidate in parsed.events {
                    let key = candidate.id.map { "id:\(candidate.sessionId):\($0):\(candidate.role.rawValue)" }
                        ?? "fallback:\(candidate.sessionId):\(candidate.role.rawValue):\(VibeSyncTime.isoString(candidate.timestamp))"
                    if eventsByKey[key] == nil { eventOrder.append(key) }
                    eventsByKey[key] = VibeSessionEvent(
                        sessionId: candidate.sessionId, source: source, project: parsed.project,
                        timestamp: candidate.timestamp, role: candidate.role)
                }
            }
        }

        // Only sessions with at least one user prompt are reported (JS
        // sessionEventsWithPrompts).
        let allEvents = eventOrder.compactMap { eventsByKey[$0] }
        let sessionsWithUsers = Set(allEvents.filter { $0.role == .user }.map(\.sessionId))
        var result = VibeParseResult(skipped: ctx.skipped)
        result.entries = idOrder.compactMap { entriesById[$0]?.entry }
        result.events = allEvents.filter { sessionsWithUsers.contains($0.sessionId) }
        return result
    }
}
