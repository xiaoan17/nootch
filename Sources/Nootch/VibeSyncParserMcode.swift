import Foundation
import OSLog
import Synchronization

/// MiniMax Code (mcode) parser — Swift port of vibe-usage `src/parsers/mcode.js`
/// (+ `getMcodeDbPath`/`getMcodeDbPaths` from src/tools.js, multi-root layout
/// from fix af60927).
///
/// The mcode CLI keeps a WAL database at
/// `<root>/v2/sqlite/runtime-state.sqlite`. Worth-reading roots:
/// `~/.minimax` + `~/.minimax-<profile>` per active profile + the pre-npm
/// `~/.minimax-code` + the pre-rename `~/.mavis` (and their profiles), plus
/// the relocation variables MCODE_HOME / MINIMAX_DATA_DIR / MAVIS_DATA_DIR
/// (in that precedence) and the VIBE_USAGE_MCODE_DB fixture override.
///
/// Strict column allow-list: the token table also stores a `raw` JSON payload
/// (and the sessions table `record_json` / `extra_data_json`) containing
/// message bodies — those are never selected. Token rows and their project
/// metadata are read in one SQLite statement so separate reads cannot observe
/// different WAL snapshots while mcode is writing.
///
/// mcode's own migration can COPY a relocated legacy tree into ~/.minimax, so
/// both copies exist; rows that reappear byte-identical in a later store are
/// collapsed, while duplicates inside one store are kept — there they are the
/// ledger.
///
/// The JS `warnings` array has no VibeParseResult equivalent; broken non-
/// primary stores log via OSLog (Grok parser precedent) and never suppress the
/// live store, matching the JS contract.
struct VibeSyncMcodeParser: VibeLogParser {
    let source = "mcode"

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    private static let dbRelative = "v2/sqlite/runtime-state.sqlite"

    // Data-root variables the mcode CLI itself resolves, in its own
    // precedence. MCODE_HOME stays first as vibe-usage's pre-existing fixture
    // override, then the two public relocation variables from the mcode README.
    private static let rootEnvKeys = ["MCODE_HOME", "MINIMAX_DATA_DIR", "MAVIS_DATA_DIR"]

    private static let tokenColumns = [
        "session_id", "model", "ts", "input_tokens", "output_tokens",
        "reasoning_tokens", "cache_read_tokens", "cache_write_tokens",
    ]
    private static let sessionColumns = ["session_id", "workspace_dir", "project_workspace_dir"]

    private static let usageSQL = """
        SELECT
          token.session_id, token.model, token.ts, token.input_tokens, \
          token.output_tokens, token.reasoning_tokens, token.cache_read_tokens, \
          token.cache_write_tokens,
          session.workspace_dir,
          session.project_workspace_dir
        FROM local_runtime_token_usage AS token
        LEFT JOIN local_runtime_sessions AS session
          ON session.session_id = token.session_id
        """

    enum ResolutionError: Error, Equatable {
        case relativeRoot(key: String, value: String)
    }

    private let dbPaths: [String]
    private let resolutionError: ResolutionError?

    init(dbPaths: [String]? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        if let dbPaths {
            self.dbPaths = dbPaths
            self.resolutionError = nil
            return
        }
        do {
            self.dbPaths = try Self.resolveDbPaths(environment: environment, home: home)
            self.resolutionError = nil
        } catch let error as ResolutionError {
            self.dbPaths = []
            self.resolutionError = error
        } catch {
            self.dbPaths = []
            self.resolutionError = nil
        }
    }

    // MARK: - Path resolution (src/tools.js getMcodeDbPath / getMcodeDbPaths)

    /// Single-database resolution: VIBE_USAGE_MCODE_DB wins, then
    /// MCODE_HOME / MINIMAX_DATA_DIR / MAVIS_DATA_DIR (must be absolute),
    /// then ~/.minimax. Throws like the JS version on a relative root.
    static func resolveDbPath(environment: [String: String], home: String) throws -> String {
        let override = environment["VIBE_USAGE_MCODE_DB"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            if override.hasPrefix("/") { return override }
            return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(override)
        }
        let root = try rootFromEnv(environment: environment) ?? home + "/.minimax"
        return root + "/" + dbRelative
    }

