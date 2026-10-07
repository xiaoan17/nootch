import Foundation
import OSLog
import Synchronization

/// Devin parser — Swift port of vibe-usage `src/parsers/devin.js`
/// (+ `getDevinDbPath` from src/tools.js).
///
/// Devin (the CLI and the Desktop app's embedded agent share one backend)
/// keeps every session in a single WAL SQLite database,
/// `$XDG_DATA_HOME/devin/cli/sessions.db` (default
/// `~/.local/share/devin/cli/sessions.db`; fixture override
/// `VIBE_USAGE_DEVIN_DB`). Per-request token usage lives inside
/// `message_nodes.chat_message` → metadata.metrics on assistant rows:
/// `input_tokens` is the uncached prompt portion, `cache_creation_tokens` and
/// `cache_read_tokens` are separate counters, and `output_tokens` is the full
/// completion (there is no separate reasoning field). Cache creation folds
/// into input; the shared bucket schema has no untyped cache-write column
/// semantics for Devin (upstream never split it).
///
/// `message_nodes` is a forest: the same logical message can be stored at
/// several adjacent nodes, so rows are deduplicated by (session_id,
/// message_id). Only allow-listed identity/accounting fields are extracted via
/// json_extract; message content, cogs_json, and sessions.metadata (credit/ACU
/// billing totals — account funding, never collected) are never selected.
///
/// The JS `warnings`/sqlite-unavailable channel has no VibeParseResult
/// equivalent: libsqlite3 is always present on macOS, and every read failure
/// fails soft with skipped = true so incremental sync keeps this source's
/// last good upload state.
struct VibeSyncDevinParser: VibeLogParser {
    let source = "devin"

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    private static let nodeColumns = ["session_id", "node_id", "chat_message", "created_at"]
    private static let sessionColumns = ["id", "working_directory", "model"]

    private static let usageSQL = """
        SELECT
          m.session_id AS sessionId,
          m.row_id AS rowId,
          m.created_at AS nodeCreated,
          json_extract(m.chat_message, '$.message_id') AS messageId,
          json_extract(m.chat_message, '$.role') AS role,
          json_extract(m.chat_message, '$.metadata.is_user_input') AS isUserInput,
          json_extract(m.chat_message, '$.metadata.created_at') AS msgCreatedAt,
          json_extract(m.chat_message, '$.metadata.generation_model') AS generationModel,
          json_extract(m.chat_message, '$.metadata.metrics.input_tokens') AS inputTokens,
          json_extract(m.chat_message, '$.metadata.metrics.output_tokens') AS outputTokens,
          json_extract(m.chat_message, '$.metadata.metrics.cache_read_tokens') AS cacheReadTokens,
          json_extract(m.chat_message, '$.metadata.metrics.cache_creation_tokens') AS cacheCreationTokens,
          s.working_directory AS workingDir,
          s.model AS sessionModel
        FROM message_nodes AS m
        LEFT JOIN sessions AS s ON s.id = m.session_id
        """

    private let dbPath: String

    init(dbPath: String? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        if let dbPath {
            self.dbPath = dbPath
        } else {
            self.dbPath = Self.resolveDbPath(environment: environment, home: home)
        }
    }

