import Foundation
import Synchronization

/// Claude Code log parser — Swift port of vibe-usage `src/parsers/claude-code.js`
/// plus the root discovery in `src/claude-roots.js`.
///
/// Layout:
///   <root>/projects/<dashed-cwd>/<session-id>.jsonl  — token usage + timing
///   <root>/transcripts/<session-id>.jsonl            — session timing only
///
/// Roots (first match wins, JS getClaudeRoots): VIBE_USAGE_CLAUDE_DIRS
/// (path-list separator ":", tests / diagnostics) replaces all discovery; else
/// ~/.claude, $CLAUDE_CONFIG_DIR, and data-bearing ~/.claude-* profile dirs.
///
/// Token mapping: inputTokens = input_tokens + max(cache_creation_input_tokens,
/// ephemeral_5m + ephemeral_1h breakdown), cachedInputTokens =
/// cache_read_input_tokens, outputTokens = output_tokens, reasoning = 0. Model
/// is message.model; "<synthetic>"/missing falls back to the session's last
/// real model, then "claude-unknown". All-zero usage rows emit nothing.
///
/// Dedupe: one API call is written as several assistant lines (one per content
/// block, plus an early streaming partial) sharing message.id/requestId; the
/// "call:<id>\0<requestId>" key collapses them and the highest usageScore
/// wins. Lines without either id fall back to uuid; keyless lines are always
/// kept. The merge is global, so a call copied into another session counts
/// once. The same session file copied between roots is resolved by scanning
/// only the most complete copy (largest size, then newest mtime, then path).
///
/// Documented simplifications vs the JS original:
/// - Claude Desktop Cowork roots (~/Library/Application Support/Claude/
///   local-agent-mode-sessions/**/.claude recursive discovery) are not
///   ported; Desktop Code itself uses ~/.claude, which is covered.
/// - realpathSync canonicalization is approximated with
///   resolvingSymlinksInPath (enough to dedupe symlinked roots).
/// - Timestamps parse as ISO8601 (with/without fractional seconds); JS
///   `new Date(value)` accepts a few more formats Claude never writes.
/// - JS tracks an "ordered events" fast path and re-sorts only unusual files;
///   here events are emitted in file order and VibeAggregation.extractSessions
///   sorts them, so the distinction is unnecessary.
/// - JS warnings collapse into `skipped: true` (the Swift protocol has no
///   warnings channel), matching the official `{skipped: true}` result.
struct VibeClaudeCodeParser: VibeLogParser {
    let source = "claude-code"
    private let roots: [String]

    init(roots: [String]? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let roots {
            self.roots = roots
            return
        }
        self.roots = Self.discoverRoots(environment: environment)
    }

    // MARK: - Root discovery (claude-roots.js)

