import Foundation
import OSLog
import Synchronization

/// Shared Pi-compatible session JSONL scan engine — Swift port of vibe-usage
/// `src/parsers/pi-session-jsonl.js`, shared by the pi-coding-agent, omp,
/// craft-agent, and cola parsers (which upstream are thin wrappers supplying
/// roots, a file filter, a project rule, and the copied-session dedup flag).
///
/// Layout: a sessions directory holds `.jsonl` session files (possibly nested).
/// Each file opens with a `{"type":"session", id, timestamp, cwd}` header and
/// then `{"type":"message", id, parentId, timestamp, message}` records; the
/// assistant message's `message.usage` carries token counts.
///
/// Token mapping: cache writes count as input (input = usage.input +
/// usage.cacheWrite); reasoning is read from `usage.reasoning` (legacy
/// `usage.reasoningTokens` accepted) and split out of the inclusive
/// `usage.output`; cachedInputTokens = usage.cacheRead. All-zero usage rows
/// emit no entry. Model is the first non-empty of message.model,
/// message.modelId, obj.model, obj.modelId, else "unknown".
///
/// Dedupe: records carrying `obj.id` dedupe globally on "<sessionId>:<id>"
/// (highest usage score wins); id-less records are always kept. Configured
/// stores can overlap (ancestor/descendant, symlinked copies), so files are
/// deduped on canonical path before reading. Session events come from
/// user/assistant/toolResult messages; toolResult counts as assistant
/// activity.
///
/// Copied-session dedup (cola.js's deduplicateCopiedSessions): a copied
/// transcript gets a new session header but unchanged records, whose short
/// message ids are only unique within a session. The record key becomes
/// [id, timestamp, parentId, role, model], and every keyed record's identity
/// (sessionId/project) is attributed to the earliest copy — the owner chosen
/// by session start time, then session id, then canonical file path. A second
/// `session` header in one file is ignored in this mode.
///
/// Documented simplifications vs the JS original:
/// - realpathSync canonicalization is approximated with
///   resolvingSymlinksInPath (enough to dedupe symlinked roots).
/// - Timestamps parse as ISO8601 (with/without fractional seconds) or epoch
///   milliseconds; JS `new Date(value)` accepts a few more formats Pi never
///   writes.
/// - JS warnings collapse into `skipped: true` plus an OSLog entry (the Swift
///   protocol has no warnings channel).
struct VibePiSessionJSONLParser: VibeLogParser {
    let source: String
    private let sessionsDirs: [String]
    private let includeFile: @Sendable (String) -> Bool
    private let projectFromPath: @Sendable (String, String) -> String
    private let deduplicateCopiedSessions: Bool
    /// cola.js: a missing part of the store must not overwrite a complete
    /// uploaded bucket with a partial sum, so a skipped run reports nothing.
    private let clearsResultsWhenSkipped: Bool

    init(
        source: String,
        sessionsDirs: [String],
        includeFile: @escaping @Sendable (String) -> Bool = { _ in true },
        projectFromPath: @escaping @Sendable (String, String) -> String = VibePiSessionJSONLParser.projectFromFirstDir(path:sessionsDir:),
        deduplicateCopiedSessions: Bool = false,
        clearsResultsWhenSkipped: Bool = false
    ) {
        self.source = source
        self.sessionsDirs = sessionsDirs
        self.includeFile = includeFile
        self.projectFromPath = projectFromPath
        self.deduplicateCopiedSessions = deduplicateCopiedSessions
        self.clearsResultsWhenSkipped = clearsResultsWhenSkipped
    }

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        var result = VibeParseResult()
        var incomplete = false
        var merged = ParsedFile()
        var seenFiles = Set<String>()

