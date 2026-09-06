import CryptoKit
import Foundation
import Synchronization

/// kimi-code (MoonshotAI Kimi Code CLI) log parser.
///
/// Port of vibe-usage `src/parsers/kimi-code.js`. Two on-disk stores are always
/// parsed and merged (`kimi migrate` drops `_usage` records, so a migrated
/// user's history exists only in the legacy store and parsing both cannot
/// double-count):
///
/// 1. Current (`~/.kimi-code`): sessions live at
///    `sessions/wd_<slug>_<hash>/session_<id>/agents/<agent>/wire.jsonl`. Each
///    line is self-describing with an integer-ms `time`. `usage.record` events
///    are per-step deltas (any `usageScope`: `turn` is a normal step, `session`
///    covers retry/compaction calls — both count). The model rides on each
///    record. User turns are `turn.prompt` with `origin.kind == "user"`. All
///    agent wires under one sessionDir form one logical session, so session
///    events key on the session directory path. The real project name comes
///    from `session_index.jsonl` (`{sessionDir, workDir}` → basename(workDir)),
///    falling back to the `wd_<slug>` bucket name.
///
/// 2. Legacy (`~/.kimi`): sessions live at
///    `sessions/<md5(workdir)>/<session-id>/wire.jsonl` with a different
///    envelope (`StatusUpdate.payload.token_usage`, float-second `timestamp`)
///    and the model in `config.toml`. Project names come from `kimi.json`
///    (`work_dirs` entries are md5-hashed; `workspaces`/`projects` are keyed by
///    hash directly). StatusUpdates dedupe globally by `payload.message_id`.
///
/// Root resolution mirrors the JS test hooks: `VIBE_USAGE_KIMI_CODE_DIR`, then
/// `KIMI_CODE_HOME`, then `~/.kimi-code`; `VIBE_USAGE_KIMI_DIR` then `~/.kimi`.
///
/// Documented simplifications vs. the JS implementation:
/// - JSON booleans are not coerced to 0/1 (JS `Number(true) == 1`); a boolean
///   in a numeric field is treated as absent.
/// - Legacy negative token values are clamped to 0 like every other field
///   instead of being passed through raw (JS legacy used `value || 0`).
/// - A legacy `message`/`payload` that is not a JSON object is treated as
///   absent (JS would accept any truthy value and then find no fields on it).
/// - Legacy `payload.model` only overrides the model when it is a string.
struct VibeKimiCodeParser: VibeLogParser {
    let source = "kimi-code"

    private let kimiCodeRoot: URL
    private let legacyKimiRoot: URL

    init(
        kimiCodeRoot: URL? = nil,
        legacyKimiRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.kimiCodeRoot = kimiCodeRoot ?? Self.resolveKimiCodeRoot(environment: environment)
        self.legacyKimiRoot = legacyKimiRoot ?? Self.resolveLegacyKimiRoot(environment: environment)
    }

