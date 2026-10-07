import Foundation
import OSLog

/// Qoder parser — Swift port of vibe-usage `src/parsers/qoder.js` (introduced
/// in upstream 5380334, with the routing-tier model-key namespacing fix of
/// 3f82a4e) plus the path resolution of `src/qoder-roots.js`.
///
/// Qoder (Alibaba's agentic coding platform) ships two editions with fully
/// separate accounts, billing, model pools and data directories:
///
///   edition     CLI config dir   IDE data dir (macOS)
///   'qoder'     ~/.qoder         ~/Library/Application Support/Qoder
///   'qoder-cn'  ~/.qoder-cn      ~/Library/Application Support/QoderCN
///
/// Each edition has two local data shapes:
///
/// 1. The IDE's SQLite store <ideDataDir>/SharedClientCache/cache/db/local.db:
///    table chat_message with `token_info` JSON { prompt_tokens, cached_tokens,
///    completion_tokens, max_input_tokens } and `model_info` JSON { model_key }.
///    Real tokens (prompt_tokens INCLUDES cached_tokens), no credits. → entries
///    + events.
///
/// 2. JSONL transcripts (CLI + desktop app share them — the app embeds the
///    CLI): <configDir>/projects/<cwd-slug>/<sessionId>.jsonl plus sub-agent
///    files at <configDir>/projects/<cwd-slug>/<sessionId>/subagents/*.jsonl.
///    Claude Code-shaped records; `message.usage` is credit-billed with every
///    token field 0, so transcripts normally yield sessions only. Token fields
///    are still read so a future build that reports tokens is counted without
///    a parser change; credits are account funding and never collected.
///
/// Routing tiers ('auto', 'ultimate', 'performance', 'efficient', 'lite') are
/// not model ids; left bare, `auto` collides with the Cursor `auto` entry in
/// the server pricing map, so tiers are namespaced (`qoder-<tier>`, upstream
/// 3f82a4e) — they never match a price and render as unmatched, which is the
/// truthful state. Concrete model keys pass through unchanged.
///
/// Documented simplifications vs the JS original:
/// - The JS `warnings` array has no VibeParseResult equivalent: failures log
///   through OSLog (CodeBuddy/OpenCode precedent) and set skipped = true. Like
///   JS, a partial read keeps the entries/events it did collect (the engine
///   still uploads them but never prunes this source's incremental state).
/// - libsqlite3 is always present on macOS, so the JS "sqlite unavailable"
///   throw path does not exist.
/// - JS `Number(value)` accepts booleans; here booleans are treated as missing
///   (consistent with the other ports).
/// - macOS-only path resolution: the Windows/Linux IDE roots of qoder-roots.js
///   have no counterpart here.
struct VibeSyncQoderParser: VibeLogParser {
    enum Edition: Sendable {
        case international  // 'qoder'
        case cn             // 'qoder-cn'

        var source: String { self == .cn ? "qoder-cn" : "qoder" }
        var label: String { self == .cn ? "Qoder CN" : "Qoder" }
        var cliDirName: String { self == .cn ? ".qoder-cn" : ".qoder" }
        var cliEnv: String { self == .cn ? "QODERCN_CONFIG_DIR" : "QODER_CONFIG_DIR" }
        var ideDirName: String { self == .cn ? "QoderCN" : "Qoder" }
        var ideHomeEnv: String { self == .cn ? "QODER_CN_HOME" : "QODER_HOME" }
        var testProjectsEnv: String { self == .cn ? "VIBE_USAGE_QODER_CN_PROJECTS" : "VIBE_USAGE_QODER_PROJECTS" }
        var testDbEnv: String { self == .cn ? "VIBE_USAGE_QODER_CN_DB" : "VIBE_USAGE_QODER_DB" }
    }

    let edition: Edition
    var source: String { edition.source }

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")
    private static let defaultModel = "qoder-agent"

    private let projectsDir: String
    private let dbPath: String

    init(
        edition: Edition,
        projectsDir: String? = nil,
        dbPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory())
    {
        self.edition = edition
        self.projectsDir = projectsDir ?? Self.resolveProjectsDir(edition: edition, environment: environment, home: home)
        self.dbPath = dbPath ?? Self.resolveDbPath(edition: edition, environment: environment, home: home)
    }

    // MARK: - Root resolution (src/qoder-roots.js)

    private static func expandHome(_ path: String, home: String) -> String {
        path.hasPrefix("~") ? home + path.dropFirst() : path
    }

