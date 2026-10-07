import Foundation
import OSLog
import Synchronization

/// OpenClaw log parser — Swift port of vibe-usage `src/parsers/openclaw.js`
/// (main @ c55b82c1; includes the profile-deployment roots of a820d3e0 and
/// the CraftAgent gap-closing of a4967515; no post-2026-08 fixes).
///
/// Layout: <root>/agents/<agentId>/sessions/*.jsonl (read flat). Roots
/// (JS getPossibleRoots): the VIBE_USAGE_OPENCLAW_DIRS override (path-list
/// separator ":", tests / relocated trees) replaces discovery; else the
/// legacy homes ~/.clawdbot, ~/.moltbot, ~/.moldbot plus every home directory
/// named `.openclaw` or `.openclaw-<profile>`. The session's project is the
/// <agentId> directory name.
///
/// Records: only lines with type 'message' count. Every such line with a
/// valid `obj.timestamp || msg.timestamp` is a session event; the role is
/// 'user' only when message.role === 'user', anything else is assistant
/// activity (JS ternary). Assistant messages with a `usage` object produce an
/// entry — OpenClaw accepts several naming conventions per field, and the
/// first key coercing to a finite positive number wins (JS getTokens):
///   input:      input, inputTokens, input_tokens, promptTokens, prompt_tokens
///   cacheWrite: cacheCreation, cacheCreationInputTokens, cacheWrite,
///               cache_creation, cache_write, cache_creation_input_tokens,
///               cache_write_input_tokens   → folded into inputTokens
///   output:     output, outputTokens, output_tokens, completionTokens,
///               completion_tokens
///   cached:     cacheRead, cache_read, cache_read_input_tokens
/// Entries are pushed even when every count is zero (JS has no zero guard).
/// Cache writes have no TTL breakdown; cacheCreation5m/1h stay 0.
///
/// Documented simplifications vs the JS original:
/// - The JS parser has no `skipped` path: unreadable directories/files are
///   silently skipped. Here that logs through OSLog; the source still reports
///   skipped == false.
/// - Timestamps parse as ISO8601 strings (with/without fractional seconds) or
///   epoch-millisecond numbers; JS `new Date(value)` accepts a few more
///   formats OpenClaw never writes.
/// - JS `Number(value)` also accepts booleans (Number(true) === 1); here
///   booleans are treated as missing (repo-wide convention).
struct VibeOpenClawParser: VibeLogParser {
    let source = "openclaw"
    private let roots: [String]

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    init(
        roots: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory())
    {
        self.roots = roots ?? Self.resolveRoots(environment: environment, home: home)
    }

    /// JS getPossibleRoots: the override (split on ":", empties dropped)
    /// replaces discovery; else legacy homes + discovered .openclaw[-*] dirs.
    static func resolveRoots(environment: [String: String], home: String = NSHomeDirectory()) -> [String] {
        if let override = environment["VIBE_USAGE_OPENCLAW_DIRS"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return override.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        var roots = [home + "/.clawdbot", home + "/.moltbot", home + "/.moldbot"]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for entry in entries {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: home + "/" + entry, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                // JS: name === '.openclaw' || /^\.openclaw-.+/.test(name)
                if entry == ".openclaw"
                    || (entry.hasPrefix(".openclaw-") && entry.count > ".openclaw-".count) {
                    roots.append(home + "/" + entry)
                }
            }
        }
        return roots
    }

    // MARK: - Session file discovery (JS parse's readdir chain)

