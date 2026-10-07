import Foundation

// Legacy editor/CLI stores plus version-1 Cline SDK artifacts. Roo shares
// the legacy accounting format, but has a different discovery/history layout.
struct VibeSyncClineParser: VibeLogParser {
    let source: String
    let roots: [String]
    let sessionDirs: [String]
    init(roo: Bool = false, roots: [String]? = nil, sessionDirs: [String]? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        source = roo ? "roo-code" : "cline"
        let ext = roo ? "rooveterinaryinc.roo-cline" : "saoudrizwan.claude-dev"
        let editors = VibeParserSupport.hosts.map { home + "/Library/Application Support/" + $0 + "/User/globalStorage/" + ext }
        let override = environment["VIBE_USAGE_CLINE_DIRS"]?.split(separator: ":").map(String.init)
        let configured = environment["CLINE_DIR"] ?? home + "/.cline"
        let defaults = roo ? editors : override ?? [home + "/.cline", configured, environment["CLINE_DATA_DIR"] ?? configured + "/data"] + editors
        let expanded = roo ? defaults : defaults.flatMap { [$0, $0 + "/data"] }
        self.roots = Array(Set(roots ?? expanded)).sorted()
        self.sessionDirs = sessionDirs ?? (roo ? [] : Array(Set((roots ?? expanded).map { $0 + "/sessions" } + (override == nil ? [environment["CLINE_SESSION_DATA_DIR"]].compactMap { $0 } : []))).sorted())
    }
    func parse() throws -> VibeParseResult {
        typealias P = VibeParserSupport
        var result = VibeParseResult()
        var candidates: [String: (P.Object, String, Int, Date)] = [:]
        for root in roots {
            var history: [P.Object] = []
            if source == "cline" {
                let path = root + "/state/taskHistory.json"
                if P.exists(path) { history = P.objects(try P.json(path)) }
            } else {
                let index = P.object(try? P.json(root + "/tasks/_index.json"))
                if let entries = index["entries"] as? [P.Object] { history = entries }
                else {
                    for task in try P.children(root + "/tasks") where P.isDirectory(task) {
                        if let item = try? P.json(task + "/history_item.json") as? P.Object { history.append(item) }
                    }
                }
            }
            for item in history {
                let id = P.string(item["id"])
                guard !id.isEmpty, !id.contains("/"), id != ".." else { continue }
                let path = root + "/tasks/" + id + "/ui_messages.json"
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                let date = attrs[.modificationDate] as? Date ?? .distantPast
                let key = P.string(item["ulid"], id)
                if let old = candidates[key], old.2 > size || (old.2 == size && old.3 >= date) { continue }
                candidates[key] = (item, path, size, date)
            }
        }
        for key in candidates.keys.sorted() {
            let (item, path, _, _) = candidates[key]!
            guard let messages = try? P.json(path) as? [P.Object] else { result.skipped = true; continue }
            let id = P.string(item["id"]), project = P.project(source == "cline" ? item["cwdOnTaskInitialization"] ?? item["shadowGitConfigWorkTree"] ?? item["cwd"] : item["workspace"])
            let fallback = P.string(source == "cline" ? item["modelId"] : item["apiConfigName"], source == "cline" ? "cline-unknown" : "roo-unknown")
            for message in messages {
                guard let date = P.date(message["ts"]) else { continue }
                let type = P.string(message["type"]), say = P.string(message["say"])
                if type == "say" && say == "api_req_started" {
                    let info = P.jsonText(message["text"])
                    let input = P.count(info["tokensIn"]) + P.count(info["cacheWrites"])
                    let output = P.count(info["tokensOut"]), cache = P.count(info["cacheReads"])
                    guard input + output + cache > 0 else { continue }
                    result.entries.append(P.entry(source, P.string(info["model"], fallback), project, date, input, output, cache))
                    result.events.append(VibeSessionEvent(sessionId: id, source: source, project: project, timestamp: date, role: .assistant))
                } else if type == "ask" || (type == "say" && say == "user_feedback") {
                    result.events.append(VibeSessionEvent(sessionId: id, source: source, project: project, timestamp: date, role: .user))
                }
            }
        }
        if source == "roo-code" { return result }
        struct Record { var event: VibeSessionEvent; var entry: VibeTokenEntry?; var total: Double }
        var copies: [(Date, String, String, P.Object, P.Object)] = []
        var canonicalDirs = Set<String>()
        for dir in sessionDirs {
            guard canonicalDirs.insert(URL(fileURLWithPath: dir).resolvingSymlinksInPath().path).inserted else { continue }
            for child in try P.children(dir) where P.isDirectory(child) {
                let id = (child as NSString).lastPathComponent
                let files = try P.children(child).filter { $0.hasSuffix(".messages.json") }
                guard !files.isEmpty else { continue }
                guard let manifest = try? P.json(child + "/" + id + ".json") as? P.Object else { continue }
                guard manifest["version"] as? Int == 1, P.string(manifest["session_id"]) == id else { return VibeParseResult(skipped: true) }
                for file in files {
                    guard let payload = try? P.json(file) as? P.Object else { continue }
                    guard payload["version"] as? Int == 1, payload["messages"] is [Any],
                          let artifact = payload["sessionId"] as? String,
                          artifact == id || P.string(P.object(payload["origin"])["parentThreadId"]) == id else { return VibeParseResult(skipped: true) }
                    copies.append((P.date(manifest["started_at"]) ?? Date(timeIntervalSince1970: 0), id, file, manifest, payload))
                }
            }
        }
        copies.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        var records: [String: Record] = [:], order: [String] = []
        for (_, id, _, manifest, payload) in copies {
            let project = P.project(manifest["workspace_root"] ?? manifest["cwd"])
            for (index, message) in P.objects(payload["messages"]).enumerated() {
                guard let role = VibeSessionRole(rawValue: P.string(message["role"])), let ts = message["ts"] as? NSNumber, let date = P.date(ts) else { continue }
                let metadata = P.object(message["metadata"])
                if role == .user && (P.string(payload["agent"]) != "lead" || metadata["kind"] != nil || metadata["userRunSpan"] as? Int == 0 || ["system", "status", "error", "tool"].contains(P.string(metadata["displayRole"])) || P.objects(message["content"]).contains(where: { ["tool_result", "tool-result"].contains(P.string($0["type"])) })) { continue }
                let metric = role == .assistant ? P.object(message["metrics"]) : [:]
                let input = P.count(metric["inputTokens"]), cache = min(input, P.count(metric["cacheReadTokens"])), output = P.count(metric["outputTokens"])
                let total = input + output
                let identity = P.string(message["id"], P.string(payload["sessionId"]) + ":" + String(index))
                let key = VibeSQLite.jsJSONString(identity) + "|" + role.rawValue + "|" + String(ts.doubleValue)
                var record = Record(event: VibeSessionEvent(sessionId: id, source: source, project: project, timestamp: date, role: role), entry: total > 0 ? P.entry(source, P.string(P.object(message["modelInfo"])["id"], P.string(manifest["model"], "cline-unknown")), project, date, input - cache, output, cache) : nil, total: total)
                if let old = records[key] {
                    guard total > old.total else { continue }
                    record.event.sessionId = old.event.sessionId; record.event.project = old.event.project; record.entry?.project = old.event.project
                } else { order.append(key) }
                records[key] = record
            }
        }
        for key in order { if let r = records[key] { result.events.append(r.event); if let e = r.entry { result.entries.append(e) } } }
        return result
    }
}
