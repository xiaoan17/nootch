import Foundation
import OSLog
import Synchronization

/// CodeArts Agent (华为 CodeArts) parser — Swift port of vibe-usage
/// `src/parsers/codearts-agent.js` + `src/codearts-roots.js`.
///
/// CodeArts Agent uses an OpenCode-derived WAL database at
/// `~/.codeartsdoer/codearts-data/opencode.db`, but it is a separate
/// product/account and therefore a separate source. The recursive map folds
/// child-agent sessions into their top-level user session; all child model
/// calls remain billable while their injected `user` messages never become
/// human prompts. Only identity, timing, model, project and token counters are
/// selected. Message/part content, tools, errors, costs, account data and the
/// CodeArts JSON/log files stay unread.
///
/// Cache-write pricing (upstream fix 0d4b6e9): the store only gives one
/// cache-write total with no per-TTL breakdown, so an untyped write is priced
/// as the cheaper 5m bucket rather than folded into input.
///
/// The JS `warnings` array has no VibeParseResult equivalent; warnings log via
/// OSLog (Grok parser precedent). Any warning still suppresses the whole
/// source (skipped = true), matching the JS contract.
struct VibeSyncCodeArtsParser: VibeLogParser {
    let source = "codearts-agent"

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    private static let usageSQL = """
        WITH RECURSIVE session_tree(
          sessionId, logicalSessionId, logicalDirectory, isChild, trail
        ) AS (
          SELECT s.id, s.id, s.directory, 0, ',' || s.id || ','
          FROM session AS s
          WHERE s.parent_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM session AS p WHERE p.id = s.parent_id)
          UNION ALL
          SELECT s.id, t.logicalSessionId, t.logicalDirectory, 1,
            t.trail || s.id || ','
          FROM session AS s
          JOIN session_tree AS t ON s.parent_id = t.sessionId
          WHERE instr(t.trail, ',' || s.id || ',') = 0
        ), session_map AS (
          SELECT
            s.id AS sessionId,
            coalesce(t.logicalSessionId, s.id) AS logicalSessionId,
            coalesce(t.logicalDirectory, s.directory) AS logicalDirectory,
            s.directory AS physicalDirectory,
            coalesce(t.isChild, 0) AS isChild
          FROM session AS s
          LEFT JOIN session_tree AS t ON t.sessionId = s.id
        )
        SELECT
          m.id AS messageId,
          m.session_id AS physicalSessionId,
          coalesce(sm.logicalSessionId, m.session_id) AS logicalSessionId,
          coalesce(sm.isChild, 0) AS isChild,
          sm.logicalDirectory AS logicalDirectory,
          sm.physicalDirectory AS physicalDirectory,
          m.time_created AS columnCreated,
          json_extract(m.data, '$.role') AS role,
          json_extract(m.data, '$.time.created') AS dataCreated,
          coalesce(
            json_extract(m.data, '$.modelID'),
            json_extract(m.data, '$.modelId'),
            json_extract(m.data, '$.model.modelID'),
            json_extract(m.data, '$.model.modelId')
          ) AS model,
          json_extract(m.data, '$.path.root') AS rootPath,
          json_extract(m.data, '$.path.cwd') AS cwdPath,
          json_extract(m.data, '$.tokens.input') AS inputTokens,
          json_extract(m.data, '$.tokens.output') AS outputTokens,
          json_extract(m.data, '$.tokens.cache.read') AS cacheReadTokens,
          json_extract(m.data, '$.tokens.cache.write') AS cacheWriteTokens,
          json_extract(m.data, '$.tokens.reasoning') AS reasoningTokens
        FROM message AS m
        LEFT JOIN session_map AS sm ON sm.sessionId = m.session_id
        ORDER BY m.time_created, m.id
        """

    private let roots: [String]

    init(roots: [String]? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        if let roots {
            self.roots = roots
        } else {
            self.roots = Self.resolveRoots(environment: environment, home: home)
        }
    }

    // MARK: - Root / database discovery (src/codearts-roots.js)