    private static func envValue(_ key: String, environment: [String: String]) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    /// CLI/app transcript root: <configDir>/projects. The fixture override wins,
    /// then Qoder's own config-dir env, then the default home layout.
    static func resolveProjectsDir(
        edition: Edition, environment: [String: String], home: String = NSHomeDirectory()
    ) -> String {
        if let test = envValue(edition.testProjectsEnv, environment: environment) {
            return expandHome(test, home: home)
        }
        if let configured = envValue(edition.cliEnv, environment: environment) {
            var root = expandHome(configured, home: home)
            while root.hasSuffix("/") || root.hasSuffix("\\") { root.removeLast() }
            return root + "/projects"
        }
        return home + "/" + edition.cliDirName + "/projects"
    }

    /// IDE SQLite store. The fixture override wins, then QODER_HOME /
    /// QODER_CN_HOME (like Qoder's own language server), then the macOS default.
    static func resolveDbPath(
        edition: Edition, environment: [String: String], home: String = NSHomeDirectory()
    ) -> String {
        if let test = envValue(edition.testDbEnv, environment: environment) {
            return expandHome(test, home: home)
        }
        if let ideHome = envValue(edition.ideHomeEnv, environment: environment) {
            return expandHome(ideHome, home: home) + "/cache/db/local.db"
        }
        return home + "/Library/Application Support/" + edition.ideDirName
            + "/SharedClientCache/cache/db/local.db"
    }

    // MARK: - Model normalization (3f82a4e)

    private static let routingTiers: Set<String> = ["auto", "ultimate", "performance", "efficient", "lite"]

    static func normalizeModel(_ key: String?) -> String {
        let trimmed = key?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmed.isEmpty else { return defaultModel }
        return routingTiers.contains(trimmed.lowercased()) ? "qoder-\(trimmed.lowercased())" : trimmed
    }

    // MARK: - Value coercion

    /// JS Number(value) restricted to JSON numbers and numeric strings.
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

    /// JS toCount: finite positive number, else 0.
    private static func toCount(_ value: Any?) -> Double {
        guard let raw = jsNumber(value), raw > 0 else { return 0 }
        return raw
    }

    /// JS truthiness for the marker fields (humanInput / toolUseResult).
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

    /// JS toDate: epoch numbers with seconds/ms sniffing (< 1e12 is seconds),
    /// numeric strings take the same path, other strings parse as ISO-8601.
    private static func toDate(_ value: Any?) -> Date? {
        if let number = jsNumber(value) {
            return Date(timeIntervalSince1970: (number < 1e12 ? number * 1000 : number) / 1000)
        }
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty else {
            return nil
        }
        return VibeSyncTime.parse(string)
    }

    // MARK: - JSONL layer (CLI + desktop app)

    /// A `user` record is a human prompt unless it is a tool result being fed
    /// back (JS isHumanPrompt).
    private static func isHumanPrompt(_ record: [String: Any]) -> Bool {
        if isTruthy(record["humanInput"]) { return true }
        if (record["origin"] as? [String: Any])?["kind"] as? String == "human" { return true }
        if isTruthy(record["toolUseResult"]) { return false }
        if let content = (record["message"] as? [String: Any])?["content"] as? [Any] {
            return !content.contains { ($0 as? [String: Any])?["type"] as? String == "tool_result" }
        }
        return true
    }

    private struct UsageRecord {
        var usage: [String: Any]
        var model: String
        var project: String
        var timestamp: Date
    }

