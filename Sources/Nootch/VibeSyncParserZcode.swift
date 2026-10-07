import Foundation

/// ZCode parser — Swift port of vibe-usage `src/parsers/zcode.js`
/// (+ `getZcodeDbPath` from src/tools.js; dual model-key spelling from fix
/// 54b7719).
///
/// ZCode (z.ai / Zhipu's coding agent) stores everything in a SQLite
/// database at `~/.zcode/cli/db/db.sqlite` (fixture override
/// `VIBE_USAGE_ZCODE_DB`). The `message` table is the canonical source: each
/// row is one user or assistant message, with an assistant message carrying
/// per-request token usage and the working directory inside its JSON `data`
/// payload. We read it directly rather than the parallel `model_usage`
/// ledger because `message` gives us BOTH session timing (user + assistant
/// rows) and token usage in one pass, with the project path attached to each
/// message. Message content stays inside the blob — only role/model/tokens/
/// path are extracted via json_extract.
struct VibeSyncZcodeParser: VibeLogParser {
    let source = "zcode"

    // ZCode renamed the assistant message's model keys from `modelID` /
    // `providerID` to `modelId` / `providerId`; read both spellings so
    // neither build reports every bucket as `unknown`.
    private static let usageSQL = """
        SELECT
          m.session_id AS sessionId,
          m.time_created AS created,
          json_extract(m.data, '$.role') AS role,
          json_extract(m.data, '$.modelID') AS modelID,
          json_extract(m.data, '$.modelId') AS modelId,
          json_extract(m.data, '$.tokens') AS tokens,
          json_extract(m.data, '$.path.root') AS pathRoot,
          json_extract(m.data, '$.path.cwd') AS pathCwd,
          s.directory AS sessionDir
        FROM message m
        LEFT JOIN session s ON s.id = m.session_id
        """

    private let dbPath: String

    init(dbPath: String? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        self.dbPath = dbPath ?? Self.resolveDbPath(environment: environment, home: home)
    }

    /// VIBE_USAGE_ZCODE_DB wins (relative overrides resolve against the CWD,
    /// like JS `resolve`), then the default layout.
    static func resolveDbPath(environment: [String: String], home: String) -> String {
        let override = environment["VIBE_USAGE_ZCODE_DB"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            if override.hasPrefix("/") { return override }
            return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(override)
        }
        return home + "/.zcode/cli/db/db.sqlite"
    }

    /// ZCode records both `cwd` and `root`; prefer `root` (the workspace
    /// root) and fall back to `cwd`, then to the session's `directory`.
    private static func projectName(_ root: String?, _ cwd: String?, _ sessionDir: String?) -> String {
        let path = [root, cwd, sessionDir].compactMap { $0 }.first { !$0.isEmpty }
        return VibeSQLite.projectFromPath(path)
    }

    /// JS truthiness for the `!tokens.input && !tokens.output` guard:
    /// missing/zero/empty is falsy.
    private static func jsTruthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let number as NSNumber: return number.doubleValue != 0
        case let string as String: return !string.isEmpty
        default: return true
        }
    }

    /// JS numeric coercion for `tokens.input || 0` inside arithmetic.
    private static func jsNumberOrZero(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces)) ?? 0
        default: return 0
        }
    }

    func parse() throws -> VibeParseResult {
        guard FileManager.default.fileExists(atPath: dbPath) else { return VibeParseResult() }

        let rows = try VibeSQLite.querySnapshotOnLock(
            databasePath: dbPath, sql: Self.usageSQL, tempPrefix: "vibe-usage-zcode")
        guard !rows.isEmpty else { return VibeParseResult() }

        var result = VibeParseResult()
        for row in rows {
            // time_created is integer epoch milliseconds (JS new Date(ms)).
            let ms = row["created"].jsNumber
            guard ms.isFinite else { continue }
            let timestamp = Date(timeIntervalSince1970: ms / 1000)

            let project = Self.projectName(
                row["pathRoot"].jsString, row["pathCwd"].jsString, row["sessionDir"].jsString)
            let sessionId = row["sessionId"].jsString.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let role = row["role"].jsString
            result.events.append(VibeSessionEvent(
                sessionId: sessionId, source: source, project: project,
                timestamp: timestamp, role: role == "user" ? .user : .assistant))

            guard role == "assistant" else { continue }
            guard let rawTokens = row["tokens"].jsString,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(rawTokens.utf8)),
                  let tokens = parsed as? [String: Any]
            else { continue }
            guard Self.jsTruthy(tokens["input"]) || Self.jsTruthy(tokens["output"]) else { continue }

            // ZCode follows Anthropic-style usage where `input` INCLUDES the
            // cache-read tokens and `output` INCLUDES reasoning (verified
            // upstream: input + output == total). Normalize to non-overlapping
            // fields so cached/reasoning tokens aren't double-counted.
            let cachedInput = Self.jsNumberOrZero((tokens["cache"] as? [String: Any])?["read"])
            let reasoning = Self.jsNumberOrZero(tokens["reasoning"])

            let model = [row["modelID"].jsString, row["modelId"].jsString]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"
            result.entries.append(VibeTokenEntry(
                source: source,
                model: model,
                project: project,
                timestamp: timestamp,
                inputTokens: Self.jsNumberOrZero(tokens["input"]) - cachedInput,
                outputTokens: Self.jsNumberOrZero(tokens["output"]) - reasoning,
                cachedInputTokens: cachedInput,
                reasoningOutputTokens: reasoning))
        }
        return result
    }
}
