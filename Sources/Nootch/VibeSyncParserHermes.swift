import Foundation

/// Hermes parser — Swift port of vibe-usage `src/parsers/hermes.js`
/// (+ `discoverHermesDatabases` from src/hermes-roots.js).
///
/// Hermes supports multiple profiles: the default profile lives at
/// `<home>/state.db`, named profiles at `<home>/profiles/<name>/state.db`.
/// The home is shared by CLI/Desktop: `~/.hermes` on macOS, or an explicit
/// `HERMES_HOME` (the Windows LOCALAPPDATA layout is unreachable in a macOS
/// app). Each profile is an independent HERMES_HOME with its own state.db,
/// so all of them are scanned; the profile name doubles as the project.
///
/// Token buckets come from the `sessions` table (cumulative per-session
/// totals); session timing comes from the `messages` table. Discovery and
/// read failures throw (JS contract: a partial result must never let sync
/// prune a profile's previously uploaded state); the sync engine records the
/// source as failed, which protects that state the same way.
struct VibeSyncHermesParser: VibeLogParser {
    let source = "hermes"

    struct Database: Sendable, Equatable {
        let path: String
        let profile: String
    }

    private let pinnedDatabases: [Database]?
    private let environment: [String: String]
    private let home: String

    init(databases: [Database]? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        self.pinnedDatabases = databases
        self.environment = environment
        self.home = home
    }

    /// JS getHermesHome, macOS branch: HERMES_HOME wins, else ~/.hermes.
    static func resolveHome(environment: [String: String], home: String) -> String {
        let explicit = environment["HERMES_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return explicit.isEmpty ? home + "/.hermes" : explicit
    }

    /// stat() that tolerates a missing path but propagates real I/O errors
    /// (e.g. EACCES), like hermes-roots.js statIfPresent with a throwing
    /// onError.
    private static func attributes(of path: String) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        {
            return nil
        }
    }

    /// JS discoverHermesDatabases: the default state.db plus every
    /// profiles/<name>/state.db, sorted by profile name for determinism.
    static func discoverDatabases(
        environment: [String: String], home: String
    ) throws -> [Database] {
        let root = resolveHome(environment: environment, home: home)
        var dbs: [Database] = []
        if try attributes(of: root + "/state.db") != nil {
            dbs.append(Database(path: root + "/state.db", profile: "default"))
        }
        let profilesDir = root + "/profiles"
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: profilesDir)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        {
            return dbs
        }
        for name in names.sorted() {
            let profileDb = profilesDir + "/" + name + "/state.db"
            guard try attributes(of: profileDb).map({
                ($0[.type] as? FileAttributeType) == .typeRegular
            }) == true else { continue }
            dbs.append(Database(path: profileDb, profile: name))
        }
        return dbs
    }

    private static let messagesSQL = """
        SELECT
          session_id as sessionId,
          role,
          timestamp
        FROM messages
        WHERE role IN ('user', 'assistant')
        ORDER BY timestamp
        """

    /// started_at / messages.timestamp are Unix seconds (float).
    private static func secondsDate(_ value: VibeSQLiteValue) -> Date? {
        let seconds = value.jsNumber
        return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }

    private func parseDatabase(_ db: Database, into result: inout VibeParseResult) throws {
        // The cache-write column only exists on newer schemas; substitute a
        // constant 0 on legacy databases like the JS version does.
        let columns = Set(try VibeSQLite.querySnapshotOnLock(
            databasePath: db.path, sql: "PRAGMA table_info(sessions)",
            tempPrefix: "vibe-usage-hermes").compactMap { $0["name"].jsString })
        let cacheWrite = columns.contains("cache_write_tokens") ? "cache_write_tokens" : "0"

        let sessionRows = try VibeSQLite.querySnapshotOnLock(
            databasePath: db.path,
            sql: """
                SELECT
                  id,
                  model,
                  started_at as startedAt,
                  input_tokens as inputTokens,
                  output_tokens as outputTokens,
                  cache_read_tokens as cacheReadTokens,
                  \(cacheWrite) as cacheWriteTokens,
                  reasoning_tokens as reasoningTokens
                FROM sessions
                WHERE input_tokens > 0 OR output_tokens > 0
                  OR cache_read_tokens > 0 OR \(cacheWrite) > 0 OR reasoning_tokens > 0
                """,
            tempPrefix: "vibe-usage-hermes")

        for row in sessionRows {
            guard let timestamp = Self.secondsDate(row["startedAt"]) else { continue }
            // Hermes stores input_tokens exclusive of cache (Anthropic-style
            // semantics) and output_tokens inclusive of reasoning
            // (CanonicalUsage.total_tokens adds prompt + output only). Split
            // reasoning instead of counting it twice, bounded by the output.
            let output = VibeSQLite.toCount(row["outputTokens"])
            let reasoning = min(output, VibeSQLite.toCount(row["reasoningTokens"]))
            result.entries.append(VibeTokenEntry(
                source: source,
                model: row["model"].jsString.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
                project: db.profile,
                timestamp: timestamp,
                inputTokens: VibeSQLite.toCount(row["inputTokens"])
                    + VibeSQLite.toCount(row["cacheWriteTokens"]),
                outputTokens: output - reasoning,
                cachedInputTokens: VibeSQLite.toCount(row["cacheReadTokens"]),
                reasoningOutputTokens: reasoning))
        }

        // A failed query is not an empty session history: let the throw
        // propagate so sync protects this source's previous state instead of
        // uploading/pruning a partial result.
        let messageRows = try VibeSQLite.querySnapshotOnLock(
            databasePath: db.path, sql: Self.messagesSQL, tempPrefix: "vibe-usage-hermes")
        for row in messageRows {
            guard let timestamp = Self.secondsDate(row["timestamp"]) else { continue }
            result.events.append(VibeSessionEvent(
                sessionId: row["sessionId"].jsString.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
                source: source,
                project: db.profile,
                timestamp: timestamp,
                role: row["role"].jsString == "user" ? .user : .assistant))
        }
    }

    func parse() throws -> VibeParseResult {
        // Discovery happens at parse time: an unreadable profiles dir is a
        // parse failure, not an empty store.
        let databases = try pinnedDatabases
            ?? Self.discoverDatabases(environment: environment, home: home)
        var result = VibeParseResult()
        for db in databases {
            try parseDatabase(db, into: &result)
        }
        return result
    }
}