    private static func rootFromEnv(environment: [String: String]) throws -> String? {
        for key in rootEnvKeys {
            let value = environment[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            if value.isEmpty { continue }
            guard value.hasPrefix("/") else {
                throw ResolutionError.relativeRoot(key: key, value: value)
            }
            return value
        }
        return nil
    }

    /// Every mcode runtime database worth parsing. Explicit roots keep
    /// returning their single unresolved path so a missing file still yields
    /// an empty result; the default layout only returns stores that exist,
    /// deduplicated by physical file so a compat symlink cannot make the same
    /// ledger count twice.
    static func resolveDbPaths(environment: [String: String], home: String) throws -> [String] {
        let override = environment["VIBE_USAGE_MCODE_DB"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty { return [try resolveDbPath(environment: environment, home: home)] }
        if let root = try rootFromEnv(environment: environment) { return [root + "/" + dbRelative] }

        var candidates = [home + "/.minimax", home + "/.minimax-code", home + "/.mavis"]
        let profilePattern = try! Regex("^\\.(?:minimax|mavis)-.+$")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home) {
            let profiles = entries
                .filter { name in
                    guard name.wholeMatch(of: profilePattern) != nil else { return false }
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(
                        atPath: home + "/" + name, isDirectory: &isDirectory) && isDirectory.boolValue
                }
                .sorted()
                .map { home + "/" + $0 }
            candidates.append(contentsOf: profiles)
        }

        let fileManager = FileManager.default
        var paths: [String] = []
        var seen = Set<String>()
        for directory in candidates {
            let dbPath = directory + "/" + dbRelative
            guard fileManager.fileExists(atPath: dbPath) else { continue }
            let identity = (dbPath as NSString).resolvingSymlinksInPath
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            paths.append(dbPath)
        }
        return paths
    }

    // MARK: - Row extraction

    private struct Record: Sendable {
        var identity: String
        var sessionId: String
        var model: String
        var project: String
        var timestamp: Date
        var inputTokens: Double
        var outputTokens: Double
        var cachedInputTokens: Double
        var reasoningOutputTokens: Double
    }

    /// mcode writes ts as integer milliseconds (confirmed against the live
    /// schema); anything < 1e12 is treated as seconds and scaled up.
    private static func tsToDate(_ value: VibeSQLiteValue) -> Date? {
        let number = value.jsNumber
        guard number.isFinite else { return nil }
        return Date(timeIntervalSince1970: (number < 1e12 ? number * 1000 : number) / 1000)
    }

    private static func extract(_ rows: [VibeSQLiteRow]) -> [Record] {
        rows.compactMap { row in
            let sessionId = row["session_id"].jsString ?? ""
            guard !sessionId.isEmpty, let timestamp = tsToDate(row["ts"]) else { return nil }

            // MCode stores output and reasoning as separate counters. Its own
            // summary code computes total = input + output + reasoning, so do
            // not subtract reasoning from output here.
            let inputTokens = VibeSQLite.toNonNegative(row["input_tokens"])
                + VibeSQLite.toNonNegative(row["cache_write_tokens"])
            let outputTokens = VibeSQLite.toNonNegative(row["output_tokens"])
            let reasoningOutputTokens = VibeSQLite.toNonNegative(row["reasoning_tokens"])
            let cachedInputTokens = VibeSQLite.toNonNegative(row["cache_read_tokens"])
            guard inputTokens + outputTokens + cachedInputTokens + reasoningOutputTokens > 0
            else { return nil }

            let projectPath = [row["project_workspace_dir"].jsString, row["workspace_dir"].jsString]
                .compactMap { $0 }.first { !$0.isEmpty }
            let project = projectPath.map { VibeSQLite.projectFromPath($0) } ?? "unknown"
            let model = row["model"].jsString?.trimmingCharacters(in: .whitespaces)
            return Record(
                identity: row.canonicalJSON,
                sessionId: sessionId,
                model: model?.isEmpty == false ? model! : "unknown",
                project: project,
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                reasoningOutputTokens: reasoningOutputTokens)
        }
    }

    // MARK: - Per-database parse cache (mtime/size fingerprinted)

    private struct CacheEntry: Sendable {
        let fingerprint: VibeSQLite.DatabaseFingerprint
        let records: [Record]
    }

    private static let cache = Mutex<[String: CacheEntry]>([:])

    private enum StoreError: Error { case incompatibleSchema }

    private func records(databasePath path: String) throws -> [Record] {
        let before = VibeSQLite.fingerprint(databasePath: path)
        if let cached = Self.cache.withLock({ $0[path] }), cached.fingerprint == before {
            return cached.records
        }
        // Schema guard: every allow-listed column must exist. If the mcode
        // runtime ever renames / drops a column, fail soft so the incremental
        // sync keeps the last good upload state for this source.
        let schemaOk = try VibeSQLite.hasColumns(
            databasePath: path, table: "local_runtime_token_usage",
            columns: Self.tokenColumns, tempPrefix: "vibe-usage-mcode")
            && VibeSQLite.hasColumns(
                databasePath: path, table: "local_runtime_sessions",
                columns: Self.sessionColumns, tempPrefix: "vibe-usage-mcode")
        guard schemaOk else { throw StoreError.incompatibleSchema }
        let rows = try VibeSQLite.querySnapshotOnLock(
            databasePath: path, sql: Self.usageSQL, tempPrefix: "vibe-usage-mcode")
        let records = Self.extract(rows)
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
        if let resolutionError { throw resolutionError }
        let fileManager = FileManager.default
        // The first store that exists is the one the running CLI would use;
        // schema or read failures there keep the fail-soft contract. Later
        // stores are best-effort extras and a broken one must not suppress
        // the live store.
        let primary = dbPaths.first { fileManager.fileExists(atPath: $0) }

        var result = VibeParseResult()
        var seenAcrossStores = Set<String>()

        for dbPath in dbPaths where fileManager.fileExists(atPath: dbPath) {
            let isPrimary = dbPath == primary
            let rows: [Record]
            do {
                rows = try records(databasePath: dbPath)
            } catch is StoreError {
                if isPrimary { return VibeParseResult(skipped: true) }
                Self.logger.warning("MiniMax Code: 跳过结构不兼容的数据库 \(dbPath, privacy: .public)")
                continue
            } catch {
                if isPrimary { return VibeParseResult(skipped: true) }
                Self.logger.warning(
                    "MiniMax Code: 无法读取 \(dbPath, privacy: .public)，已跳过: \(error.localizedDescription, privacy: .public)")
                continue
            }
            var identitiesInStore = Set<String>()
            for row in rows {
                // Identity covers every selected column; only a byte-identical
                // ledger row can collapse, and only against an earlier store.
                if seenAcrossStores.contains(row.identity) { continue }
                identitiesInStore.insert(row.identity)
                result.entries.append(VibeTokenEntry(
                    source: source,
                    model: row.model,
                    project: row.project,
                    timestamp: row.timestamp,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    cachedInputTokens: row.cachedInputTokens,
                    reasoningOutputTokens: row.reasoningOutputTokens))
            }
            seenAcrossStores.formUnion(identitiesInStore)
        }
        return result
    }
}