    /// VIBE_USAGE_DEVIN_DB wins (relative overrides resolve against the CWD,
    /// like JS `resolve`), then $XDG_DATA_HOME, then the default layout.
    static func resolveDbPath(environment: [String: String], home: String) -> String {
        let override = environment["VIBE_USAGE_DEVIN_DB"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            if override.hasPrefix("/") { return override }
            return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(override)
        }
        let dataHome = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespaces)
        let base = (dataHome?.isEmpty == false ? dataHome! : home + "/.local/share")
        return base + "/devin/cli/sessions.db"
    }

    // MARK: - Row extraction

    private struct Record: Sendable {
        var sessionId: String
        var messageId: String
        var role: String?
        var isUserInput: Bool
        var generationModel: String?
        var sessionModel: String?
        var workingDir: String?
        var msgCreatedAt: VibeSQLiteValue
        var nodeCreated: VibeSQLiteValue
        var inputTokens: VibeSQLiteValue
        var outputTokens: VibeSQLiteValue
        var cacheReadTokens: VibeSQLiteValue
        var cacheCreationTokens: VibeSQLiteValue

        /// metadata.created_at is an ISO-8601 string with millisecond
        /// precision; the node column is integer unix seconds (defensive
        /// ms/seconds sniffing matches the sibling parsers).
        var timestamp: Date? {
            if let iso = msgCreatedAt.jsString, let date = VibeSyncTime.parse(iso) {
                return date
            }
            return VibeSQLite.sniffedUnixDate(nodeCreated, requirePositive: true)
        }
    }

    private static func extract(_ rows: [VibeSQLiteRow]) -> [Record] {
        rows.compactMap { row in
            let sessionId = row["sessionId"].jsString ?? ""
            guard !sessionId.isEmpty else { return nil }
            // The node forest stores the same logical message at several
            // adjacent nodes; dedupe on the stable message id (row id as
            // fallback when absent).
            let messageId = row["messageId"].jsString ?? "row:\(row["rowId"].jsString ?? "")"
            return Record(
                sessionId: sessionId,
                messageId: messageId,
                role: row["role"].jsString,
                isUserInput: row["isUserInput"].jsNumber == 1,
                generationModel: row["generationModel"].jsString,
                sessionModel: row["sessionModel"].jsString,
                workingDir: row["workingDir"].jsString,
                msgCreatedAt: row["msgCreatedAt"],
                nodeCreated: row["nodeCreated"],
                inputTokens: row["inputTokens"],
                outputTokens: row["outputTokens"],
                cacheReadTokens: row["cacheReadTokens"],
                cacheCreationTokens: row["cacheCreationTokens"])
        }
    }

    // MARK: - Per-database parse cache (mtime/size fingerprinted)

    private struct CacheEntry: Sendable {
        let fingerprint: VibeSQLite.DatabaseFingerprint
        let records: [Record]
    }

    private static let cache = Mutex<[String: CacheEntry]>([:])

    private func records() throws -> [Record] {
        let before = VibeSQLite.fingerprint(databasePath: dbPath)
        if let cached = Self.cache.withLock({ $0[dbPath] }), cached.fingerprint == before {
            return cached.records
        }
        // Schema guard: if a future Devin build renames or drops a relied-upon
        // column, fail soft (skipped) so incremental sync keeps this source's
        // last good upload state.
        let schemaOk = try VibeSQLite.hasColumns(
            databasePath: dbPath, table: "message_nodes",
            columns: Self.nodeColumns, tempPrefix: "vibe-usage-devin")
            && VibeSQLite.hasColumns(
                databasePath: dbPath, table: "sessions",
                columns: Self.sessionColumns, tempPrefix: "vibe-usage-devin")
        guard schemaOk else { throw VibeSQLiteError(message: "incompatible schema") }
        let rows = try VibeSQLite.querySnapshotOnLock(
            databasePath: dbPath, sql: Self.usageSQL, tempPrefix: "vibe-usage-devin")
        let records = Self.extract(rows)
        if VibeSQLite.fingerprint(databasePath: dbPath) == before {
            Self.cache.withLock { cache in
                cache[dbPath] = CacheEntry(fingerprint: before, records: records)
            }
        }
        return records
    }

    // MARK: - parse()

    func parse() throws -> VibeParseResult {
        guard FileManager.default.fileExists(atPath: dbPath) else { return VibeParseResult() }

        let allRecords: [Record]
        do {
            allRecords = try records()
        } catch {
            Self.logger.warning(
                "Devin: 无法读取 \(self.dbPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return VibeParseResult(skipped: true)
        }

        var result = VibeParseResult()
        var sessionsWithUserPrompt = Set<String>()
        var seen = Set<String>()

        for row in allRecords {
            let dedupKey = "\(row.sessionId)\u{0}\(row.messageId)"
            guard !seen.contains(dedupKey) else { continue }
            seen.insert(dedupKey)

            guard let timestamp = row.timestamp else { continue }

            let project = row.workingDir?.isEmpty == false
                ? VibeSQLite.projectFromPath(row.workingDir) : "unknown"

            // Only `is_user_input` user rows are human prompts — Devin writes
            // synthetic user records (e.g. cache_keepalive "continue" prompts)
            // that must not inflate the user-prompt count; they and tool
            // results still mark agent activity, so they join the assistant
            // side. `system` rows are prompt-assembly artifacts re-written on
            // resume and are skipped.
            if row.role != "system" {
                let role: VibeSessionRole = row.role == "user" && row.isUserInput ? .user : .assistant
                result.events.append(VibeSessionEvent(
                    sessionId: row.sessionId, source: source, project: project,
                    timestamp: timestamp, role: role))
                if role == .user { sessionsWithUserPrompt.insert(row.sessionId) }
            }

            guard row.role == "assistant" else { continue }
            let inputTokens = VibeSQLite.toCount(row.inputTokens) + VibeSQLite.toCount(row.cacheCreationTokens)
            let outputTokens = VibeSQLite.toCount(row.outputTokens)
            let cachedInputTokens = VibeSQLite.toCount(row.cacheReadTokens)
            guard inputTokens + outputTokens + cachedInputTokens > 0 else { continue }

            let model = [row.generationModel, row.sessionModel]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"
            result.entries.append(VibeTokenEntry(
                source: source,
                model: model,
                project: project,
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                reasoningOutputTokens: 0))
        }

        // Only sessions containing a real human prompt reach extractSessions —
        // keepalive-only or otherwise automated sessions still contribute
        // their token usage to the entries above.
        result.events.removeAll { !sessionsWithUserPrompt.contains($0.sessionId) }
        return result
    }
}
