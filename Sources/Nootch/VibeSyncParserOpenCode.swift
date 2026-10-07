import Foundation
import OSLog
import Synchronization

/// OpenCode parser — Swift port of vibe-usage `src/parsers/opencode.js`
/// (initial import 2d53016, latest fix f1dd166) + `src/opencode-roots.js`.
///
/// Dual format: SQLite opencode.db (1.x `message` table / 2.x
/// `session_message` event-sourced projection) wins within each store; the
/// JSON `storage/message/` tree is the legacy alternative, not a second copy
/// of the same migrated history. Default root is `~/.local/share/opencode`;
/// VIBE_USAGE_OPENCODE_DIRS (PATH-delimited) overrides.
///
/// OpenCode 2.x: the row's `type` is the role, `data.model.id` the model,
/// `data.tokens` the counters. Message rows carry no `path`, so the project
/// comes from the session row's `directory`; the session table is
/// `session_v2` in 2.x and `session` before that (both names in the wild,
/// upstream issue #114). Only column/JSON accounting expressions are selected
/// — never message text, tool payloads, or costs.
///
/// Cache-write pricing (f1dd166): the store writes one cache-write total with
/// no per-TTL breakdown and no separate `tokens.total` to reconcile against,
/// so it goes to the cheaper 5m cache-creation bucket — the same rule as
/// CodeArts Agent, which reads this exact layout.
///
/// The JS `warnings` array has no VibeParseResult equivalent; store read
/// failures log via OSLog (Grok parser precedent) and still suppress the whole
/// source (skipped = true) so a partial read cannot look like deletion.
struct VibeSyncOpenCodeParser: VibeLogParser {
    let source = "opencode"

    private static let logger = Logger(subsystem: "nootch", category: "VibeSync")

    // Select only accounting/timing metadata, never message text or tool
    // inputs. Keep the existing top-level model/project precedence for old
    // uploads.
    private static let v1Query = """
        SELECT id, session_id AS sessionID,
            json_extract(data, '$.role') AS role,
            json_extract(data, '$.time.created') AS created,
            coalesce(json_extract(data, '$.modelID'), json_extract(data, '$.model.modelID')) AS modelID,
            json_extract(data, '$.tokens') AS tokens,
            json_extract(data, '$.path.root') AS rootPath
            FROM message ORDER BY id
        """

    private static func v2Query(sessionTable: String?) -> String {
        """
        SELECT m.id AS id, m.session_id AS sessionID,
            m.type AS role,
            coalesce(json_extract(m.data, '$.time.created'), m.time_created) AS created,
            coalesce(json_extract(m.data, '$.model.id'), json_extract(m.data, '$.modelID')) AS modelID,
            json_extract(m.data, '$.tokens') AS tokens,
            s.directory AS directory
            FROM session_message m
            \(sessionTable.map { "LEFT JOIN \($0) s ON s.id = m.session_id" } ?? "")
            WHERE m.type IN ('user', 'assistant')
            ORDER BY m.id
        """
    }

    private enum Store: Equatable {
        case sqlite(String)
        case json(String)

        var path: String {
            switch self {
            case .sqlite(let path), .json(let path): return path
            }
        }
    }

    private let roots: [String]
    private let extraRoots: [String]

    init(roots: [String]? = nil,
         extraRoots: [String] = [],
         environment: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory()) {
        if let roots {
            self.roots = roots
        } else {
            let override = environment["VIBE_USAGE_OPENCODE_DIRS"]?
                .trimmingCharacters(in: .whitespaces) ?? ""
            self.roots = override.isEmpty
                ? [home + "/.local/share/opencode"]
                : override.split(separator: ":")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
        }
        self.extraRoots = extraRoots
    }

    // MARK: - Store discovery (src/opencode-roots.js)

