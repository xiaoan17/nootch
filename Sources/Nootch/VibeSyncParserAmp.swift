import Foundation

struct VibeSyncAmpParser: VibeLogParser {
    let source = "amp"
    let threadsDir: String
    init(threadsDir: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        self.threadsDir = threadsDir ?? environment["AMP_DATA_DIR"] ?? ((environment["XDG_DATA_HOME"] ?? home + "/.local/share") + "/amp/threads")
    }
    func parse() throws -> VibeParseResult {
        typealias P = VibeParserSupport
        var result = VibeParseResult()
        for path in try P.files(threadsDir, matching: { $0.hasPrefix("T-") && $0.hasSuffix(".json") }) {
            guard let thread = try? P.json(path) as? P.Object else { result.skipped = true; continue }
            let messages = P.objects(thread["messages"]), ledger = P.objects(P.object(thread["usageLedger"])["events"])
            let id = P.string(thread["id"], path)
            var times: [Int: Date] = [:]
            for event in ledger {
                guard let date = P.date(event["timestamp"]) else { continue }
                for key in ["fromMessageId", "toMessageId"] {
                    if let i = event[key] as? Int { times[i] = min(times[i] ?? date, date) }
                }
                let tokens = P.object(event["tokens"])
                let i = event["toMessageId"] as? Int ?? -1
                let usage = messages.indices.contains(i) ? P.object(messages[i]["usage"]) : [:]
                let input = P.count(tokens["input"]) + P.count(usage["cacheCreationInputTokens"])
                let output = P.count(tokens["output"]), cache = P.count(usage["cacheReadInputTokens"])
                if input + output + cache > 0 { result.entries.append(P.entry(source, P.string(event["model"], "unknown"), "unknown", date, input, output, cache)) }
            }
            if ledger.isEmpty {
                for message in messages {
                    let usage = P.object(message["usage"])
                    guard let date = P.date(message["timestamp"] ?? thread["created"]) else { continue }
                    let input = P.count(usage["inputTokens"]) + P.count(usage["cacheCreationInputTokens"])
                    let output = P.count(usage["outputTokens"]), cache = P.count(usage["cacheReadInputTokens"])
                    if input + output + cache > 0 { result.entries.append(P.entry(source, P.string(usage["model"], "unknown"), "unknown", date, input, output, cache)) }
                }
            }
            for (i, message) in messages.enumerated() {
                guard let date = times[i] ?? P.date(thread["created"]) else { continue }
                result.events.append(VibeSessionEvent(sessionId: id, source: source, project: "unknown", timestamp: date, role: P.string(message["role"]) == "user" ? .user : .assistant))
            }
        }
        return result
    }
}