    /// One assistant message spans several lines; keep the last usage-bearing
    /// record per message id so a call is counted exactly once (JS
    /// usageByMessage). Returns nil when the file cannot be read at all — the
    /// caller marks the source skipped and keeps going, like the JS catch.
    private static func parseTranscriptFile(
        _ path: String, source: String, into result: inout VibeParseResult
    ) -> Bool {
        let fallbackSession = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var usageByMessage: [String: Int] = [:]  // key → index into usageRecords
        var usageRecords: [UsageRecord] = []

        let ok = forEachJSONLine(at: path) { record in
            guard let type = record["type"] as? String, type == "user" || type == "assistant",
                  let timestamp = toDate(record["timestamp"])
            else { return }
            let sessionId = [record["sessionId"], record["session_id"]]
                .compactMap { $0 as? String }
                .first { !$0.isEmpty } ?? fallbackSession
            let project = VibeSQLite.projectFromCwd(record["cwd"] as? String)
            let message = record["message"] as? [String: Any] ?? [:]

            if type == "user" {
                if isHumanPrompt(record) {
                    result.events.append(VibeSessionEvent(
                        sessionId: sessionId, source: source, project: project,
                        timestamp: timestamp, role: .user))
                }
                return
            }

            result.events.append(VibeSessionEvent(
                sessionId: sessionId, source: source, project: project,
                timestamp: timestamp, role: .assistant))

            guard let usage = message["usage"] as? [String: Any] else { return }
            let identity = [message["id"], record["uuid"]]
                .compactMap { $0 as? String }
                .first { !$0.isEmpty } ?? "\(path):\(usageByMessage.count)"
            let key = "\(sessionId)|\(identity)"
            let usageRecord = UsageRecord(
                usage: usage, model: normalizeModel(message["model"] as? String),
                project: project, timestamp: timestamp)
            if let index = usageByMessage[key] {
                usageRecords[index] = usageRecord  // last line of a message wins
            } else {
                usageByMessage[key] = usageRecords.count
                usageRecords.append(usageRecord)
            }
        }
        guard ok else { return false }

        for record in usageRecords {
            // Cache writes join input (same convention as the Claude Code parser).
            let input = toCount(record.usage["input_tokens"]) + toCount(record.usage["cache_creation_input_tokens"])
            let cached = cachedTokens(record.usage)
            let output = toCount(record.usage["output_tokens"])
            if input + cached + output == 0 { continue }  // credit-billed call: tokens not reported
            result.entries.append(VibeTokenEntry(
                source: source,
                model: record.model,
                project: record.project,
                timestamp: record.timestamp,
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: cached,
                reasoningOutputTokens: 0))
        }
        return true
    }

    private static func cachedTokens(_ usage: [String: Any]) -> Double {
        // JS `usage.cache_read_input_tokens ?? usage.cached_tokens`: absent or
        // null cache_read falls back to cached_tokens.
        if let raw = usage["cache_read_input_tokens"], !(raw is NSNull) { return toCount(raw) }
        return toCount(usage["cached_tokens"])
    }

