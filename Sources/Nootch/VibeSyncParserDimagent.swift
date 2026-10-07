import Foundation

/// DimAgent parser — Swift port of vibe-usage `src/parsers/dimagent.js`
/// (+ `getDimAgentDbPath` from src/tools.js).
///
/// DimAgent (dimcode) keeps a SQLite database at `~/.dimcode/v2/dimcode.sqlite`
/// (relocated by `DIMCODE_HOME` or `XDG_CONFIG_HOME`; fixture override
/// `VIBE_USAGE_DIMAGENT_DB`). Per-request token usage lives in the
/// `usage_ledger` table as a JSON `usage` payload; `messages` carries the
/// user/assistant rows for session timing.
///
/// Forked sessions copy the parent's ledger rows under fresh
/// `ledger_<uuid>` ids, so forked rows whose signature matches an original
/// row are dropped; orphan clones (the original aged out) are kept once per
/// signature, matching the JS dedup contract. Message rows belonging to a
/// fork (`msg_fork_%`) are excluded from session timing the same way.
struct VibeSyncDimagentParser: VibeLogParser {
    let source = "dimagent"

    private static let forkedLedgerId = try! NSRegularExpression(
        pattern: #"^ledger_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
        options: [.caseInsensitive])

    private static let usageSQL = """
        SELECT
          u.ledgerId,
          u.runId,
          u.providerId,
          u.modelId,
          u.usage,
          u.cost,
          u.createdAt,
          s.cwd
        FROM usage_ledger u
        LEFT JOIN sessions s ON s.sessionId = u.sessionId
        """

    private static let messagesSQL = """
        SELECT
          m.sessionId,
          m.role,
          m.createdAt,
          s.cwd
        FROM messages m
        LEFT JOIN sessions s ON s.sessionId = m.sessionId
        WHERE m.role IN ('user', 'assistant')
          AND m.messageId NOT LIKE 'msg_fork_%'
        """

    private let dbPath: String

    init(dbPath: String? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        self.dbPath = dbPath ?? Self.resolveDbPath(environment: environment, home: home)
    }

    /// JS getDimAgentDbPath: VIBE_USAGE_DIMAGENT_DB wins (relative overrides
    /// resolve against the CWD), then DIMCODE_HOME/dimcode.sqlite, then
    /// $XDG_CONFIG_HOME/.dimcode/v2 or ~/.dimcode/v2.
    static func resolveDbPath(environment: [String: String], home: String) -> String {
        func resolve(_ path: String) -> String {
            path.hasPrefix("/")
                ? path
                : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        }
        let override = environment["VIBE_USAGE_DIMAGENT_DB"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty { return resolve(override) }
        let explicitHome = environment["DIMCODE_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !explicitHome.isEmpty { return resolve(explicitHome) + "/dimcode.sqlite" }
        let xdg = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = !xdg.isEmpty ? resolve(xdg) + "/.dimcode/v2" : home + "/.dimcode/v2"
        return base + "/dimcode.sqlite"
    }

    /// JS projectName: last path component, both separators.
    private static func projectName(_ cwd: String?) -> String {
        guard var value = cwd, !value.isEmpty else { return "unknown" }
        while value.hasSuffix("/") || value.hasSuffix("\\") { value.removeLast() }
        let name = value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return name.isEmpty ? "unknown" : name
    }

    private static func isForkedLedger(_ ledgerId: String) -> Bool {
        forkedLedgerId.firstMatch(
            in: ledgerId, range: NSRange(ledgerId.startIndex..., in: ledgerId)) != nil
    }

    /// JS usageSignature: identity over every accounting field, with the raw
    /// usage JSON text (not its parse tree) so a byte-identical copy matches.
    private static func usageSignature(_ row: VibeSQLiteRow) -> String {
        [
            row["runId"].jsString ?? "",
            row["providerId"].jsString ?? "",
            row["modelId"].jsString ?? "",
            row["usage"].jsString ?? "",
            row["cost"].jsString ?? "",
            row["createdAt"].jsString ?? "",
        ].joined(separator: "\0")
    }

    /// JS toCount over a parsed JSON value: finite positive number, else 0.
    private static func jsonCount(_ value: Any?) -> Double {
        let number: Double
        switch value {
        case let nsNumber as NSNumber: number = nsNumber.doubleValue
        case let string as String:
            number = Double(string.trimmingCharacters(in: .whitespaces)) ?? .nan
        default: number = .nan
        }
        return number.isFinite && number > 0 ? number : 0
    }

    private static func parseUsageRows(_ rows: [VibeSQLiteRow]) -> [VibeTokenEntry] {
        let originalSignatures = Set(rows
            .filter { !isForkedLedger($0["ledgerId"].jsString ?? "") }
            .map(usageSignature))
        var keptOrphanClones = Set<String>()

        var entries: [VibeTokenEntry] = []
        for row in rows {
            let signature = usageSignature(row)
            if isForkedLedger(row["ledgerId"].jsString ?? "") {
                if originalSignatures.contains(signature) || keptOrphanClones.contains(signature) {
                    continue
                }
                keptOrphanClones.insert(signature)
            }

            guard let rawUsage = row["usage"].jsString,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(rawUsage.utf8)),
                  let usage = parsed as? [String: Any]
            else { continue }

            guard let timestampString = row["createdAt"].jsString,
                  let timestamp = VibeSyncTime.parse(timestampString)
            else { continue }

            // promptTokens is Anthropic-style inclusive of the cache read;
            // split it so cached input is not double-counted.
            let promptTokens = jsonCount(usage["promptTokens"])
            let cachedInputTokens = jsonCount(usage["cacheReadTokens"])
            let inputTokens = max(0, promptTokens - cachedInputTokens)
            let outputTokens = jsonCount(usage["completionTokens"])
            guard inputTokens + outputTokens + cachedInputTokens > 0 else { continue }

            entries.append(VibeTokenEntry(
                source: "dimagent",
                model: row["modelId"].jsString.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
                project: projectName(row["cwd"].jsString),
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                reasoningOutputTokens: 0))
        }
        return entries
    }

    func parse() throws -> VibeParseResult {
        guard FileManager.default.fileExists(atPath: dbPath) else { return VibeParseResult() }

        let usageRows = try VibeSQLite.querySnapshotOnLock(
            databasePath: dbPath, sql: Self.usageSQL, tempPrefix: "vibe-usage-dimagent")
        let messageRows = try VibeSQLite.querySnapshotOnLock(
            databasePath: dbPath, sql: Self.messagesSQL, tempPrefix: "vibe-usage-dimagent")

        var result = VibeParseResult()
        result.entries = Self.parseUsageRows(usageRows)
        for row in messageRows {
            guard let timestampString = row["createdAt"].jsString,
                  let timestamp = VibeSyncTime.parse(timestampString)
            else { continue }
            result.events.append(VibeSessionEvent(
                sessionId: row["sessionId"].jsString.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
                source: source,
                project: Self.projectName(row["cwd"].jsString),
                timestamp: timestamp,
                role: row["role"].jsString == "user" ? .user : .assistant))
        }
        return result
    }
}
