import Foundation
import Synchronization

/// Grok (Grok Build TUI / CLI) log parser — Swift port of vibe-usage
/// `src/parsers/grok.js`.
///
/// Layout (see ~/.grok/docs/user-guide/17-sessions.md):
///   $GROK_HOME/sessions/<url-encoded-cwd>/<session-id>/
///     summary.json  — cwd, model, timestamps
///     updates.jsonl — ACP session updates; turn_completed carries exact usage
///     events.jsonl  — turn_started / turn_ended timing fallback
///
/// Root discovery: VIBE_USAGE_GROK_SESSIONS override (tests / relocated
/// trees), else $GROK_HOME/sessions, else ~/.grok/sessions.
///
/// Token mapping (pushUsageEntry in the JS source): inputTokens in the log is
/// the *total* prompt count, so the reported input is total − cache reads, and
/// output is output − reasoning, matching Codex/Copilot so totalTokens does
/// not double-count cache/reasoning. All-zero turns emit nothing. Per-model
/// `modelUsage` (when present and non-empty) wins over the turn-level totals.
///
/// Documented simplifications vs the JS original:
/// - No extraRoots / strict-mode support: the JS parser warns-and-skips when a
///   user-configured extra root is unreadable; the Swift protocol has no
///   warnings channel and the app configures no extra roots, so a missing
///   default root simply yields an empty result (same as JS).
/// - Timestamp strings are parsed as ISO8601 only; JS `new Date(value)`
///   accepts a few more formats, none of which Grok writes.
struct VibeGrokParser: VibeLogParser {
    let source = "grok"
    private let sessionRoots: [String]