    /// Recursive *.jsonl collection under the projects root. A missing root is
    /// simply empty; an unreadable directory branch marks the source skipped
    /// (JS listJsonlFiles warns and sets ctx.skipped).
    private func listTranscripts(_ root: String, result: inout VibeParseResult) -> [String] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        var files: [String] = []
        func walk(_ directory: String) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                result.skipped = true
                Self.logger.warning("\(self.source, privacy: .public): cannot read \(directory, privacy: .public)")
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
        walk(root)
        return files
    }

    private func parseTranscripts(into result: inout VibeParseResult) {
        for file in listTranscripts(projectsDir, result: &result) {
            if !Self.parseTranscriptFile(file, source: source, into: &result) {
                // A half-written or unreadable transcript: keep prior upload
                // state (skipped), retry next run.
                result.skipped = true
                Self.logger.warning("\(self.source, privacy: .public): cannot read \(file, privacy: .public)")
            }
        }
    }

    // MARK: - IDE SQLite layer

    // Only token/model/timing columns are selected; message content, tool
    // results and summaries are never read.
    private static let ideColumns = """
        cm.id AS id,
        cm.session_id AS sessionId,
        cm.request_id AS requestId,
        cm.role AS role,
        cm.token_info AS tokenInfo,
        cm.model_info AS modelInfo,
        cm.gmt_create AS created
        """

    private static let ideQueryWithSession = """
        SELECT \(ideColumns),
          cs.project_uri AS projectUri,
          cs.project_name AS projectName,
          cs.preferred_model_info AS preferredModelInfo
          FROM chat_message cm
          LEFT JOIN chat_session cs ON cs.session_id = cm.session_id
          WHERE cm.role IN ('user', 'assistant')
        """

    private static let ideQueryPlain = """
        SELECT \(ideColumns)
          FROM chat_message cm
          WHERE cm.role IN ('user', 'assistant')
        """

    private static func isMissingTable(_ error: VibeSQLiteError, _ table: String) -> Bool {
        error.message.range(
            of: "no such table:\\s*\(table)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func queryIdeRows(_ dbPath: String) throws -> [VibeSQLiteRow] {
        do {
            return try VibeSQLite.querySnapshotOnLock(
                databasePath: dbPath, sql: ideQueryWithSession, tempPrefix: "vibe-usage-qoder-")
        } catch let error as VibeSQLiteError {
            // Older Qoder CN builds have no chat_session table; degrade to
            // unattributed projects.
            if isMissingTable(error, "chat_session") {
                do {
                    return try VibeSQLite.querySnapshotOnLock(
                        databasePath: dbPath, sql: ideQueryPlain, tempPrefix: "vibe-usage-qoder-")
                } catch let plainError as VibeSQLiteError where isMissingTable(plainError, "chat_message") {
                    return []
                }
            }
            if isMissingTable(error, "chat_message") { return [] }
            throw error
        }
    }

    private static func jsonObject(_ value: VibeSQLiteValue) -> [String: Any]? {
        guard case .text(let text) = value,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object
    }

    private static func ideProject(_ row: VibeSQLiteRow) -> String {
        let uri = row["projectUri"].jsString?.trimmingCharacters(in: .whitespaces) ?? ""
        if !uri.isEmpty {
            if uri.hasPrefix("file://") {
                if let url = URL(string: uri) {
                    let path = url.path(percentEncoded: false)
                    if !path.isEmpty { return VibeSQLite.projectFromCwd(path) }
                }
                // fall through to project_name
            } else {
                return VibeSQLite.projectFromCwd(uri)
            }
        }
        let name = row["projectName"].jsString?.trimmingCharacters(in: .whitespaces) ?? ""
        // '.' is Qoder's "no project" sentinel.
        return !name.isEmpty && name != "." ? name : "unknown"
    }

    private static func ideModel(_ row: VibeSQLiteRow) -> String {
        let info = jsonObject(row["modelInfo"])
        let preferred = jsonObject(row["preferredModelInfo"])
        let key = [info?["model_key"], info?["modelKey"], preferred?["model_key"], preferred?["modelKey"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
        return normalizeModel(key)
    }

    /// JS toDate over a SQLite value: integer/real epoch with seconds/ms
    /// sniffing, numeric text likewise, other text parses as ISO-8601.
    private static func ideDate(_ value: VibeSQLiteValue) -> Date? {
        switch value {
        case .integer, .double:
            let number = value.jsNumber
            guard number.isFinite else { return nil }
            return Date(timeIntervalSince1970: (number < 1e12 ? number * 1000 : number) / 1000)
        case .text(let string):
            return toDate(string)
        case .null:
            return nil
        }
    }

    private func parseIde(into result: inout VibeParseResult) {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        let rows: [VibeSQLiteRow]
        do {
            rows = try Self.queryIdeRows(dbPath)
        } catch {
            // Schema drift or a transient read failure: fail soft so incremental
            // state for this source is not pruned.
            result.skipped = true
            Self.logger.warning(
                "\(self.source, privacy: .public): cannot read \(self.dbPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        for row in rows {
            guard let timestamp = Self.ideDate(row["created"]) else { continue }
            let project = Self.ideProject(row)
            let sessionId = row["sessionId"].jsString.map { $0.isEmpty ? "unknown" : $0 } ?? "unknown"
            let role: VibeSessionRole = row["role"].jsString == "user" ? .user : .assistant
            result.events.append(VibeSessionEvent(
                sessionId: sessionId, source: source, project: project,
                timestamp: timestamp, role: role))
            guard role == .assistant else { continue }

            guard let tokens = Self.jsonObject(row["tokenInfo"]) else { continue }
            let prompt = Self.toCount(tokens["prompt_tokens"])
            let cached = min(prompt, Self.toCount(tokens["cached_tokens"]))
            let completion = Self.toCount(tokens["completion_tokens"])
            if prompt + completion == 0 { continue }

            result.entries.append(VibeTokenEntry(
                source: source,
                model: Self.ideModel(row),
                project: project,
                timestamp: timestamp,
                // prompt_tokens already includes cached_tokens.
                inputTokens: prompt - cached,
                outputTokens: completion,
                cachedInputTokens: cached,
                reasoningOutputTokens: 0))
        }
    }

    // MARK: - Streaming JSONL

    /// Read one 64KB chunk at a time; retain only an unfinished row between
    /// reads. Corrupt/non-object lines are skipped, never fatal — Qoder may be
    /// appending the final record while we snapshot it. Message contents are
    /// parsed and immediately discarded; only counts and timestamps are kept.
    /// Returns false on I/O failure.
    private static func forEachJSONLine(at path: String, consume: ([String: Any]) -> Void) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? file.close() }
        var pending = Data()
        pending.reserveCapacity(256 * 1024)
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
        // readline flushes a final newline-less line when the stream ends.
        if start < pending.endIndex { parse(Data(pending[start...])) }
        return true
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        var result = VibeParseResult()
        parseTranscripts(into: &result)
        parseIde(into: &result)
        return result
    }
}