    /// stat + access check. Missing paths read as absent; other stat errors
    /// surface as warnings (JS `readable`).
    private static func readable(_ path: String, directory: Bool) throws -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw VibeSQLiteError(message: String(cString: strerror(errno)))
        }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        guard isDirectory == directory else {
            throw VibeSQLiteError(message: "格式不正确: \(path)")
        }
        return access(path, R_OK) == 0
    }

    /// SQLite wins within each store; JSON is the legacy alternative. A failed
    /// SQLite read must protect state.
    private static func openCodeStore(_ root: String) throws -> Store? {
        if try readable(root + "/opencode.db", directory: false) { return .sqlite(root + "/opencode.db") }
        if try readable(root + "/storage/message", directory: true) { return .json(root + "/storage/message") }
        return nil
    }

    private static func findStores(roots: [String], extraRoots: [String]) -> (stores: [Store], warnings: [String]) {
        var seen = Set<String>()
        var stores: [Store] = []
        var warnings: [String] = []
        for root in roots + extraRoots {
            do {
                guard let store = try openCodeStore(root) else {
                    if extraRoots.contains(root) {
                        warnings.append("OpenCode: 额外目录缺少 opencode.db 或 storage/message/: \(root)")
                    }
                    continue
                }
                let canonical = (store.path as NSString).resolvingSymlinksInPath
                let canonicalStore: Store
                switch store {
                case .sqlite: canonicalStore = .sqlite(canonical)
                case .json: canonicalStore = .json(canonical)
                }
                guard !seen.contains(canonical) else { continue }
                seen.insert(canonical)
                stores.append(canonicalStore)
            } catch {
                warnings.append("OpenCode: 无法读取数据目录 \(root): \(error.localizedDescription)")
            }
        }
        return (stores, warnings)
    }

    // MARK: - Row extraction

    /// Normalized message row from either backend. `tokens` keeps the raw JSON
    /// object so tokenSize / entry mapping can apply JS Number() coercion.
    /// @unchecked: the JSON payloads only ever contain NSString/NSNumber values.
    private struct Record: @unchecked Sendable {
        var id: String
        var sessionId: String
        var role: String?
        var timestamp: Date
        var modelID: String?
        var tokens: [String: Any]?
        var rootPath: String?
        var directory: String?
        var fallbackKey: String

        /// JS tokenSize: input+output+reasoning+cache.read (cache.write is
        /// deliberately not part of the "most complete copy" score).
        var tokenSize: Double {
            guard let tokens else { return 0 }
            let cache = tokens["cache"] as? [String: Any]
            return Self.number(tokens["input"]) + Self.number(tokens["output"])
                + Self.number(tokens["reasoning"]) + Self.number(cache?["read"])
        }

        /// JS `Number(value) || 0` over JSONSerialization values.
        static func number(_ value: Any?) -> Double {
            switch value {
            case let number as NSNumber:
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return 0 }
                return number.doubleValue
            case let string as String:
                return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            default:
                return 0
            }
        }
    }

    /// JS `new Date(row.created)`: numbers are milliseconds (no seconds
    /// sniffing here), strings parse as ISO-8601.
    private static func createdDate(_ value: VibeSQLiteValue) -> Date? {
        switch value {
        case .integer(let number):
            return Date(timeIntervalSince1970: Double(number) / 1000)
        case .double(let number):
            guard number.isFinite else { return nil }
            return Date(timeIntervalSince1970: number / 1000)
        case .text(let string):
            return VibeSyncTime.parse(string)
        case .null:
            return nil
        }
    }

    private static func jsonObject(_ value: VibeSQLiteValue) -> [String: Any]? {
        guard case .text(let text) = value,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object
    }

    private static func extractSqlite(_ rows: [VibeSQLiteRow], storePath: String) -> [Record] {
        rows.enumerated().compactMap { index, row in
            guard let timestamp = createdDate(row["created"]) else { return nil }
            let id = row["id"].jsString ?? ""
            let sessionId = row["sessionID"].jsString ?? "unknown"
            return Record(
                id: id,
                sessionId: sessionId.isEmpty ? "unknown" : sessionId,
                role: row["role"].jsString,
                timestamp: timestamp,
                modelID: row["modelID"].jsString,
                tokens: jsonObject(row["tokens"]),
                rootPath: row["rootPath"].jsString,
                directory: row["directory"].jsString,
                fallbackKey: "\(storePath):\(index)")
        }
    }

    private static func readSqlite(_ path: String) throws -> [Record] {
        let tables = Set(try VibeSQLite.query(
            databasePath: path,
            sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                 AND name IN ('message', 'session_message', 'session', 'session_v2')
                """).compactMap { $0["name"].jsString })
        guard tables.contains("message") || tables.contains("session_message") else {
            throw VibeSQLiteError(message: "不认识的表结构（没有 message / session_message 表）: \(path)")
        }
        // Read both shapes when a migrated store keeps both: copies are merged
        // by (session, message id), and the legacy row is seen first so an
        // equal copy never renames a project that earlier uploads already used.
        var rows: [VibeSQLiteRow] = []
        if tables.contains("message") {
            rows.append(contentsOf: try VibeSQLite.query(databasePath: path, sql: v1Query))
        }
        if tables.contains("session_message") {
            let sessionTable = tables.contains("session_v2") ? "session_v2"
                : (tables.contains("session") ? "session" : nil)
            rows.append(contentsOf: try VibeSQLite.query(databasePath: path, sql: v2Query(sessionTable: sessionTable)))
        }
        return extractSqlite(rows, storePath: path)
    }

    private static func readJson(_ path: String) throws -> [Record] {
        let fileManager = FileManager.default
        var records: [Record] = []
        for sessionDir in try fileManager.contentsOfDirectory(atPath: path) {
            guard sessionDir.hasPrefix("ses_") else { continue }
            let sessionPath = path + "/" + sessionDir
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sessionPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let files = try fileManager.contentsOfDirectory(atPath: sessionPath).sorted()
            for file in files where file.hasSuffix(".json") {
                let filePath = sessionPath + "/" + file
                let data = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: URL(fileURLWithPath: filePath)))
                guard let object = data as? [String: Any] else { continue }
                let created = (object["time"] as? [String: Any])?["created"]
                guard let timestamp = jsonCreatedDate(created) else { continue }
                let declaredId = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                records.append(Record(
                    id: declaredId ?? (file as NSString).deletingPathExtension,
                    sessionId: sessionDir,
                    role: object["role"] as? String,
                    timestamp: timestamp,
                    modelID: (object["modelID"] as? String) ?? (object["model"] as? [String: Any])?["modelID"] as? String,
                    tokens: object["tokens"] as? [String: Any],
                    rootPath: (object["path"] as? [String: Any])?["root"] as? String,
                    directory: nil,
                    fallbackKey: "\(path):\(records.count)"))
            }
        }
        return records
    }

    private static func jsonCreatedDate(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        case let string as String:
            return VibeSyncTime.parse(string)
        default:
            return nil
        }
    }

    // MARK: - Per-store parse cache

    private struct JsonFingerprint: Equatable, Sendable {
        var files: [String: VibeSQLite.FileStamp]
    }

    private enum Fingerprint: Equatable, Sendable {
        case sqlite(VibeSQLite.DatabaseFingerprint)
        case json(JsonFingerprint)
    }

    private struct CacheEntry: Sendable {
        let fingerprint: Fingerprint
        let records: [Record]
    }

    private static let cache = Mutex<[String: CacheEntry]>([:])

    private static func fingerprint(_ store: Store) -> Fingerprint {
        switch store {
        case .sqlite(let path):
            return .sqlite(VibeSQLite.fingerprint(databasePath: path))
        case .json(let path):
            var files: [String: VibeSQLite.FileStamp] = [:]
            let fileManager = FileManager.default
            if let enumerator = fileManager.enumerator(atPath: path) {
                for case let file as String in enumerator {
                    if let stamp = VibeSQLite.stamp(path + "/" + file) { files[file] = stamp }
                }
            }
            return .json(JsonFingerprint(files: files))
        }
    }

    private func cachedRecords(_ store: Store) throws -> [Record] {
        let before = Self.fingerprint(store)
        if let cached = Self.cache.withLock({ $0[store.path] }), cached.fingerprint == before {
            return cached.records
        }
        let records: [Record]
        switch store {
        case .sqlite(let path): records = try Self.readSqlite(path)
        case .json(let path): records = try Self.readJson(path)
        }
        if Self.fingerprint(store) == before {
            Self.cache.withLock { cache in
                if cache.count >= 64, cache[store.path] == nil, let oldest = cache.keys.first {
                    cache.removeValue(forKey: oldest)
                }
                cache[store.path] = CacheEntry(fingerprint: before, records: records)
            }
        }
        return records
    }

    // MARK: - parse()

    func parse() throws -> VibeParseResult {
        let discovery = Self.findStores(roots: roots, extraRoots: extraRoots)
        var warningCount = discovery.warnings.count
        for warning in discovery.warnings { Self.logger.warning("\(warning, privacy: .public)") }

        // Message ids are unique within an OpenCode session. Across stores,
        // keep the most complete copy; never dedup unrelated equal-sized
        // calls. Missing ids cannot prove that two stores hold the same
        // record.
        var records: [String: Record] = [:]
        var order: [String] = []
        for store in discovery.stores {
            let rows: [Record]
            do {
                rows = try cachedRecords(store)
            } catch {
                warningCount += 1
                Self.logger.warning(
                    "OpenCode: 无法读取 \(store.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            for row in rows {
                let key = "\(row.sessionId)\u{0}\(row.id.isEmpty ? row.fallbackKey : row.id)"
                if let previous = records[key] {
                    if row.tokenSize > previous.tokenSize { records[key] = row }
                } else {
                    records[key] = row
                    order.append(key)
                }
            }
        }
        if warningCount > 0 { return VibeParseResult(skipped: true) }

        var result = VibeParseResult()
        for key in order {
            guard let row = records[key] else { continue }
            // V2 message rows carry no `path`, so they fall back to the
            // session directory; they come from a store the parser could not
            // read before, so nothing previously uploaded is relabelled by
            // that fallback. V1 rows with only path.cwd stay "unknown" (the
            // legacy precedence is preserved).
            let project = row.rootPath?.isEmpty == false ? VibeSQLite.projectFromPath(row.rootPath)
                : (row.directory?.isEmpty == false ? VibeSQLite.projectFromPath(row.directory) : "unknown")
            result.events.append(VibeSessionEvent(
                sessionId: row.sessionId, source: source, project: project,
                timestamp: row.timestamp, role: row.role == "user" ? .user : .assistant))

            guard let model = row.modelID, !model.isEmpty, let tokens = row.tokens else { continue }
            let inputTokens = Record.number(tokens["input"])
            let outputTokens = Record.number(tokens["output"])
            guard inputTokens != 0 || outputTokens != 0 else { continue }
            let cache = tokens["cache"] as? [String: Any]
            result.entries.append(VibeTokenEntry(
                source: source,
                model: model,
                project: project,
                timestamp: row.timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: Record.number(cache?["read"]),
                reasoningOutputTokens: Record.number(tokens["reasoning"]),
                cacheCreation5mTokens: Record.number(cache?["write"])))
        }
        return result
    }
}
