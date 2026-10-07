import Foundation
import OSLog

/// Alma parser — Swift port of vibe-usage `src/parsers/alma.js`
/// (+ `getAlmaDbPath` from src/tools.js; model normalization from fixes
/// 48b70f9/c21aaf0).
///
/// Alma (an Electron app) keeps a SQLite usage ledger at
/// `~/Library/Application Support/alma/chat_threads.db` on macOS (fixture
/// override `VIBE_USAGE_ALMA_DB`). Per-request token usage lives in
/// `usage_records`; the project name comes from the joined workspace row.
/// The `messages` table (chat bodies) is never selected.
///
/// Alma's ledger contains assistant responses only, so no session events are
/// emitted (reconstructing user turns would require reading chat records
/// outside the usage contract). Any read failure fails soft with
/// skipped = true so incremental sync keeps this source's last good upload
/// state; the JS `warnings` channel maps to OSLog.
struct VibeSyncAlmaParser: VibeLogParser {
    let source = "alma"

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    private static let usageSQL = """
        SELECT
          usage_records.model AS model,
          usage_records.timestamp AS timestamp,
          usage_records.input_tokens AS inputTokens,
          usage_records.output_tokens AS outputTokens,
          usage_records.cached_input_tokens AS cachedInputTokens,
          usage_records.reasoning_tokens AS reasoningOutputTokens,
          usage_records.cache_write_input_tokens AS cacheWriteInputTokens,
          workspaces.name AS workspaceName
        FROM usage_records
        LEFT JOIN chat_threads ON chat_threads.id = usage_records.thread_id
        LEFT JOIN workspaces ON workspaces.id = chat_threads.workspace_id
        """

    private let dbPath: String

    init(dbPath: String? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        self.dbPath = dbPath ?? Self.resolveDbPath(environment: environment, home: home)
    }

    /// VIBE_USAGE_ALMA_DB wins (relative overrides resolve against the CWD,
    /// like JS `resolve`), then the macOS Electron path. The JS win32/linux
    /// branches are unreachable in a macOS app.
    static func resolveDbPath(environment: [String: String], home: String) -> String {
        let override = environment["VIBE_USAGE_ALMA_DB"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            if override.hasPrefix("/") { return override }
            return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(override)
        }
        return home + "/Library/Application Support/alma/chat_threads.db"
    }

    /// JS normalizeAlmaModel: strip the provider prefix chain (`a:b:model` →
    /// `model`), trimming whitespace; empty/invalid values are "unknown".
    static func normalizeModel(_ value: String?) -> String {
        guard let model = value?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return "unknown"
        }
        guard let separator = model.lastIndex(of: ":") else { return model }
        let tail = model[model.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? "unknown" : tail
    }

    /// JS safeWorkspaceName: the workspace name is a display label that may
    /// hold a path; reduce it to its basename so no directory leaks.
    static func safeWorkspaceName(_ value: String?) -> String {
        guard let value else { return "unknown" }
        var normalized = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "/")
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let name = normalized.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "unknown" : name
    }

    func parse() throws -> VibeParseResult {
        guard FileManager.default.fileExists(atPath: dbPath) else { return VibeParseResult() }

        let rows: [VibeSQLiteRow]
        do {
            rows = try VibeSQLite.querySnapshotOnLock(
                databasePath: dbPath, sql: Self.usageSQL, tempPrefix: "vibe-usage-alma")
        } catch {
            Self.logger.warning(
                "Alma: 无法读取 \(self.dbPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return VibeParseResult(skipped: true)
        }

        var result = VibeParseResult()
        for row in rows {
            guard let timestampString = row["timestamp"].jsString,
                  let timestamp = VibeSyncTime.parse(timestampString)
            else { continue }

            let inputTokens = VibeSQLite.toCount(row["inputTokens"])
                + VibeSQLite.toCount(row["cacheWriteInputTokens"])
            let outputTokens = VibeSQLite.toCount(row["outputTokens"])
            let cachedInputTokens = VibeSQLite.toCount(row["cachedInputTokens"])
            let reasoningOutputTokens = VibeSQLite.toCount(row["reasoningOutputTokens"])
            guard inputTokens + outputTokens + cachedInputTokens + reasoningOutputTokens > 0
            else { continue }

            result.entries.append(VibeTokenEntry(
                source: source,
                model: Self.normalizeModel(row["model"].jsString),
                project: Self.safeWorkspaceName(row["workspaceName"].jsString),
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                reasoningOutputTokens: reasoningOutputTokens))
        }
        return result
    }
}