        for sessionsDir in sessionsDirs {
            for path in findJsonlFiles(sessionsDir, incomplete: &incomplete) {
                // Configured stores can overlap: an ancestor and its
                // descendant, or two paths that resolve to the same place
                // through a symlink. Record-level dedup only covers entries
                // carrying an id, so collapse on the canonical file path
                // (JS canonicalFilePath / seenFiles).
                let canonical = (path as NSString).resolvingSymlinksInPath
                guard seenFiles.insert(canonical).inserted else { continue }
                guard let parsed = cachedScan(path: path, sessionsDir: sessionsDir, canonical: canonical) else {
                    incomplete = true
                    Self.logger.warning("\(self.source, privacy: .public): cannot read \(path, privacy: .public)")
                    continue
                }
                merged.anonymousEntries.append(contentsOf: parsed.anonymousEntries)
                merged.anonymousEvents.append(contentsOf: parsed.anonymousEvents)
                for (key, record) in parsed.keyedEntries {
                    if let current = merged.keyedEntries[key], current.score >= record.score { continue }
                    merged.keyedEntries[key] = record
                }
                for (key, event) in parsed.keyedEvents {
                    merged.keyedEvents[key] = event
                }
                for (key, owner) in parsed.keyedOwners {
                    if let current = merged.keyedOwners[key], !owner.isPreferred(over: current) { continue }
                    merged.keyedOwners[key] = owner
                }
            }
        }