    init(sessionRoots: [String]? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let sessionRoots {
            self.sessionRoots = sessionRoots.filter { Self.isDirectory($0) }
            return
        }
        if let override = environment["VIBE_USAGE_GROK_SESSIONS"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            self.sessionRoots = [override].filter { Self.isDirectory($0) }
            return
        }
        let grokHome: String
        if let envHome = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespaces), !envHome.isEmpty {
            grokHome = NSString(string: envHome).expandingTildeInPath
        } else {
            grokHome = NSHomeDirectory() + "/.grok"
        }
        self.sessionRoots = [grokHome + "/sessions"].filter { Self.isDirectory($0) }
    }

    func parse() throws -> VibeParseResult {
        guard !sessionRoots.isEmpty else { return VibeParseResult() }

        var candidates: [SessionCandidate] = []
        for root in sessionRoots {
            candidates.append(contentsOf: listSessionDirs(root))
        }
        // The same session id can exist under several roots (moved/copied
        // grok homes); keep the most complete copy, scored lexicographically
        // by the sizes of updates.jsonl, events.jsonl, summary.json.
        let sessions = sessionRoots.count > 1 ? mostCompleteCopies(candidates) : candidates

        var result = VibeParseResult()
        for session in sessions {
            let parsed = cachedSession(session)
            result.entries.append(contentsOf: parsed.entries)
            result.events.append(contentsOf: parsed.events)
        }
        return result
    }

    // MARK: - Session discovery

    private struct SessionCandidate {
        let sessionId: String
        let path: String
        let projectFallback: String
        let score: [Int]
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func listSessionDirs(_ sessionsDir: String) -> [SessionCandidate] {
        let fileManager = FileManager.default
        guard let groups = try? fileManager.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        var results: [SessionCandidate] = []
        for group in groups {
            let groupPath = sessionsDir + "/" + group
            guard Self.isDirectory(groupPath),
                  let children = try? fileManager.contentsOfDirectory(atPath: groupPath)
            else { continue }
            let projectFallback = Self.projectFromGroupDir(group, groupPath: groupPath)
            for child in children {
                let sessionPath = groupPath + "/" + child
                guard Self.isDirectory(sessionPath) else { continue }
                // A real session always has summary.json (or at least updates).
                let hasSummary = fileManager.fileExists(atPath: sessionPath + "/summary.json")
                let hasUpdates = fileManager.fileExists(atPath: sessionPath + "/updates.jsonl")
                guard hasSummary || hasUpdates else { continue }
                results.append(SessionCandidate(
                    sessionId: child,
                    path: sessionPath,
                    projectFallback: projectFallback,
                    score: [
                        Self.fileSize(sessionPath + "/updates.jsonl"),
                        Self.fileSize(sessionPath + "/events.jsonl"),
                        Self.fileSize(sessionPath + "/summary.json"),
                    ]))
            }
        }
        return results
    }

    private static func fileSize(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    /// JS: candidate replaces the previous copy only when, at the first index
    /// where the size scores differ, the candidate's file is larger.
    private func mostCompleteCopies(_ candidates: [SessionCandidate]) -> [SessionCandidate] {
        var selected: [String: SessionCandidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            guard let previous = selected[candidate.sessionId] else {
                selected[candidate.sessionId] = candidate
                order.append(candidate.sessionId)
                continue
            }
            let moreComplete = zip(candidate.score, previous.score)
                .first { $0.0 != $0.1 }
                .map { $0.0 > $0.1 } ?? false
            if moreComplete { selected[candidate.sessionId] = candidate }
        }
        return order.compactMap { selected[$0] }
    }

    /// Decode a sessions group dirname; fall back to a `.cwd` sidecar file,
    /// then to the raw dirname (JS projectFromGroupDir).
    private static func projectFromGroupDir(_ groupName: String, groupPath: String) -> String {
        let cwdFile = groupPath + "/.cwd"
        if let raw = try? String(contentsOfFile: cwdFile, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return projectFromPath(trimmed) }
        }
        if let decoded = groupName.removingPercentEncoding,
           decoded.contains("/") || decoded.contains("\\") {
            return projectFromPath(decoded)
        }
        return groupName.isEmpty ? "unknown" : groupName
    }

    /// Last path component (project name), or "unknown" (JS projectFromPath).
    private static func projectFromPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "unknown" : name
    }

    // MARK: - Per-session scan (mtime/size cached)

    private struct ParsedSession: Sendable {
        var entries: [VibeTokenEntry] = []
        var events: [VibeSessionEvent] = []
    }

    private struct FileStamp: Equatable, Sendable {
        let size: Int
        let mtime: TimeInterval
    }

    private struct SessionFingerprint: Equatable, Sendable {
        let updates: FileStamp?
        let events: FileStamp?
        let summary: FileStamp?
    }

    private struct CacheEntry: Sendable {
        let fingerprint: SessionFingerprint
        let parsed: ParsedSession
    }

    // Sync runs every 30 minutes; unchanged session files (the vast majority)
    // are re-statted but never re-read, so a full pass costs one directory
    // walk plus reads of files appended since the last run.
    private static let cache = Mutex<[String: CacheEntry]>([:])

    private static func stamp(_ path: String) -> FileStamp? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let size = values.fileSize, let mtime = values.contentModificationDate
        else { return nil }
        return FileStamp(size: size, mtime: mtime.timeIntervalSince1970)
    }

    private static func fingerprint(_ sessionPath: String) -> SessionFingerprint {
        SessionFingerprint(
            updates: stamp(sessionPath + "/updates.jsonl"),
            events: stamp(sessionPath + "/events.jsonl"),
            summary: stamp(sessionPath + "/summary.json"))
    }

    private func cachedSession(_ session: SessionCandidate) -> ParsedSession {
        let before = Self.fingerprint(session.path)
        if let cached = Self.cache.withLock({ $0[session.path] }), cached.fingerprint == before {
            return cached.parsed
        }
        let parsed = scanSession(session)
        // Commit only if the files did not change mid-read; a changing file is
        // rescanned next sync rather than caching a partial aggregate.
        if Self.fingerprint(session.path) == before {
            Self.cache.withLock { entries in
                if entries.count >= 4096, entries[session.path] == nil, let oldest = entries.keys.first {
                    entries.removeValue(forKey: oldest)
                }
                entries[session.path] = CacheEntry(fingerprint: before, parsed: parsed)
            }
        }
        return parsed
    }

    private func scanSession(_ session: SessionCandidate) -> ParsedSession {
        var parsed = ParsedSession()
        let summary = Self.readJSON(session.path + "/summary.json") ?? [:]
        let info = summary["info"] as? [String: Any]
        let cwd = (info?["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (summary["git_root_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let project = cwd.map(Self.projectFromPath) ?? session.projectFallback
        let fallbackModel = (summary["current_model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"

        // Prefer updates.jsonl turn_completed for exact usage + message timings.
        var sawUserOrAssistant = false
        Self.forEachJSONLine(at: session.path + "/updates.jsonl") { object in
            guard let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any]
            else { return }
            let kind = update["sessionUpdate"] as? String
            let timestamp = Self.toDate(object["timestamp"])

            if kind == "turn_completed", let timestamp {
                Self.emitTurnUsage(into: &parsed.entries, usage: update["usage"] as? [String: Any],
                                   project: project, timestamp: timestamp, fallbackModel: fallbackModel)
            }
            guard let timestamp else { return }

            switch kind {
            case "user_message_chunk":
                sawUserOrAssistant = true
                parsed.events.append(VibeSessionEvent(
                    sessionId: session.sessionId, source: source, project: project,
                    timestamp: timestamp, role: .user))
            case "agent_message_chunk", "turn_completed":
                sawUserOrAssistant = true
                parsed.events.append(VibeSessionEvent(
                    sessionId: session.sessionId, source: source, project: project,
                    timestamp: timestamp, role: .assistant))
            default:
                break
            }
        }

        // Fallback timing from events.jsonl when updates lack message chunks
        // (short/aborted sessions, older builds).
        if !sawUserOrAssistant {
            Self.forEachJSONLine(at: session.path + "/events.jsonl") { object in
                guard let timestamp = Self.toDate(object["ts"] ?? object["timestamp"]) else { return }
                switch object["type"] as? String {
                case "turn_started":
                    parsed.events.append(VibeSessionEvent(
                        sessionId: session.sessionId, source: source, project: project,
                        timestamp: timestamp, role: .user))
                case "turn_ended", "first_token":
                    parsed.events.append(VibeSessionEvent(
                        sessionId: session.sessionId, source: source, project: project,
                        timestamp: timestamp, role: .assistant))
                default:
                    break
                }
            }
        }

        // Last-resort session envelope from summary timestamps so a session
        // with no parseable turns still appears once usage lands later.
        if parsed.events.isEmpty {
            let created = Self.toDate(summary["created_at"] ?? info?["created_at"])
            let updated = Self.toDate(summary["updated_at"] ?? summary["last_active_at"])
            if let created {
                parsed.events.append(VibeSessionEvent(
                    sessionId: session.sessionId, source: source, project: project,
                    timestamp: created, role: .user))
            }
            if let updated, created == nil || updated != created {
                parsed.events.append(VibeSessionEvent(
                    sessionId: session.sessionId, source: source, project: project,
                    timestamp: updated, role: .assistant))
            }
        }
        return parsed
    }

    // MARK: - Usage mapping

    private static func emitTurnUsage(
        into entries: inout [VibeTokenEntry],
        usage: [String: Any]?,
        project: String,
        timestamp: Date,
        fallbackModel: String)
    {
        guard let usage else { return }
        if let modelUsage = usage["modelUsage"] as? [String: Any], !modelUsage.isEmpty {
            for (model, perModel) in modelUsage {
                pushUsageEntry(into: &entries, model: model, project: project, timestamp: timestamp,
                               usage: perModel as? [String: Any] ?? usage)
            }
            return
        }
        pushUsageEntry(into: &entries, model: fallbackModel, project: project, timestamp: timestamp, usage: usage)
    }

    private static func pushUsageEntry(
        into entries: inout [VibeTokenEntry],
        model: String,
        project: String,
        timestamp: Date,
        usage: [String: Any])
    {
        let totalInput = max(0, number(usage["inputTokens"]))
        let cached = max(0, number(usage["cachedReadTokens"]))
        let output = max(0, number(usage["outputTokens"]))
        let reasoning = max(0, number(usage["reasoningTokens"]))

        // Prefer exclusive fields when both are present (Codex-style).
        let inputTokens = max(0, totalInput - cached)
        let outputTokens = max(0, output - reasoning)

        guard inputTokens + outputTokens + cached + reasoning > 0 else { return }

        entries.append(VibeTokenEntry(
            source: "grok",
            model: model.isEmpty ? "unknown" : model,
            project: project,
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cached,
            reasoningOutputTokens: reasoning))
    }

    // MARK: - Value coercion

    /// JS toDate: finite numbers are Unix seconds below 1e12, milliseconds
    /// at/above it; strings parse as dates; anything else is no timestamp.
    private static func toDate(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            let milliseconds = raw < 1e12 ? raw * 1000 : raw
            return Date(timeIntervalSince1970: milliseconds / 1000)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return VibeSyncTime.parse(trimmed)
        default:
            return nil
        }
    }

    /// JS Number(value) || 0: numeric strings count, booleans/junk are 0.
    private static func number(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return 0 }
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces)) ?? 0
        default:
            return 0
        }
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - Streaming JSONL

    /// Read one 64KB chunk at a time; retain only an unfinished row between
    /// reads. Corrupt/non-object lines are skipped, never fatal (JS keeps
    /// what it has on truncated mid-write files). Message contents are parsed
    /// and immediately discarded — only counts and timestamps are kept.
    private static func forEachJSONLine(at path: String, consume: ([String: Any]) -> Void) {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
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
            guard let chunk = try? file.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
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
        if start < pending.endIndex { parse(Data(pending[start...])) }
    }
}