    /// Every <root>/agents/<agentId>/sessions/*.jsonl with its project (the
    /// agent directory name). Missing/unreadable levels are skipped, matching
    /// the JS existsSync/try-catch chain.
    private func findSessionFiles() -> [(path: String, project: String)] {
        var results: [(path: String, project: String)] = []
        for root in roots {
            let agentsDir = root + "/agents"
            guard FileManager.default.fileExists(atPath: agentsDir),
                  let agents = try? FileManager.default.contentsOfDirectory(atPath: agentsDir)
            else { continue }
            for agent in agents {
                let agentDir = agentsDir + "/" + agent
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: agentDir, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let sessionsDir = agentDir + "/sessions"
                guard FileManager.default.fileExists(atPath: sessionsDir),
                      let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)
                else { continue }
                for file in files where file.hasSuffix(".jsonl") {
                    let path = sessionsDir + "/" + file
                    var fileIsDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &fileIsDirectory),
                       !fileIsDirectory.boolValue {
                        results.append((path, agent))
                    }
                }
            }
        }
        // Sorted for a deterministic snapshot; JS uses readdir order, which
        // only affects entry ordering, never the aggregates.
        return results.sorted { $0.path < $1.path }
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
    private func cachedScan(_ path: String, project: String) -> ParsedFile? {
        guard let before = Self.stamp(path) else { return nil }
        if let cached = Self.cache.withLock({ $0[path] }), cached.stamp == before {
            return cached.parsed
        }
        guard let parsed = scan(path, byteLimit: before.size, project: project) else { return nil }
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

    /// Read only the file size captured during discovery, so a line OpenClaw
    /// is appending right now is left for the next sync.
    private func scan(_ path: String, byteLimit: Int, project: String) -> ParsedFile? {
        var parsed = ParsedFile()
        let scanned = Self.forEachJSONLine(at: path, byteLimit: byteLimit) { object in
            guard (object["type"] as? String) == "message",
                  let message = object["message"] as? [String: Any]
            else { return }

            // JS: obj.timestamp || msg.timestamp, then new Date(...) must parse.
            guard let rawTimestamp = Self.jsTruthy(object["timestamp"]) ?? Self.jsTruthy(message["timestamp"]),
                  let timestamp = Self.jsDate(rawTimestamp)
            else { return }

            // JS: role is 'user' only for message.role === 'user'; anything
            // else counts as assistant activity.
            let isUser = (message["role"] as? String) == "user"
            parsed.events.append(VibeSessionEvent(
                sessionId: path, source: source, project: project,
                timestamp: timestamp, role: isUser ? .user : .assistant))

            // JS: msg.role === 'user' ? 'user' : 'assistant' for the event,
            // but entries require the exact 'assistant' role.
            guard (message["role"] as? String) == "assistant",
                  let rawUsage = Self.jsTruthy(message["usage"]) else { return }
            let usage = rawUsage as? [String: Any] ?? [:]

            let inputTokens = Self.getTokens(
                usage, "input", "inputTokens", "input_tokens", "promptTokens", "prompt_tokens")
            let cacheWriteTokens = Self.getTokens(
                usage, "cacheCreation", "cacheCreationInputTokens", "cacheWrite",
                "cache_creation", "cache_write", "cache_creation_input_tokens",
                "cache_write_input_tokens")
            parsed.entries.append(VibeTokenEntry(
                source: "openclaw",
                model: Self.jsTruthy(message["model"]) as? String
                    ?? Self.jsTruthy(object["model"]) as? String ?? "unknown",
                project: project,
                timestamp: timestamp,
                inputTokens: inputTokens + cacheWriteTokens,
                outputTokens: Self.getTokens(
                    usage, "output", "outputTokens", "output_tokens",
                    "completionTokens", "completion_tokens"),
                cachedInputTokens: Self.getTokens(
                    usage, "cacheRead", "cache_read", "cache_read_input_tokens"),
                reasoningOutputTokens: 0))
        }
        return scanned ? parsed : nil
    }

    // MARK: - Value coercion

    /// JS getTokens: the first key whose Number(value) is finite and > 0 wins.
    private static func getTokens(_ usage: [String: Any], _ keys: String...) -> Double {
        for key in keys {
            if let number = jsNumber(usage[key]), number > 0 { return number }
        }
        return 0
    }

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
    /// never fatal — OpenClaw may be appending the final record while we
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
        for (path, project) in findSessionFiles() {
            guard let parsed = cachedScan(path, project: project) else {
                // JS: readFileSync failure is a bare `continue`; the source
                // has no skipped path.
                Self.logger.warning("openclaw: cannot read session file \(path, privacy: .public)")
                continue
            }
            result.entries.append(contentsOf: parsed.entries)
            result.events.append(contentsOf: parsed.events)
        }
        return result
    }
}
