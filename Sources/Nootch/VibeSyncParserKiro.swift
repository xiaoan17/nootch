import Foundation

// Upstream precedence: native CLI stream → archived/SQLite CLI estimates →
// IDE credit deltas → explicitly enabled legacy telemetry. Never add these
// representations together. CLI token counts are estimates, as in upstream.
struct VibeSyncKiroParser: VibeLogParser {
    let source = "kiro"
    let environment: [String: String]
    let home: String
    init(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        self.environment = environment; self.home = home
    }
    typealias P = VibeParserSupport
    static let ignored = Set(["signature", "redactedContent", "toolUseId", "modelId", "message_id", "format", "id"])
    static func textChars(_ value: Any?) -> Int {
        if let s = value as? String { return s.utf16.count }
        if let a = value as? [Any] { return a.reduce(0) { $0 + textChars($1) } }
        if let o = value as? P.Object { return o.reduce(0) { $0 + (ignored.contains($1.key) ? 0 : textChars($1.value)) } }
        return 0
    }
    static func streamEntries(_ events: [P.Object], project: String, model: String?, fallback: Date, overhead: Double = 0) -> [VibeTokenEntry] {
        var result: [VibeTokenEntry] = [], timestamp: Date?, cumulative = 0.0, pending = 0.0
        var model = model ?? "kiro-token-estimate"
        for event in events {
            let data = P.object(event["data"]), content = P.objects(P.object(event["data"])["content"])
            switch P.string(event["kind"]) {
            case "Prompt":
                let seconds = P.count(P.object(data["meta"])["timestamp"])
                if seconds > 0 { timestamp = Date(timeIntervalSince1970: seconds) }
                for item in content { pending += P.string(item["kind"]) == "image" ? 1600 : Double(textChars(item["data"]) / 4) }
            case "ToolResults":
                for item in content { pending += Double(textChars(item["data"]) / 4) }
            case "AssistantMessage":
                var output = 0.0, reasoning = 0.0, signature = 0.0
                for item in content {
                    let d = P.object(item["data"])
                    if let m = d["modelId"] as? String, !m.isEmpty { model = m }
                    if P.string(item["kind"]) == "thinking" {
                        reasoning += Double(P.string(d["text"]).utf16.count / 4)
                        signature += Double(P.string(d["signature"]).utf16.count / 4)
                    } else { output += Double(textChars(item["data"]) / 4) }
                }
                if pending + output + reasoning > 0 { result.append(P.entry("kiro", model, project, timestamp ?? fallback, pending, output, cumulative + overhead, reasoning)) }
                cumulative += pending + output + reasoning + signature; pending = 0
            case "Compaction": cumulative = Double(textChars(data["summary"]) / 4); pending = 0
            default: break
            }
        }
        return result
    }
    struct Snapshot { var date: Date; var usage: Double; var reset: String }
    static func creditEntries(_ snapshots: [Snapshot]) -> [VibeTokenEntry] {
        let ordered = snapshots.sorted { $0.date < $1.date }
        var previous: Snapshot?, result: [VibeTokenEntry] = []
        for snapshot in ordered {
            defer { previous = snapshot }
            guard let old = previous, old.reset == snapshot.reset, snapshot.usage >= old.usage else { continue }
            let delta = floor(snapshot.usage) - floor(old.usage)
            if delta > 0 { result.append(P.entry("kiro", "kiro-credits", "unknown", snapshot.date, 0, delta)) }
        }
        return result
    }
    static func conversationEntries(_ conversations: [P.Object]) -> [VibeTokenEntry] {
        var byID: [String: P.Object] = [:], result: [VibeTokenEntry] = []
        for c in conversations {
            let id = P.string(c["conversation_id"])
            guard !id.isEmpty else { continue }
            if let old = byID[id], P.count(old["updated_at"]) > P.count(c["updated_at"]) { continue }
            byID[id] = c
        }
        func shallowChars(_ value: Any?) -> Int {
            if let s = value as? String { return s.utf16.count }
            return P.object(value).reduce(0) { $0 + ($1.key == "images" ? 0 : P.string($1.value).utf16.count) }
        }
        for id in byID.keys.sorted() {
            let conversation = byID[id]!, data = P.object(conversation["value"])
            var cumulative = Double(P.string(data["latest_summary"]).utf16.count / 4), previous = 0.0
            for (i, turn) in P.objects(data["history"]).enumerated() {
                let meta = P.object(turn["request_metadata"])
                guard P.count(meta["request_start_timestamp_ms"]) > 0, let date = P.date(meta["request_start_timestamp_ms"]) else { continue }
                var user = Double(shallowChars(turn["user"]) / 4)
                for image in P.objects(P.object(turn["user"])["images"]) {
                    let raw = P.object(image["source"])["Bytes"]
                    let bytes = (raw as? [UInt8]).map { Data($0) } ?? (raw as? String).flatMap { Data(base64Encoded: $0) }
                    if let bytes, bytes.count >= 24, Array(bytes.prefix(4)) == [0x89, 0x50, 0x4e, 0x47] {
                        let b = [UInt8](bytes)
                        func be(_ n: Int) -> Double { Double((0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(b[n + $1]) }) }
                        user += floor(be(16) * be(20) / 750)
                    } else { user += 1600 }
                }
                let assistant = Double(shallowChars(turn["assistant"]) / 4)
                let output = Double((meta["time_between_chunks"] as? [Any])?.count ?? 0), cache = i > 0 ? cumulative : 0, input = user + (i > 0 ? previous : 0)
                cumulative += user + assistant; previous = assistant
                if input + output + cache > 0 { result.append(P.entry("kiro", P.string(meta["model_id"], "kiro-token-estimate"), P.project(conversation["cwd"]), date, input, output, cache)) }
            }
        }
        return result
    }
    func parse() throws -> VibeParseResult {
        let streamDir = environment["KIRO_CLI_SESSIONS_DIR"] ?? home + "/.kiro/sessions/cli"
        var entries: [VibeTokenEntry] = []
        for file in try P.children(streamDir) where file.hasSuffix(".jsonl") {
            let meta = P.object(try? P.json(String(file.dropLast(6)) + ".json"))
            let model = P.object(P.object(P.object(meta["session_state"])["rts_model_state"])["model_info"])["model_id"] as? String
            let fallback = (try FileManager.default.attributesOfItem(atPath: file))[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
            entries += Self.streamEntries(try P.lines(file), project: P.project(meta["cwd"]), model: model, fallback: fallback, overhead: floor(P.count(environment["KIRO_CLI_SYSTEM_OVERHEAD_TOKENS"])))
        }
        if !entries.isEmpty { return VibeParseResult(entries: entries) }
        var conversations: [P.Object] = []
        for file in try P.children(environment["KIRO_SESSIONS_DIR"] ?? home + "/.kiro_sessions") where file.hasSuffix(".json") {
            if let c = try? P.json(file) as? P.Object { conversations.append(c) }
        }
        let db = environment["KIRO_CLI_DB_PATH"] ?? home + "/Library/Application Support/kiro-cli/data.sqlite3"
        if P.exists(db) {
            for (sql, modern) in [("SELECT conversation_id, key as cwd, created_at, updated_at, value FROM conversations_v2", true), ("SELECT key as cwd, value FROM conversations", false)] {
                let rows: [VibeSQLiteRow]
                do { rows = try VibeSQLite.querySnapshotOnLock(databasePath: db, sql: sql, tempPrefix: "nootch-kiro") }
                catch let error as VibeSQLiteError where error.message.contains("no such table") || error.message.contains("no such column") { continue }
                for row in rows {
                    let value = P.jsonText(row["value"].jsString), history = P.objects(P.jsonText(row["value"].jsString)["history"])
                    let updated = modern ? row["updated_at"].jsNumber : P.count(P.object(history.last?["request_metadata"])["request_start_timestamp_ms"])
                    conversations.append(["conversation_id": modern ? row["conversation_id"].jsString ?? "" : P.string(value["conversation_id"]), "cwd": row["cwd"].jsString ?? "unknown", "updated_at": updated, "value": value])
                }
            }
        }
        entries = Self.conversationEntries(conversations)
        if !entries.isEmpty { return VibeParseResult(entries: entries) }
        let app = home + "/Library/Application Support/Kiro"
        let base = environment["KIRO_BASE_PATH"] ?? app + "/User/globalStorage/kiro.kiroagent"
        let user = environment["KIRO_USER_PATH"] ?? (environment["KIRO_BASE_PATH"] != nil ? URL(fileURLWithPath: base).deletingLastPathComponent().deletingLastPathComponent().path : app + "/User")
        let logs = URL(fileURLWithPath: user).deletingLastPathComponent().path + "/logs"
        var snapshots: [Snapshot] = [], seen = Set<String>()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        for file in try P.files(logs, matching: { $0 == "q-client.log" || $0.hasPrefix("q-client.log.") }) {
            for line in try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n") {
                guard line.count > 24, let date = formatter.date(from: String(line.prefix(23))), let brace = line.firstIndex(of: "{") else { continue }
                let object = P.jsonText(String(line[brace...]))
                guard P.string(object["commandName"]) == "GetUsageLimitsCommand" else { continue }
                let output = P.object(object["output"])
                for breakdown in P.objects(output["usageBreakdownList"] ?? output["usageBreakdowns"]) {
                    guard P.string(breakdown["resourceType"] ?? breakdown["type"]).uppercased() == "CREDIT", P.string(breakdown["unit"]).uppercased() == "INVOCATIONS" else { continue }
                    let trial = P.object(breakdown["freeTrialInfo"]), free = P.object(breakdown["freeTrialUsage"])
                    let usage = [breakdown["currentUsageWithPrecision"], breakdown["currentUsage"], trial["currentUsageWithPrecision"], trial["currentUsage"], free["currentUsage"]].compactMap { $0 }.map(P.count).max()
                    guard let usage else { continue }
                    let reset = P.string(breakdown["nextDateReset"] ?? breakdown["resetDate"])
                    guard seen.insert("\(date.timeIntervalSince1970)|\(usage)|\(reset)").inserted else { continue }
                    snapshots.append(Snapshot(date: date, usage: usage, reset: reset))
                }
            }
        }
        entries = Self.creditEntries(snapshots)
        if !entries.isEmpty || environment["VIBE_USAGE_KIRO_LEGACY_TOKENS"] != "1" { return VibeParseResult(entries: entries) }
        let legacyDB = base + "/dev_data/devdata.sqlite", legacyJSON = base + "/dev_data/tokens_generated.jsonl"
        var rows: [P.Object] = []
        if P.exists(legacyDB) {
            rows = try VibeSQLite.querySnapshotOnLock(databasePath: legacyDB, sql: "SELECT model, tokens_prompt, tokens_generated, timestamp FROM tokens_generated WHERE tokens_prompt > 0 OR tokens_generated > 0 ORDER BY id", tempPrefix: "nootch-kiro").map { row in ["model": row["model"].jsString ?? "", "tokens_prompt": row["tokens_prompt"].jsNumber, "tokens_generated": row["tokens_generated"].jsNumber, "timestamp": row["timestamp"].jsString ?? ""] }
        } else if P.exists(legacyJSON) {
            let date = (try FileManager.default.attributesOfItem(atPath: legacyJSON))[.modificationDate] as? Date ?? .distantPast
            rows = try P.lines(legacyJSON).map { ["model": $0["model"] ?? "", "tokens_prompt": $0["promptTokens"] ?? 0, "tokens_generated": $0["generatedTokens"] ?? 0, "timestamp": VibeSyncTime.isoString(date)] }
        }
        for row in rows {
            var time = P.string(row["timestamp"]).replacingOccurrences(of: " ", with: "T")
            if !time.hasSuffix("Z") && time.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil { time += "Z" }
            guard let date = P.date(time) else { continue }
            var model = P.string(row["model"]).trimmingCharacters(in: .whitespaces)
            if model.isEmpty || model.lowercased() == "agent" { model = "kiro-token-estimate" }
            else { model = model.replacingOccurrences(of: #"_\d{8}_V\d+_\d+$|_V\d+$"#, with: "", options: [.regularExpression, .caseInsensitive]).lowercased().replacingOccurrences(of: "_", with: "-") }
            entries.append(P.entry(source, model, "unknown", date, P.count(row["tokens_prompt"]), P.count(row["tokens_generated"])))
        }
        return VibeParseResult(entries: entries)
    }
}