    /// VIBE_USAGE_CODEARTS_AGENT_DIRS (PATH-delimited) wins; default is the
    /// home-relative location used by the desktop agent kernel.
    static func resolveRoots(environment: [String: String], home: String) -> [String] {
        let override = environment["VIBE_USAGE_CODEARTS_AGENT_DIRS"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if override.isEmpty {
            return [home + "/.codeartsdoer/codearts-data"]
        }
        return override.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { normalizeRoot($0, home: home) }
    }

    private static func normalizeRoot(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            return home + "/" + path.dropFirst(2)
        }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        return ((FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent(path) as NSString).standardizingPath
    }

    /// Locate the accounting databases. A root may point at the data
    /// directory, its `.codeartsdoer` parent, or `opencode.db` itself.
    /// (The JS version warns on stat errors other than ENOENT/ENOTDIR;
    /// FileManager.fileExists cannot distinguish those, so discovery stays
    /// silent and only read failures suppress the source.)
    static func findDatabases(roots: [String]) -> [String] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var paths: [String] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory) else { continue }
            let candidates = isDirectory.boolValue
                ? [root + "/opencode.db", root + "/codearts-data/opencode.db"]
                : [root]
            for candidate in candidates {
                var candidateIsDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate, isDirectory: &candidateIsDirectory),
                      !candidateIsDirectory.boolValue,
                      (candidate as NSString).lastPathComponent == "opencode.db",
                      access(candidate, R_OK) == 0
                else { continue }
                let canonical = (candidate as NSString).resolvingSymlinksInPath
                guard !seen.contains(canonical) else { continue }
                seen.insert(canonical)
                paths.append(canonical)
                break
            }
        }
        return paths
    }

    // MARK: - Row extraction

    private struct Record: Sendable {
        var messageId: String?
        var physicalSessionId: String?
        var logicalSessionId: String?
        var isChild: Bool
        var logicalDirectory: String?
        var physicalDirectory: String?
        var role: String?
        var model: String?
        var rootPath: String?
        var cwdPath: String?
        var timestamp: Date
        var inputTokens: VibeSQLiteValue
        var outputTokens: VibeSQLiteValue
        var cacheReadTokens: VibeSQLiteValue
        var cacheWriteTokens: VibeSQLiteValue
        var reasoningTokens: VibeSQLiteValue

        var tokenFootprint: Double {
            VibeSQLite.toCount(inputTokens) + VibeSQLite.toCount(outputTokens)
                + VibeSQLite.toCount(cacheReadTokens) + VibeSQLite.toCount(cacheWriteTokens)
                + VibeSQLite.toCount(reasoningTokens)
        }
    }

    /// JS timestampFrom(dataCreated, columnCreated): the data field wins when
    /// present; numbers sniff ms vs seconds; strings parse as ISO-8601 (JS
    /// `new Date(string)` accepts a few more formats, none of which CodeArts
    /// writes).
    private static func recordTimestamp(_ row: VibeSQLiteRow) -> Date? {
        let dataCreated = row["dataCreated"]
        if dataCreated != .null {
            return VibeSQLite.sniffedUnixDate(dataCreated, requirePositive: true)
        }
        return VibeSQLite.sniffedUnixDate(row["columnCreated"], requirePositive: true)
    }

    private static func extract(_ rows: [VibeSQLiteRow]) -> [Record] {
        rows.compactMap { row in
            guard let timestamp = recordTimestamp(row) else { return nil }
            return Record(
                messageId: row["messageId"].jsString,
                physicalSessionId: row["physicalSessionId"].jsString,
                logicalSessionId: row["logicalSessionId"].jsString,
                isChild: row["isChild"].jsNumber == 1,
                logicalDirectory: row["logicalDirectory"].jsString,
                physicalDirectory: row["physicalDirectory"].jsString,
                role: row["role"].jsString,
                model: row["model"].jsString,
                rootPath: row["rootPath"].jsString,
                cwdPath: row["cwdPath"].jsString,
                timestamp: timestamp,
                inputTokens: row["inputTokens"],
                outputTokens: row["outputTokens"],
                cacheReadTokens: row["cacheReadTokens"],
                cacheWriteTokens: row["cacheWriteTokens"],
                reasoningTokens: row["reasoningTokens"])
        }
    }

    // MARK: - Per-database parse cache (mtime/size fingerprinted)

    private struct CacheEntry: Sendable {
        let fingerprint: VibeSQLite.DatabaseFingerprint
        let records: [Record]
    }

    private static let cache = Mutex<[String: CacheEntry]>([:])

    private func cachedRecords(databasePath path: String) throws -> [Record] {
        let before = VibeSQLite.fingerprint(databasePath: path)
        if let cached = Self.cache.withLock({ $0[path] }), cached.fingerprint == before {
            return cached.records
        }
        let rows = try VibeSQLite.querySnapshotOnLock(
            databasePath: path, sql: Self.usageSQL, tempPrefix: "vibe-usage-codearts-agent")
        let records = Self.extract(rows)
        // Commit only if the files did not change mid-read; a changing
        // database is re-queried next sync rather than caching a partial read.
        if VibeSQLite.fingerprint(databasePath: path) == before {
            Self.cache.withLock { cache in
                if cache.count >= 64, cache[path] == nil, let oldest = cache.keys.first {
                    cache.removeValue(forKey: oldest)
                }
                cache[path] = CacheEntry(fingerprint: before, records: records)
            }
        }
        return records
    }

    // MARK: - parse()

    func parse() throws -> VibeParseResult {
        let dbPaths = Self.findDatabases(roots: roots)
        var warningCount = 0

        // Dedup by (session, message id) across databases, keeping the copy
        // with the largest token footprint (JS records Map).
        var records: [String: Record] = [:]
        var order: [String] = []
        for dbPath in dbPaths {
            let rows: [Record]
            do {
                rows = try cachedRecords(databasePath: dbPath)
            } catch {
                warningCount += 1
                Self.logger.warning(
                    "CodeArts Agent: 无法读取 \(dbPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            for (index, row) in rows.enumerated() {
                let sessionId = row.physicalSessionId ?? ""
                let messageId = row.messageId ?? ""
                let key = !sessionId.isEmpty && !messageId.isEmpty
                    ? "msg\u{0}\(sessionId)\u{0}\(messageId)"
                    : "row\u{0}\(dbPath)\u{0}\(index)"
                if let previous = records[key] {
                    if row.tokenFootprint > previous.tokenFootprint { records[key] = row }
                } else {
                    records[key] = row
                    order.append(key)
                }
            }
        }

        // A partial multi-profile read would look like legitimate deletion to
        // the incremental sync layer. Suppress the entire source until every
        // discovered database can be read again.
        if warningCount > 0 { return VibeParseResult(skipped: true) }

        var result = VibeParseResult()
        var sessionsWithUserPrompt = Set<String>()
        for key in order {
            guard let row = records[key] else { continue }
            // JS `a || b || c`: empty strings fall through to the next candidate.
            let project = VibeSQLite.projectFromCwd(
                [row.rootPath, row.cwdPath, row.logicalDirectory, row.physicalDirectory]
                    .compactMap { $0 }.first { !$0.isEmpty })
            let sessionId = [row.logicalSessionId, row.physicalSessionId]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "unknown"
            if let role = row.role, !role.isEmpty {
                let isHumanPrompt = role == "user" && !row.isChild
                result.events.append(VibeSessionEvent(
                    sessionId: sessionId, source: source, project: project,
                    timestamp: row.timestamp, role: isHumanPrompt ? .user : .assistant))
                if isHumanPrompt { sessionsWithUserPrompt.insert(sessionId) }
            }

            guard row.role == "assistant" else { continue }
            let inputTokens = VibeSQLite.toCount(row.inputTokens)
            let outputTokens = VibeSQLite.toCount(row.outputTokens)
            let cachedInputTokens = VibeSQLite.toCount(row.cacheReadTokens)
            let reasoningOutputTokens = VibeSQLite.toCount(row.reasoningTokens)
            let cacheCreation5mTokens = VibeSQLite.toCount(row.cacheWriteTokens)
            guard inputTokens + outputTokens + cachedInputTokens + reasoningOutputTokens
                + cacheCreation5mTokens > 0 else { continue }

            result.entries.append(VibeTokenEntry(
                source: source,
                model: row.model?.isEmpty == false ? row.model! : "unknown",
                project: project,
                timestamp: row.timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                cacheCreation5mTokens: cacheCreation5mTokens))
        }

        // Only sessions containing a real human prompt reach extractSessions.
        result.events.removeAll { !sessionsWithUserPrompt.contains($0.sessionId) }
        return result
    }
}