        // Deterministic order: keyed records sort by dedupe key so a cached
        // re-parse yields a byte-identical snapshot (Dictionary iteration
        // order differs between fresh scans and cache hits).
        result.entries = merged.anonymousEntries
            + merged.keyedEntries.keys.sorted().compactMap { key in
                guard var entry = merged.keyedEntries[key]?.entry else { return nil }
                // Copied-session dedup attributes the record to the earliest
                // copy's project (JS recordOwners), regardless of which copy
                // supplied the winning payload.
                if let owner = merged.keyedOwners[key] { entry.project = owner.project }
                return entry
            }
        result.events = merged.anonymousEvents
            + merged.keyedEvents.keys.sorted().compactMap { key in
                guard var event = merged.keyedEvents[key] else { return nil }
                if let owner = merged.keyedOwners[key] {
                    event.sessionId = owner.sessionId
                    event.project = owner.project
                }
                return event
            }
        result.skipped = incomplete
        if incomplete && clearsResultsWhenSkipped {
            result.entries = []
            result.events = []
        }
        return result
    }

    // MARK: - File discovery

    /// Recursive *.jsonl collection, sorted for deterministic merge order; an
    /// unreadable existing branch marks the result incomplete rather than
    /// taking the parser down (JS findJsonlFiles).
    private func findJsonlFiles(_ directory: String, incomplete: inout Bool) -> [String] {
        guard FileManager.default.fileExists(atPath: directory) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            incomplete = true
            Self.logger.warning("\(self.source, privacy: .public): cannot read directory \(directory, privacy: .public)")
            return []
        }
        var results: [String] = []
        for entry in entries.sorted() {
            let fullPath = directory + "/" + entry
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue {
                results.append(contentsOf: findJsonlFiles(fullPath, incomplete: &incomplete))
            } else if entry.hasSuffix(".jsonl"), includeFile(fullPath) {
                results.append(fullPath)
            }
        }
        return results
    }

    /// Project fallback from the first path segment below the sessions dir:
    /// its last dash-component ("2026-07-27-myproj" → "myproj"; JS
    /// projectFromFirstDir). A session header's cwd overrides this.
    static func projectFromFirstDir(path: String, sessionsDir: String) -> String {
        var relative = path
        if path.hasPrefix(sessionsDir + "/") {
            relative = String(path.dropFirst(sessionsDir.count + 1))
        }
        guard let first = relative.split(separator: "/", omittingEmptySubsequences: false).first,
              !first.isEmpty
        else { return "unknown" }
        return first.split(separator: "-", omittingEmptySubsequences: true).last.map(String.init) ?? "unknown"
    }

    /// Last path component of a cwd value, Unix or Windows separators
    /// (JS projectFromCwd, fallback "unknown").
    private static func projectFromCwd(_ value: Any?) -> String {
        guard let cwd = value as? String else { return "unknown" }
        var trimmed = cwd.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return "unknown" }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "unknown"
    }

    // MARK: - Per-file scan (mtime/size cached)

    private struct ScoredEntry: Sendable {
        let score: Double
        let entry: VibeTokenEntry
    }

    /// Copied-session ownership candidate (JS recordOwners): every keyed
    /// record is attributed to the earliest copy carrying it.
    private struct OwnerCandidate: Sendable {
        let sessionId: String
        let project: String
        let startedAt: Double
        let filePath: String

        func isPreferred(over other: OwnerCandidate) -> Bool {
            if startedAt != other.startedAt { return startedAt < other.startedAt }
            if sessionId != other.sessionId { return sessionId < other.sessionId }
            return filePath < other.filePath
        }
    }

    private struct ParsedFile: Sendable {
        var keyedEntries: [String: ScoredEntry] = [:]
        var anonymousEntries: [VibeTokenEntry] = []
        var keyedEvents: [String: VibeSessionEvent] = [:]
        var anonymousEvents: [VibeSessionEvent] = []
        var keyedOwners: [String: OwnerCandidate] = [:]
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

    /// Returns nil when the file cannot be read (JS warns and continues).
    private func cachedScan(path: String, sessionsDir: String, canonical: String) -> ParsedFile? {
        // The project fallback derives from the sessions dir, so the same file
        // reached through a different root is a different cache entry; the
        // source and dedup mode key the scan configuration with it.
        let cacheKey = canonical + "\0" + sessionsDir + "\0" + source
            + (deduplicateCopiedSessions ? "\0copied" : "")
        guard let before = Self.stamp(path) else { return nil }
        if let cached = Self.cache.withLock({ $0[cacheKey] }), cached.stamp == before {
            return cached.parsed
        }
        guard let parsed = scan(path: path, sessionsDir: sessionsDir, canonical: canonical) else { return nil }
        // Commit only if the file did not change mid-read; a changing file is
        // rescanned next sync rather than caching a partial aggregate.
        if Self.stamp(path) == before {
            Self.cache.withLock { entries in
                if entries.count >= 4096, entries[cacheKey] == nil, let oldest = entries.keys.first {
                    entries.removeValue(forKey: oldest)
                }
                entries[cacheKey] = CacheEntry(stamp: before, parsed: parsed)
            }
        }
        return parsed
    }

    private func scan(path: String, sessionsDir: String, canonical: String) -> ParsedFile? {
        var parsed = ParsedFile()
        var sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let derivedProject = projectFromPath(path, sessionsDir)
        var project = derivedProject.isEmpty ? "unknown" : derivedProject
        // JS sessionStartedAt: the header's timestamp in epoch milliseconds,
        // Infinity until a parseable header arrives.
        var sessionStartedAt = Double.infinity
        var seenHeader = false

        let scanned = Self.forEachJSONLine(at: path) { object in
            if (object["type"] as? String) == "session" {
                // A copied transcript starts with one fresh header; later
                // headers in the same file belong to the copied history.
                if self.deduplicateCopiedSessions && seenHeader { return }
                seenHeader = true
                if let id = Self.truthyId(object["id"]) { sessionId = id }
                if let cwd = object["cwd"], Self.isTruthy(cwd) {
                    project = Self.projectFromCwd(cwd)
                }
                sessionStartedAt = Self.headerStartedAt(object["timestamp"])
                return
            }
            guard (object["type"] as? String) == "message",
                  let message = object["message"] as? [String: Any]
            else { return }

            // JS: new Date(obj.timestamp || message.timestamp || 0) — a record
            // with no timestamp lands on the epoch and is kept; a present but
            // unparseable one drops the record.
            let rawTimestamp = Self.firstTruthy(object["timestamp"], message["timestamp"])
            let timestamp: Date
            if let rawTimestamp {
                guard let date = Self.jsDate(rawTimestamp) else { return }
                timestamp = date
            } else {
                timestamp = Date(timeIntervalSince1970: 0)
            }
            let model = [message["model"], message["modelId"], object["model"], object["modelId"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? "unknown"

            let recordId: String?
            if let id = Self.truthyId(object["id"]) {
                if self.deduplicateCopiedSessions, rawTimestamp != nil {
                    // Cola copies a transcript with a new session header but
                    // unchanged records. Its short message ids are only unique
                    // within a session, so cross-session dedup also requires
                    // time, parent, role, and model. All other Pi-family
                    // callers retain sessionId:id identities.
                    recordId = Self.copiedRecordKey(
                        id: object["id"] as Any, timestamp: timestamp,
                        parentId: object["parentId"], role: message["role"], model: model)
                } else {
                    recordId = "\(sessionId):\(id)"
                }
            } else {
                recordId = nil
            }

            if self.deduplicateCopiedSessions, let recordId {
                parsed.keyedOwners[recordId] = OwnerCandidate(
                    sessionId: sessionId, project: project,
                    startedAt: sessionStartedAt, filePath: canonical)
            }

            let role = message["role"] as? String
            if role == "user" || role == "assistant" || role == "toolResult" {
                let event = VibeSessionEvent(
                    sessionId: sessionId, source: source, project: project,
                    timestamp: timestamp, role: role == "user" ? .user : .assistant)
                if let recordId {
                    parsed.keyedEvents[recordId] = event
                } else {
                    parsed.anonymousEvents.append(event)
                }
            }

            guard role == "assistant", let usage = message["usage"] as? [String: Any] else { return }
            // Pi's Usage type names this field `reasoning` (a documented subset
            // of `output`); older/adjacent stores wrote `reasoningTokens`.
            let reasoning = Self.toCount(usage["reasoning"] ?? usage["reasoningTokens"])
            // OMP/Pi usage.output includes reasoning; the shared bucket
            // contract stores non-reasoning output and reasoning separately.
            let outputTokens = max(0, Self.toCount(usage["output"]) - reasoning)
            let inputTokens = Self.toCount(usage["input"]) + Self.toCount(usage["cacheWrite"])
            let cachedInputTokens = Self.toCount(usage["cacheRead"])
            let score = inputTokens + outputTokens + cachedInputTokens + reasoning
            guard score > 0 else { return }

            let entry = VibeTokenEntry(
                source: source, model: model, project: project, timestamp: timestamp,
                inputTokens: inputTokens, outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens, reasoningOutputTokens: reasoning)
            if let recordId {
                // Keep the most complete payload when a record id repeats
                // (JS: replace only on a strictly higher score).
                if let current = parsed.keyedEntries[recordId], current.score >= score { return }
                parsed.keyedEntries[recordId] = ScoredEntry(score: score, entry: entry)
            } else {
                parsed.anonymousEntries.append(entry)
            }
        }
        return scanned ? parsed : nil
    }

    // MARK: - Value coercion

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

    /// JS truthiness for JSON values: null/false/0/"" are falsy, anything else
    /// (including objects and arrays) is truthy.
    private static func isTruthy(_ value: Any) -> Bool {
        switch value {
        case is NSNull: return false
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            let raw = number.doubleValue
            return raw != 0 && !raw.isNaN
        case let string as String: return !string.isEmpty
        default: return true
        }
    }

    private static func firstTruthy(_ first: Any?, _ second: Any?) -> Any? {
        if let first, isTruthy(first) { return first }
        if let second, isTruthy(second) { return second }
        return nil
    }

    /// A truthy `id` rendered the way JS `${obj.id}` / String(obj.id) would:
    /// strings verbatim, numbers by their plain description.
    private static func truthyId(_ value: Any?) -> String? {
        guard let value, isTruthy(value) else { return nil }
        switch value {
        case let string as String: return string
        case let number as NSNumber: return "\(number)"
        default: return nil
        }
    }

    /// JS new Date(value): numbers are epoch milliseconds, strings parse as
    /// dates; anything else is no timestamp.
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    private static func jsDate(_ value: Any) -> Date? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            return Date(timeIntervalSince1970: raw / 1000)
        case let string as String:
            return (try? fractionalSeconds.parse(string)) ?? (try? wholeSeconds.parse(string))
        default:
            return nil
        }
    }

    /// JS `new Date(obj.timestamp).getTime()` for a session header: epoch
    /// milliseconds, Infinity when absent or unparseable (new Date(null) is 0).
    private static func headerStartedAt(_ value: Any?) -> Double {
        guard let value else { return .infinity }
        if value is NSNull { return 0 }
        guard let date = jsDate(value) else { return .infinity }
        return date.timeIntervalSince1970 * 1000
    }

    /// JS JSON.stringify([obj.id, timestamp.getTime(), obj.parentId ?? null,
    /// message.role, model]) — the copied-session dedup key. Only determinism
    /// matters; the key never leaves the process.
    private static func copiedRecordKey(id: Any, timestamp: Date, parentId: Any?, role: Any?, model: String) -> String {
        let milliseconds = (timestamp.timeIntervalSince1970 * 1000).rounded()
        let key: [Any] = [id, milliseconds, parentId ?? NSNull(), role ?? NSNull(), model]
        guard JSONSerialization.isValidJSONObject(key),
              let data = try? JSONSerialization.data(withJSONObject: key),
              let string = String(data: data, encoding: .utf8)
        else { return "\(milliseconds)" }
        return string
    }

    // MARK: - Streaming JSONL

    /// Read one 64KB chunk at a time; retain only an unfinished row between
    /// reads. Corrupt/non-object lines are skipped, never fatal — Pi may be
    /// appending the final record while we snapshot it. Message contents are
    /// parsed and immediately discarded; only counts and timestamps are kept.
    /// Returns false on I/O failure.
    private static func forEachJSONLine(at path: String, consume: ([String: Any]) -> Void) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
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
            let chunk: Data
            do { chunk = try file.read(upToCount: 64 * 1024) ?? Data() } catch { return false }
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
        if start < pending.endIndex { parse(Data(pending[start...])) }
        return true
    }
}