    static func discoverRoots(environment: [String: String]) -> [String] {
        let home = NSHomeDirectory()
        var roots: [String] = []
        let override = environment["VIBE_USAGE_CLAUDE_DIRS"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            roots = override.split(separator: ":").map { expandHome(String($0)) }.filter { !$0.isEmpty }
        } else {
            roots.append(home + "/.claude")
            if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
               !configured.isEmpty {
                roots.append(expandHome(configured))
            }
            // Multi-profile convention: data-bearing ~/.claude-<name> dirs.
            // fileExists follows symlinks, matching JS hasClaudeData().
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
                for entry in entries where entry.hasPrefix(".claude-") && entry.count > ".claude-".count {
                    let candidate = home + "/" + entry
                    if FileManager.default.fileExists(atPath: candidate + "/projects")
                        || FileManager.default.fileExists(atPath: candidate + "/transcripts") {
                        roots.append(candidate)
                    }
                }
            }
        }
        var seen = Set<String>()
        var unique: [String] = []
        for root in roots {
            let canonical = (root as NSString).resolvingSymlinksInPath
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            unique.append(root)
        }
        return unique
    }

    /// JS expandHome: "~" / "~/" prefixes, trailing slashes stripped.
    private static func expandHome(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") || trimmed.hasPrefix("~\\") {
            return NSHomeDirectory() + "/" + trimmed.dropFirst(2)
        }
        return trimmed
    }

    // MARK: - Candidate collection

    private struct Candidate {
        let path: String
        let sessionId: String
        let size: Int
        let mtime: TimeInterval
        let fallbackProject: String
    }

    private struct FileStamp: Equatable, Sendable {
        let size: Int
        let mtime: TimeInterval
    }

    private static func stamp(_ path: String) -> FileStamp? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let size = values.fileSize, let mtime = values.contentModificationDate
        else { return nil }
        return FileStamp(size: size, mtime: mtime.timeIntervalSince1970)
    }

    /// Recursive *.jsonl collection; an unreadable existing branch marks the
    /// result incomplete rather than taking the parser down (JS findJsonlFiles).
    private func findJsonlFiles(_ directory: String, incomplete: inout Bool) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            if FileManager.default.fileExists(atPath: directory) { incomplete = true }
            return []
        }
        var results: [String] = []
        for entry in entries {
            let fullPath = directory + "/" + entry
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue {
                results.append(contentsOf: findJsonlFiles(fullPath, incomplete: &incomplete))
            } else if entry.hasSuffix(".jsonl") {
                results.append(fullPath)
            }
        }
        return results
    }

    /// Group files by logical session id across roots and order each group by
    /// completeness: larger size, then newer mtime, then lexicographic path
    /// (JS collectCandidates / candidateIsBetter).
    private func collectCandidates(directoryName: String, incomplete: inout Bool) -> [(String, [Candidate])] {
        var groups: [String: [Candidate]] = [:]
        var order: [String] = []
        for root in roots {
            let baseDir = root + "/" + directoryName
            for path in findJsonlFiles(baseDir, incomplete: &incomplete) {
                guard let stamp = Self.stamp(path) else {
                    incomplete = true
                    continue
                }
                let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let relative = path.hasPrefix(baseDir + "/") ? String(path.dropFirst(baseDir.count + 1)) : nil
                let candidate = Candidate(
                    path: path,
                    sessionId: sessionId,
                    size: stamp.size,
                    mtime: stamp.mtime,
                    fallbackProject: directoryName == "projects" ? Self.projectFromRelative(relative) : "unknown")
                if groups[sessionId] == nil { order.append(sessionId) }
                groups[sessionId, default: []].append(candidate)
            }
        }
        return order.map { sessionId in
            let sorted = groups[sessionId]!.sorted { first, second in
                if first.size != second.size { return first.size > second.size }
                if first.mtime != second.mtime { return first.mtime > second.mtime }
                return first.path < second.path
            }
            return (sessionId, sorted)
        }
    }

    /// Fallback for old records without cwd: last dash-component of the first
    /// relative path segment ("-Users-x-myproj" → "myproj"; JS projectFromRelative).
    private static func projectFromRelative(_ relative: String?) -> String {
        guard let relative,
              let firstSegment = relative.split(separator: "/", omittingEmptySubsequences: true).first
        else { return "unknown" }
        let parts = firstSegment.split(separator: "-", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? "unknown"
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

    // MARK: - Per-file scan (mtime/size cached)

    private struct UsageRecord: Sendable {
        let dedupeKey: String?
        let usageScore: Double
        var entry: VibeTokenEntry
    }

    private struct ParsedFile: Sendable {
        var keyed: [String: UsageRecord] = [:]
        var anonymous: [UsageRecord] = []
        var events: [VibeSessionEvent] = []
    }

    private enum ScanKind {
        case projects
        case transcripts
    }

    private struct CacheEntry: Sendable {
        let stamp: FileStamp
        let parsed: ParsedFile
    }

    // Sync runs every 30 minutes; unchanged session files (the vast majority)
    // are re-statted but never re-read, so a full pass costs one directory
    // walk plus reads of files appended since the last run.
    private static let cache = Mutex<[String: CacheEntry]>([:])

    /// Returns nil when the file cannot be read (caller tries the next
    /// candidate copy of the session, JS scanBestCandidate).
    private func cachedScan(_ candidate: Candidate, kind: ScanKind) -> ParsedFile? {
        guard let before = Self.stamp(candidate.path) else { return nil }
        if let cached = Self.cache.withLock({ $0[candidate.path] }), cached.stamp == before {
            return cached.parsed
        }
        guard let parsed = scan(candidate, kind: kind) else { return nil }
        // Commit only if the file did not change mid-read; a changing file is
        // rescanned next sync rather than caching a partial aggregate.
        if Self.stamp(candidate.path) == before {
            Self.cache.withLock { entries in
                if entries.count >= 4096, entries[candidate.path] == nil, let oldest = entries.keys.first {
                    entries.removeValue(forKey: oldest)
                }
                entries[candidate.path] = CacheEntry(stamp: before, parsed: parsed)
            }
        }
        return parsed
    }

    private func scan(_ candidate: Candidate, kind: ScanKind) -> ParsedFile? {
        switch kind {
        case .projects: return scanProjectCandidate(candidate)
        case .transcripts: return scanTranscriptCandidate(candidate)
        }
    }

    private func scanBestCandidate(
        _ candidates: [Candidate], kind: ScanKind, incomplete: inout Bool
    ) -> ParsedFile? {
        for candidate in candidates {
            if let parsed = cachedScan(candidate, kind: kind) { return parsed }
            incomplete = true
        }
        return nil
    }

    /// Read only the file size captured during discovery, so a line Claude is
    /// appending right now is left for the next sync (JS readJsonl).
    private func scanProjectCandidate(_ candidate: Candidate) -> ParsedFile? {
        var parsed = ParsedFile()
        var lastModel: String?
        var sessionProject = candidate.fallbackProject
        var foundSessionCwd = false
        let scanned = Self.forEachJSONLine(at: candidate.path, byteLimit: candidate.size) { object in
            // cwd can change after `cd`; the session keeps the project it
            // started in (first cwd wins).
            if !foundSessionCwd, let cwd = object["cwd"] as? String,
               !cwd.trimmingCharacters(in: .whitespaces).isEmpty {
                sessionProject = Self.projectFromCwd(cwd, fallback: candidate.fallbackProject)
                foundSessionCwd = true
            }
            if let event = Self.timingEvent(object, sessionId: candidate.sessionId, project: sessionProject) {
                parsed.events.append(event)
            }
            guard (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = Self.parseTimestamp(object["timestamp"])
            else { return }

            let rawModel = (message["model"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let modelIsReal = !rawModel.isEmpty && rawModel != "<synthetic>"
            if modelIsReal { lastModel = rawModel }
            let model = modelIsReal ? rawModel : (lastModel ?? "claude-unknown")

            let inputTokens = Self.toCount(usage["input_tokens"]) + Self.cacheCreationTokens(usage)
            let outputTokens = Self.toCount(usage["output_tokens"])
            let cachedInputTokens = Self.toCount(usage["cache_read_input_tokens"])
            let usageScore = inputTokens + outputTokens + cachedInputTokens
            // Synthetic bookkeeping rows carry zero usage and would only
            // inflate bucket counts the server discards anyway.
            guard usageScore > 0 else { return }

            Self.mergeUsageRecord(into: &parsed, UsageRecord(
                dedupeKey: Self.usageDedupeKey(object),
                usageScore: usageScore,
                entry: VibeTokenEntry(
                    source: "claude-code",
                    model: model,
                    project: sessionProject,
                    timestamp: timestamp,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cachedInputTokens: cachedInputTokens,
                    reasoningOutputTokens: 0)))
        }
        guard scanned else { return nil }
        // A cwd can appear after initial metadata/messages: normalize the
        // completed session so early records get the same project label.
        for index in parsed.anonymous.indices { parsed.anonymous[index].entry.project = sessionProject }
        for key in parsed.keyed.keys { parsed.keyed[key]?.entry.project = sessionProject }
        return parsed
    }

    private func scanTranscriptCandidate(_ candidate: Candidate) -> ParsedFile? {
        var parsed = ParsedFile()
        let scanned = Self.forEachJSONLine(at: candidate.path, byteLimit: candidate.size) { object in
            if let event = Self.timingEvent(
                object, sessionId: candidate.sessionId,
                project: Self.projectFromCwd(object["cwd"], fallback: "unknown")) {
                parsed.events.append(event)
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
        // Claude sometimes copies the same record into another session with
        // zeroed usage; keep the most complete payload (JS mergeUsageEntry).
        if let current = context.keyed[key], current.usageScore >= record.usageScore { return }
        context.keyed[key] = record
    }

    /// "call:<message.id>\0<requestId>" collapses per-content-block repeats and
    /// streaming partials of one API call; older logs without ids fall back to
    /// the line uuid; keyless lines are always kept (JS usageDedupeKey).
    private static func usageDedupeKey(_ object: [String: Any]) -> String? {
        let message = object["message"] as? [String: Any]
        let messageId = (message?["id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let requestId = (object["requestId"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !messageId.isEmpty || !requestId.isEmpty {
            return "call:\(messageId)\0\(requestId)"
        }
        if let uuid = object["uuid"] as? String, !uuid.isEmpty { return uuid }
        return nil
    }

    /// max(total, TTL breakdown): current logs carry both, max avoids
    /// double-counting while tolerating partially populated logs.
    private static func cacheCreationTokens(_ usage: [String: Any]) -> Double {
        let direct = toCount(usage["cache_creation_input_tokens"])
        let breakdown = usage["cache_creation"] as? [String: Any] ?? [:]
        let split = toCount(breakdown["ephemeral_5m_input_tokens"])
            + toCount(breakdown["ephemeral_1h_input_tokens"])
        return max(direct, split)
    }

    /// JS timingEvent: user lines are user turns; assistant/tool_use/
    /// tool_result lines all count as assistant activity.
    private static func timingEvent(
        _ object: [String: Any], sessionId: String, project: String
    ) -> VibeSessionEvent? {
        guard let type = object["type"] as? String,
              type == "user" || type == "assistant" || type == "tool_use" || type == "tool_result",
              let timestamp = parseTimestamp(object["timestamp"])
        else { return nil }
        return VibeSessionEvent(
            sessionId: sessionId, source: "claude-code", project: project,
            timestamp: timestamp, role: type == "user" ? .user : .assistant)
    }

    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return (try? fractionalSeconds.parse(string)) ?? (try? wholeSeconds.parse(string))
    }

    /// JS toCount: Number(value), kept when finite and positive, else 0.
    private static func toCount(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
            let raw = number.doubleValue
            return raw.isFinite && raw > 0 ? raw : 0
        case let string as String:
            let raw = Double(string.trimmingCharacters(in: .whitespaces)) ?? 0
            return raw.isFinite && raw > 0 ? raw : 0
        default:
            return 0
        }
    }

    // MARK: - Streaming JSONL

    /// Read one 64KB chunk at a time, at most `byteLimit` bytes; retain only
    /// an unfinished row between reads. Corrupt/non-object lines are skipped,
    /// never fatal — Claude may be appending the final record while we
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
        var incomplete = false
        var merged = ParsedFile()

        let projectGroups = collectCandidates(directoryName: "projects", incomplete: &incomplete)
        var projectSessionIds = Set<String>()
        for (sessionId, candidates) in projectGroups {
            guard let parsed = scanBestCandidate(candidates, kind: .projects, incomplete: &incomplete)
            else { continue }
            projectSessionIds.insert(sessionId)
            for record in parsed.anonymous { Self.mergeUsageRecord(into: &merged, record) }
            for record in parsed.keyed.values { Self.mergeUsageRecord(into: &merged, record) }
            result.events.append(contentsOf: parsed.events)
        }

        // Transcripts add session timing only for sessions projects/ lacks.
        let transcriptGroups = collectCandidates(directoryName: "transcripts", incomplete: &incomplete)
        for (sessionId, candidates) in transcriptGroups where !projectSessionIds.contains(sessionId) {
            guard let parsed = scanBestCandidate(candidates, kind: .transcripts, incomplete: &incomplete)
            else { continue }
            result.events.append(contentsOf: parsed.events)
        }

        // Deterministic order: keyed entries sort by dedupe key so a cached
        // re-parse yields a byte-identical snapshot (Dictionary iteration
        // order differs between fresh scans and cache hits).
        result.entries = merged.anonymous.map(\.entry)
            + merged.keyed.keys.sorted().compactMap { merged.keyed[$0]?.entry }
        result.skipped = incomplete
        return result
    }
}