    static func resolveKimiCodeRoot(environment: [String: String]) -> URL {
        if let override = environment["VIBE_USAGE_KIMI_CODE_DIR"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        if let home = environment["KIMI_CODE_HOME"]?.trimmingCharacters(in: .whitespaces), !home.isEmpty {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    static func resolveLegacyKimiRoot(environment: [String: String]) -> URL {
        if let override = environment["VIBE_USAGE_KIMI_DIR"]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi")
    }

    // MARK: - Parse

    func parse() throws -> VibeParseResult {
        var result = VibeParseResult()
        var liveKeys = Set<String>()
        parseCurrent(into: &result, liveKeys: &liveKeys)
        parseLegacy(into: &result, liveKeys: &liveKeys)
        // Drop cache entries for wire files that no longer exist.
        Self.fileCache.withLock { cache in
            let stale = cache.keys.filter { !liveKeys.contains($0) }
            for key in stale { cache[key] = nil }
        }
        return result
    }

    private func parseCurrent(into result: inout VibeParseResult, liveKeys: inout Set<String>) {
        let sessionsDir = kimiCodeRoot.appendingPathComponent("sessions")
        let sessionIndex = Self.loadSessionIndex(at: kimiCodeRoot.appendingPathComponent("session_index.jsonl"))
        for wire in Self.findCurrentWireFiles(sessionsDir: sessionsDir) {
            liveKeys.insert(wire.file.path)
            let project = sessionIndex[wire.sessionDirPath] ?? wire.bucketProject
            let output = Self.cachedParse(at: wire.file) {
                Self.parseCurrentWire(at: wire.file, sessionDir: wire.sessionDirPath, project: project)
            }
            result.entries.append(contentsOf: output.entries)
            result.events.append(contentsOf: output.events)
        }
    }

    private func parseLegacy(into result: inout VibeParseResult, liveKeys: inout Set<String>) {
        let sessionsDir = legacyKimiRoot.appendingPathComponent("sessions")
        let projectMap = Self.loadLegacyProjectMap(kimiJSON: legacyKimiRoot.appendingPathComponent("kimi.json"))
        let defaultModel = Self.loadLegacyModel(configTOML: legacyKimiRoot.appendingPathComponent("config.toml"))
        var seenMessageIds = Set<String>()
        for wire in Self.findLegacyWireFiles(sessionsDir: sessionsDir) {
            liveKeys.insert(wire.file.path)
            let project = projectMap[wire.workDirHash] ?? wire.workDirHash
            let output = Self.cachedParse(at: wire.file) {
                Self.parseLegacyWire(
                    at: wire.file, project: project, defaultModel: defaultModel,
                    seenMessageIds: &seenMessageIds)
            }
            result.entries.append(contentsOf: output.entries)
            result.events.append(contentsOf: output.events)
        }
    }

    // MARK: - Current format (~/.kimi-code)

    private static func parseCurrentWire(at url: URL, sessionDir: String, project: String) -> FileOutput {
        var output = FileOutput()
        let usageMarker = Data("\"usage.record\"".utf8)
        let promptMarker = Data("\"turn.prompt\"".utf8)
        forEachLine(at: url) { line in
            // Only these two event types carry anything this parser reads.
            guard line.range(of: usageMarker) != nil || line.range(of: promptMarker) != nil else { return }
            autoreleasepool {
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = event["type"] as? String else { return }
                // Top-level `time` is integer milliseconds. An out-of-range
                // value would later crash ISO8601 formatting — skip instead of
                // stamping "now" (a stateless parser would re-key the record
                // into a fresh bucket on every sync, duplicating it).
                let timestamp = strictNumber(event["time"]).flatMap(date(fromMilliseconds:))

                if type == "turn.prompt" {
                    if (event["origin"] as? [String: Any])?["kind"] as? String == "user", let timestamp {
                        output.events.append(VibeSessionEvent(
                            sessionId: sessionDir, source: "kimi-code", project: project,
                            timestamp: timestamp, role: .user))
                    }
                    return
                }

                guard type == "usage.record", let timestamp,
                      let usage = event["usage"] as? [String: Any] else { return }
                // Cache creation is billed non-cached input; cache reads stay
                // in their own field, matching the other parsers' bucket model.
                let input = usageTokens(usage["inputOther"]) + usageTokens(usage["inputCacheCreation"])
                let outputTokens = usageTokens(usage["output"])
                let cached = usageTokens(usage["inputCacheRead"])
                guard input > 0 || outputTokens > 0 || cached > 0 else { return }

                let model = (event["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
                output.entries.append(VibeTokenEntry(
                    source: "kimi-code", model: model, project: project, timestamp: timestamp,
                    inputTokens: input, outputTokens: outputTokens,
                    cachedInputTokens: cached, reasoningOutputTokens: 0))
                // Each usage.record marks an assistant step completing — use it
                // as assistant timing so active-time math sees both turn sides.
                output.events.append(VibeSessionEvent(
                    sessionId: sessionDir, source: "kimi-code", project: project,
                    timestamp: timestamp, role: .assistant))
            }
        }
        return output
    }

    private struct CurrentWireFile {
        let file: URL
        let sessionDirPath: String
        let bucketProject: String
    }

    private static func findCurrentWireFiles(sessionsDir: URL) -> [CurrentWireFile] {
        let fileManager = FileManager.default
        var results: [CurrentWireFile] = []
        for workDir in childDirectories(of: sessionsDir) {
            for session in childDirectories(of: workDir) {
                let agentsDir = session.appendingPathComponent("agents")
                for agent in childDirectories(of: agentsDir) {
                    let wire = agent.appendingPathComponent("wire.jsonl")
                    if fileManager.fileExists(atPath: wire.path) {
                        results.append(CurrentWireFile(
                            file: wire, sessionDirPath: session.path,
                            bucketProject: projectFromBucketName(workDir.lastPathComponent)))
                    }
                }
            }
        }
        return results
    }

    private static func loadSessionIndex(at url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in content.split(separator: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dir = entry["sessionDir"] as? String, !dir.isEmpty,
                  let workDir = entry["workDir"] as? String,
                  let project = projectName(fromPath: workDir)
            else { continue }
            map[dir] = project
        }
        return map
    }

    /// Strip the trailing `_<hash>` from a `wd_<slug>_<hash>` bucket name so the
    /// slug can serve as a last-resort project label.
    private static func projectFromBucketName(_ name: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"^wd_(.+)_[0-9a-f]+$"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name)
        else { return name }
        return String(name[range])
    }

    // MARK: - Legacy format (~/.kimi)

    private static let legacyUserEventTypes: Set<String> = ["TurnBegin", "UserMessage", "user_message", "Input"]

    private static func parseLegacyWire(
        at url: URL, project: String, defaultModel: String, seenMessageIds: inout Set<String>
    ) -> FileOutput {
        var output = FileOutput()
        var currentModel = defaultModel
        var lastTimestampMs: Double?
        let payloadMarker = Data("\"payload\"".utf8)
        forEachLine(at: url) { line in
            // Lines without any payload are skipped wholesale by the JS parser
            // (no timestamp/model carry-over happens on them either).
            guard line.range(of: payloadMarker) != nil else { return }
            autoreleasepool {
                guard let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                let envelope = (raw["message"] as? [String: Any]) ?? raw
                let type = (envelope["type"] as? String) ?? (raw["type"] as? String)
                guard let payload = (envelope["payload"] as? [String: Any]) ?? (raw["payload"] as? [String: Any])
                else { return }

                // Float-second timestamps ride on the envelope or the payload
                // and persist across lines until the next one replaces them.
                if let seconds = strictNumber(raw["timestamp"]) {
                    lastTimestampMs = seconds * 1000
                } else if let seconds = strictNumber(payload["timestamp"]) {
                    lastTimestampMs = seconds * 1000
                }
                if let model = payload["model"] as? String, !model.isEmpty { currentModel = model }

                if let ms = lastTimestampMs, ms != 0, let timestamp = date(fromMilliseconds: ms) {
                    let role: VibeSessionRole = type.map(legacyUserEventTypes.contains) == true ? .user : .assistant
                    output.events.append(VibeSessionEvent(
                        sessionId: url.path, source: "kimi-code", project: project,
                        timestamp: timestamp, role: role))
                }

                guard type == "StatusUpdate",
                      let tokenUsage = payload["token_usage"] as? [String: Any] else { return }
                let inputOther = usageTokens(tokenUsage["input_other"])
                let cacheCreation = usageTokens(tokenUsage["input_cache_creation"])
                let outputTokens = usageTokens(tokenUsage["output"])
                let cacheRead = usageTokens(tokenUsage["input_cache_read"])
                guard inputOther > 0 || cacheCreation > 0 || outputTokens > 0 || cacheRead > 0 else { return }

                if let messageId = payload["message_id"] as? String, !messageId.isEmpty {
                    if seenMessageIds.contains(messageId) { return }
                    seenMessageIds.insert(messageId)
                }

                // No valid timestamp → skip rather than stamp "now" (same
                // stateless-rekeying duplicate hazard as the current format).
                guard let ms = lastTimestampMs, ms != 0, let timestamp = date(fromMilliseconds: ms) else { return }
                output.entries.append(VibeTokenEntry(
                    source: "kimi-code", model: currentModel, project: project, timestamp: timestamp,
                    inputTokens: inputOther + cacheCreation, outputTokens: outputTokens,
                    cachedInputTokens: cacheRead, reasoningOutputTokens: 0))
            }
        }
        return output
    }

    private struct LegacyWireFile {
        let file: URL
        let workDirHash: String
    }

    private static func findLegacyWireFiles(sessionsDir: URL) -> [LegacyWireFile] {
        let fileManager = FileManager.default
        var results: [LegacyWireFile] = []
        for workDir in childDirectories(of: sessionsDir) {
            for session in childDirectories(of: workDir) {
                let wire = session.appendingPathComponent("wire.jsonl")
                if fileManager.fileExists(atPath: wire.path) {
                    results.append(LegacyWireFile(file: wire, workDirHash: workDir.lastPathComponent))
                }
            }
        }
        return results
    }

    private static func loadLegacyProjectMap(kimiJSON url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var map: [String: String] = [:]
        if let workDirs = config["work_dirs"] as? [[String: Any]] {
            for entry in workDirs {
                guard let path = entry["path"] as? String, !path.isEmpty,
                      let name = projectName(fromPath: path) else { continue }
                map[md5Hex(path)] = name
            }
        }
        for key in ["workspaces", "projects"] {
            guard let object = config[key] as? [String: Any] else { continue }
            for (hash, info) in object {
                let path = (info as? String) ?? (info as? [String: Any]).flatMap {
                    ($0["path"] as? String) ?? ($0["dir"] as? String)
                }
                guard let path, !path.isEmpty, let name = projectName(fromPath: path) else { continue }
                map[hash] = name
            }
        }
        return map
    }

    private static func loadLegacyModel(configTOML url: URL) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
        let fullRange = NSRange(content.startIndex..., in: content)
        if let regex = try? NSRegularExpression(
            pattern: #"^\s*default_model\s*=\s*["']([^"']+)["']"#, options: [.anchorsMatchLines]),
           let match = regex.firstMatch(in: content, range: fullRange),
           let range = Range(match.range(at: 1), in: content) {
            return String(content[range])
        }
        if let regex = try? NSRegularExpression(
            pattern: #"^\s*\[models\.(?:"([^"]+)"|([A-Za-z0-9_-]+))\]"#, options: [.anchorsMatchLines]),
           let match = regex.firstMatch(in: content, range: fullRange) {
            for index in 1...2 {
                if let range = Range(match.range(at: index), in: content) { return String(content[range]) }
            }
        }
        return "unknown"
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Shared helpers

    private static func projectName(fromPath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var trimmed = path
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        guard let base = trimmed.split(separator: "/").last else { return trimmed.isEmpty ? nil : trimmed }
        return base.isEmpty ? trimmed : String(base)
    }

    /// Strict numeric coercion for fields where the JS checks `typeof === 'number'`.
    private static func strictNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// JS `Number(value)`: finite and positive, else 0.
    private static func usageTokens(_ value: Any?) -> Double {
        let number: Double?
        switch value {
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
            number = value.doubleValue
        case let value as String:
            number = Double(value.trimmingCharacters(in: .whitespaces))
        default:
            number = nil
        }
        guard let number, number.isFinite, number > 0 else { return 0 }
        return number
    }

    /// JS `new Date(ms)` validity: |ms| ≤ 8.64e15 keeps the Date in range.
    private static func date(fromMilliseconds ms: Double) -> Date? {
        guard ms.isFinite, abs(ms) <= 8.64e15 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func childDirectories(of url: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Per-file mtime/size cache (same pattern as TokenUsageScanner)

    private struct FileOutput: Sendable {
        var entries: [VibeTokenEntry] = []
        var events: [VibeSessionEvent] = []
    }

    private struct CacheEntry: Sendable {
        let modified: Date
        let size: Int
        let output: FileOutput
    }

    private static let fileCache = Mutex<[String: CacheEntry]>([:])

    /// Returns the cached parse when the file's size and mtime are unchanged.
    /// A file that changes mid-scan is re-scanned next time rather than
    /// committing a partial result.
    private static func cachedParse(at url: URL, scan: () -> FileOutput) -> FileOutput {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let before = try? url.resourceValues(forKeys: keys),
              let modified = before.contentModificationDate, let size = before.fileSize
        else { return scan() }
        let key = url.path
        if let cached = fileCache.withLock({ $0[key] }), cached.modified == modified, cached.size == size {
            return cached.output
        }
        let output = scan()
        let after = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys)
        if after?.contentModificationDate == modified, after?.fileSize == size {
            fileCache.withLock { $0[key] = CacheEntry(modified: modified, size: size, output: output) }
        }
        return output
    }

    /// Streams a JSONL file one line at a time; only an unfinished row is
    /// retained between 64KB reads (TokenUsageScanner's pattern — these files
    /// can reach hundreds of MB and must not be loaded whole).
    private static func forEachLine(at url: URL, consume: (Data) -> Void) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }
        var pending = Data()
        pending.reserveCapacity(256 * 1024)
        var start = pending.startIndex
        while true {
            guard let chunk = try? file.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            pending.append(chunk)
            var end = start
            var index = start
            while index < pending.endIndex {
                if pending[index] == 10 {
                    consume(Data(pending[end..<index]))
                    end = pending.index(after: index)
                }
                index = pending.index(after: index)
            }
            start = end
            // Compact the consumed prefix only after 1MB accumulates: doing it
            // every chunk copied the whole remainder each time (O(n^2)).
            if pending.distance(from: pending.startIndex, to: start) > 1_048_576 {
                pending.removeFirst(pending.distance(from: pending.startIndex, to: start))
                start = pending.startIndex
            }
        }
        if start < pending.endIndex { consume(Data(pending[start...])) }
    }
}