// MARK: - Root discovery helpers (pi-roots.js / craft-roots.js / cola-roots.js)

enum VibePiRoots {
    /// JS expandHome: "~" and "~/" / "~\" anchors only.
    static func expandHome(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") || trimmed.hasPrefix("~\\") {
            return NSHomeDirectory() + "/" + trimmed.dropFirst(2)
        }
        return trimmed
    }

    /// JS uniqueExistingDirs: expand, dedupe in order, keep existing paths.
    static func uniqueExistingDirs(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let expanded = expandHome(path)
            guard !expanded.isEmpty, !seen.contains(expanded),
                  FileManager.default.fileExists(atPath: expanded)
            else { continue }
            seen.insert(expanded)
            result.append(expanded)
        }
        return result
    }

    /// JS looksLikeOmpAgentDir: path contains "/.omp/", or the directory
    /// carries OMP's config.yml / agent.db markers.
    static func looksLikeOmpAgentDir(_ agentDir: String) -> Bool {
        if agentDir.replacingOccurrences(of: "\\", with: "/").contains("/.omp/") { return true }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: agentDir + "/config.yml")
            || fileManager.fileExists(atPath: agentDir + "/agent.db")
    }

    /// JS profileSessionDirs: one sessions dir per profile child. With
    /// `includesAgentDir` the profile keeps the agent/ segment
    /// (profiles/<name>/agent/sessions); OMP's XDG layout drops it
    /// (profiles/<name>/sessions). Missing profiles root yields nothing.
    static func profileSessionDirs(_ profilesRoot: String, includesAgentDir: Bool) -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)
        else { return [] }
        var dirs: [String] = []
        for name in children {
            let base = profilesRoot + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            dirs.append(base + (includesAgentDir ? "/agent/sessions" : "/sessions"))
        }
        return dirs
    }
}
