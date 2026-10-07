import Foundation
import OSLog

/// MiMoCode (小米 MiMo) parser — Swift port of vibe-usage
/// `src/parsers/mimocode.js` (+ `getMimicodeDbPath` from src/tools.js).
///
/// The MiMoCode CLI keeps a SQLite database at
/// `$MIMOCODE_HOME/data/mimicode.db` (default
/// `~/.local/share/mimicode/mimicode.db`; `MIMOCODE_DB` relocates or renames
/// the file itself). Each `message` row carries a JSON `data` payload with
/// the role, per-request token usage (assistant rows only), and the model id;
/// the project comes from the joined `session.directory`. Message *content*
/// stays inside the JSON blob — only role/time/tokens/model are read.
///
/// Sessions recorded in the optional `external_import` table were imported
/// from other tools (e.g. claude-code) and are excluded so their usage is
/// not double-reported under two sources.
struct VibeSyncMimocodeParser: VibeLogParser {
    let source = "mimocode"

    enum ResolutionError: Error, Equatable {
        case relativeHome(value: String)
    }

    private let dbPath: String
    private let resolutionError: ResolutionError?

    init(dbPath: String? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        if let dbPath {
            self.dbPath = dbPath
            self.resolutionError = nil
            return
        }
        do {
            self.dbPath = try Self.resolveDbPath(environment: environment, home: home)
            self.resolutionError = nil
        } catch let error as ResolutionError {
            self.dbPath = ""
            self.resolutionError = error
        } catch {
            self.dbPath = ""
            self.resolutionError = nil
        }
    }

    /// JS getMimicodeDbPath: MIMOCODE_HOME (must be absolute) replaces the
    /// data root; MIMOCODE_DB overrides the file, relative names staying
    /// inside the data dir.
    static func resolveDbPath(environment: [String: String], home: String) throws -> String {
        let mimoHome = environment["MIMOCODE_HOME"] ?? ""
        if !mimoHome.isEmpty, !mimoHome.hasPrefix("/") {
            throw ResolutionError.relativeHome(value: mimoHome)
        }
        let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let dataDir = !mimoHome.isEmpty
            ? mimoHome + "/data"
            : !xdg.isEmpty ? xdg + "/mimicode" : home + "/.local/share/mimicode"
        let db = environment["MIMOCODE_DB"] ?? ""
        if db.isEmpty { return dataDir + "/mimicode.db" }
        return db.hasPrefix("/") ? db : dataDir + "/" + db
    }

    // MARK: - JS value coercion over parsed message JSON

    /// JS `Number(value) || 0`: numbers pass through, numeric strings parse,
    /// anything else (missing key, NaN, garbage) is 0.
    private static func jsNumberOrZero(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number.doubleValue : 0
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces)) ?? 0
        default:
            return 0
        }
    }

    /// JS `new Date(value)`: numbers are epoch milliseconds, strings are
    /// parsed as ISO-8601.
    private static func jsDate(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let ms = number.doubleValue
            return ms.isFinite ? Date(timeIntervalSince1970: ms / 1000) : nil
        case let string as String:
            return VibeSyncTime.parse(string)
        default:
            return nil
        }
    }

    // MARK: - parse()

    func parse() throws -> VibeParseResult {
        if let resolutionError { throw resolutionError }
        guard FileManager.default.fileExists(atPath: dbPath) else { return VibeParseResult() }

        // external_import only exists on builds that support importing
        // sessions from other tools; join/filter it out when present.
        let hasExternalImports = try !VibeSQLite.querySnapshotOnLock(
            databasePath: dbPath,
            sql: """
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'external_import' LIMIT 1
                """,
            tempPrefix: "vibe-usage-mimicode").isEmpty
        let join = hasExternalImports
            ? "LEFT JOIN external_import ON external_import.session_id = message.session_id"
            : ""
        let filter = hasExternalImports ? "WHERE external_import.session_id IS NULL" : ""
        let rows = try VibeSQLite.querySnapshotOnLock(
            databasePath: dbPath,
            sql: """
                SELECT
                  message.session_id AS sessionID,
                  message.time_created AS created,
                  message.data AS data,
                  session.directory AS directory
                FROM message
                JOIN session ON session.id = message.session_id
                \(join)
                \(filter)
                """,
            tempPrefix: "vibe-usage-mimicode")

        var result = VibeParseResult()
        for row in rows {
            guard let rawData = row["data"].jsString,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(rawData.utf8)),
                  let data = parsed as? [String: Any],
                  let role = data["role"] as? String,
                  role == "user" || role == "assistant"
            else { continue }

            let timestamp = Self.jsDate((data["time"] as? [String: Any])?["created"])
                ?? VibeSQLite.sniffedUnixDate(row["created"], requirePositive: false)
            guard let timestamp else { continue }

            let project = VibeSQLite.projectFromPath(row["directory"].jsString)
            let sessionId = row["sessionID"].jsString.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            result.events.append(VibeSessionEvent(
                sessionId: sessionId, source: source, project: project,
                timestamp: timestamp, role: role == "user" ? .user : .assistant))

            guard role == "assistant",
                  let model = data["modelID"] as? String, !model.isEmpty,
                  let tokens = data["tokens"] as? [String: Any]
            else { continue }

            let cache = tokens["cache"] as? [String: Any]
            let inputTokens = Self.jsNumberOrZero(tokens["input"])
                + Self.jsNumberOrZero(cache?["write"])
            let outputTokens = Self.jsNumberOrZero(tokens["output"])
            let reasoningOutputTokens = Self.jsNumberOrZero(tokens["reasoning"])
            let cachedInputTokens = Self.jsNumberOrZero(cache?["read"])
            guard inputTokens + outputTokens + reasoningOutputTokens + cachedInputTokens > 0
            else { continue }

            result.entries.append(VibeTokenEntry(
                source: source,
                model: model,
                project: project,
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                reasoningOutputTokens: reasoningOutputTokens))
        }
        return result
    }
}
