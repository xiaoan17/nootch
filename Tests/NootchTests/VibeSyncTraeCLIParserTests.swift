import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage test/trae-cli.test.js (upstream cebb532 + the
// malformed-timestamp handling of 417c631 and the unique-layer summing of
// 556b1c5). Fixtures copy the upstream shapes: usage lives in span tags, span
// startTime is microseconds, events carry an ISO created_at.
@Suite("VibeTraeCLIParser")
struct VibeSyncTraeCLIParserTests {
    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func makeSession(root: URL, id: String) throws -> URL {
        let url = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func usageSpan(
        _ category: String, input: Double, output: Double,
        cacheRead: Double = 0, reasoning: Double = 0,
        startTime: Double = 1_783_429_023_825_200, model: String? = "GLM-5.3"
    ) -> VibeTraeUsageSpan {
        VibeTraeUsageSpan(
            category: category, model: model, startTime: startTime,
            inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, reasoningTokens: reasoning)
    }

    @Test("root resolution: existing override wins, else ~/Library/Caches/trae-cli/sessions when present")
    func rootResolution() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(VibeTraeCLIParser.resolveCacheDirs(environment: ["VIBE_USAGE_TRAE_CLI_SESSIONS": root.path]) == [root.path])
        // A nonexistent override yields nothing (JS filters with existsSync).
        #expect(VibeTraeCLIParser.resolveCacheDirs(
            environment: ["VIBE_USAGE_TRAE_CLI_SESSIONS": root.path + "/missing"]) == [])
        #expect(VibeTraeCLIParser.resolveCacheDirs(environment: [:], home: root.path) == [])
        let caches = root.path + "/Library/Caches/trae-cli/sessions"
        try FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        #expect(VibeTraeCLIParser.resolveCacheDirs(environment: [:], home: root.path) == [caches])
    }

    @Test("parse reads Trae CLI session cache logs and aggregates tokens")
    func normalParsing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionUUID = "892e9718-b764-4dad-ab5c-ea2e3d2a5828"
        let session = try makeSession(root: root, id: sessionUUID)

        try write("""
        {"id":"\(sessionUUID)","created_at":"2026-07-07T20:57:03.162922+08:00","updated_at":"2026-07-07T21:58:38.438473+08:00","metadata":{"cwd":"/Users/park0er/coding/Foundations/AgentSetups","model_name":"GLM-5.2","permission_mode":"bypass_permissions","title":"扫码完成了"}}
        """, to: session.appendingPathComponent("session.json"))

        try write([
            #"{"traceID":"8ee89a9cbeb9641ebdbe9fe16e9129c9","spanID":"c24432205ceac7a5","operationName":"Doubao-Seed-2.1-Pro","startTime":1783429023825200,"tags":[{"key":"span.category","type":"string","value":"model.stream.eino"},{"key":"model.name","type":"string","value":"Doubao-Seed-2.1-Pro"},{"key":"usage.input_tokens","type":"int64","value":22503},{"key":"usage.output_tokens","type":"int64","value":641},{"key":"usage.total_tokens","type":"int64","value":23144},{"key":"usage.cache_read_tokens","type":"int64","value":5944},{"key":"usage.reasoning_tokens","type":"int64","value":578}]}"#,
            // Duplicate layer of the same call: must not double-count.
            #"{"traceID":"8ee89a9cbeb9641ebdbe9fe16e9129c9","spanID":"4d01c049e62044ef","operationName":"Doubao-Seed-2.1-Pro","startTime":1783429023825100,"tags":[{"key":"span.category","type":"string","value":"model.real_call"},{"key":"usage.input_tokens","type":"int64","value":22503},{"key":"usage.output_tokens","type":"int64","value":641},{"key":"usage.cache_read_tokens","type":"int64","value":5944},{"key":"usage.reasoning_tokens","type":"int64","value":0}]}"#,
            // 417c631: a malformed startTime is skipped, not fatal.
            #"{"traceID":"invalid-time","startTime":"not-a-timestamp","tags":[{"key":"usage.input_tokens","type":"int64","value":999}]}"#,
        ].joined(separator: "\n") + "\n", to: session.appendingPathComponent("traces.jsonl"))

        try write([
            #"{"id":"e0bcb513-39b4-4447-8e22-93c74144ce56","session_id":""# + sessionUUID + #"","created_at":"2026-07-07T20:57:03.2208+08:00","agent_start":{}}"#,
            #"{"id":"2752eeb1-d99f-4b0c-9bf4-35c59660d241","session_id":""# + sessionUUID + #"","created_at":"2026-07-07T20:57:03.521842+08:00","message":{"message":{"role":"assistant","content":"hello"}}}"#,
            // Malformed created_at: skipped.
            #"{"id":"invalid-time-event","session_id":""# + sessionUUID + #"","created_at":"not-a-timestamp","agent_start":{}}"#,
        ].joined(separator: "\n") + "\n", to: session.appendingPathComponent("events.jsonl"))

        let parser = VibeTraeCLIParser(environment: ["VIBE_USAGE_TRAE_CLI_SESSIONS": root.path])
        let result = try parser.parse()
        #expect(!result.skipped)

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "trae-cli")
        #expect(entry.model == "Doubao-Seed-2.1-Pro")  // span tag beats session fallback GLM-5.2
        #expect(entry.project == "AgentSetups")
        #expect(entry.timestamp == Date(timeIntervalSince1970: 1_783_429_023.8252))  // µs → s
        #expect(entry.inputTokens == 22503)
        #expect(entry.outputTokens == 641)
        #expect(entry.cachedInputTokens == 5944)
        #expect(entry.reasoningOutputTokens == 578)
        #expect(entry.cacheCreation5mTokens == 0)
        #expect(entry.cacheCreation1hTokens == 0)

        // Upstream bucket assertion: totalTokens excludes cache reads.
        let bucket = try #require(VibeAggregation.aggregateToBuckets(result.entries, hostname: "h").first)
        #expect(bucket.totalTokens == 22503 + 641 + 578)

        #expect(result.events.count == 2)
        #expect(result.events.allSatisfy {
            $0.sessionId == sessionUUID && $0.source == "trae-cli" && $0.project == "AgentSetups"
        })
        let sessions = VibeAggregation.extractSessions(result.events)
        #expect(sessions.count == 1)
        #expect(sessions.first?.source == "trae-cli")
        #expect(sessions.first?.project == "AgentSetups")
        #expect(sessions.first?.messageCount == 2)
        #expect(sessions.first?.userMessageCount == 1)
    }

    @Test("selectTraeUsageSpans keeps one layer per LLM call and sums sequential calls")
    func spanSelectionPrimary() {
        let u1 = (input: 100.0, output: 10.0, cacheRead: 50.0, reasoning: 5.0)
        let u2 = (input: 200.0, output: 20.0, cacheRead: 80.0, reasoning: 8.0)
        let selected = VibeTraeCLIParser.selectTraeUsageSpans([
            usageSpan("model.stream.eino", input: u1.input, output: u1.output, cacheRead: u1.cacheRead, reasoning: u1.reasoning),
            usageSpan("model.real_call", input: u1.input, output: u1.output, cacheRead: u1.cacheRead, reasoning: u1.reasoning),
            usageSpan("model.call", input: u1.input, output: u1.output, cacheRead: u1.cacheRead, reasoning: u1.reasoning),
            usageSpan("model.stream.eino", input: u2.input, output: u2.output, cacheRead: u2.cacheRead, reasoning: u2.reasoning, startTime: 1_783_429_023_900_000),
            usageSpan("model.real_call", input: u2.input, output: u2.output, cacheRead: u2.cacheRead, reasoning: u2.reasoning, startTime: 1_783_429_023_900_000),
            usageSpan("model.call", input: u2.input, output: u2.output, cacheRead: u2.cacheRead, reasoning: u2.reasoning, startTime: 1_783_429_023_900_000),
        ])
        #expect(selected.count == 2)
        #expect(selected.map(\.category) == ["model.stream.eino", "model.stream.eino"])
        #expect(selected.reduce(0) { $0 + $1.inputTokens } == 300)
    }

    @Test("selectTraeUsageSpans includes failover generate spans alongside stream.eino")
    func spanSelectionFailover() {
        let selected = VibeTraeCLIParser.selectTraeUsageSpans([
            usageSpan("model.stream.eino", input: 100, output: 10, reasoning: 4, startTime: 1, model: "GLM-5.3"),
            usageSpan("model.generate", input: 80, output: 70, startTime: 2, model: "Doubao-Seed-Evolving"),
        ])
        #expect(selected.count == 2)
        #expect(selected.compactMap(\.model).sorted() == ["Doubao-Seed-Evolving", "GLM-5.3"])
    }

    @Test("selectTraeUsageSpans falls back to model.real_call when stream.eino is absent")
    func spanSelectionFallback() {
        let selected = VibeTraeCLIParser.selectTraeUsageSpans([
            usageSpan("model.real_call", input: 40, output: 2),
            usageSpan("model.call", input: 40, output: 2),
        ])
        #expect(selected.count == 1)
        #expect(selected.first?.category == "model.real_call")
    }

    @Test("parse sums sequential LLM calls that share one session traceID")
    func sequentialCallsSum() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root, id: "same-trace")
        try write(#"{"id":"same-trace","metadata":{"cwd":"/tmp/demo","model_name":"GLM-5.3"}}"#,
                  to: session.appendingPathComponent("session.json"))

        func span(_ category: String, _ input: Int, _ output: Int, _ startTime: Int, _ reasoning: Int = 0) -> String {
            """
            {"traceID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","startTime":\(startTime),"tags":[{"key":"span.category","value":"\(category)"},{"key":"model.name","value":"GLM-5.3"},{"key":"usage.input_tokens","value":\(input)},{"key":"usage.output_tokens","value":\(output)},{"key":"usage.cache_read_tokens","value":0},{"key":"usage.reasoning_tokens","value":\(reasoning)}]}
            """
        }
        try write([
            span("model.stream.eino", 1000, 10, 1_787_345_117_880_722, 4),
            span("model.real_call", 1000, 10, 1_787_345_117_880_722),
            span("model.call", 1000, 10, 1_787_345_117_880_722),
            span("model.stream.eino", 2000, 20, 1_787_345_118_880_722, 6),
            span("model.real_call", 2000, 20, 1_787_345_118_880_722),
            span("model.call", 2000, 20, 1_787_345_118_880_722),
        ].joined(separator: "\n") + "\n", to: session.appendingPathComponent("traces.jsonl"))
        try write("", to: session.appendingPathComponent("events.jsonl"))

        let result = try VibeTraeCLIParser(environment: ["VIBE_USAGE_TRAE_CLI_SESSIONS": root.path]).parse()
        #expect(result.entries.count == 2)
        #expect(result.entries.allSatisfy { $0.model == "GLM-5.3" && $0.project == "demo" })
        let bucket = try #require(VibeAggregation.aggregateToBuckets(result.entries, hostname: "h").first)
        #expect(bucket.inputTokens == 3000)
        #expect(bucket.outputTokens == 30)
        #expect(bucket.reasoningOutputTokens == 10)
        #expect(bucket.model == "GLM-5.3")
    }

    @Test("a session dir without traces/events files simply contributes nothing")
    func missingFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession(root: root, id: "empty-session")
        let result = try VibeTraeCLIParser(environment: ["VIBE_USAGE_TRAE_CLI_SESSIONS": root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
        #expect(!result.skipped)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root, id: "cached")
        try write(#"{"id":"cached","metadata":{"cwd":"/tmp/demo","model_name":"GLM-5.3"}}"#,
                  to: session.appendingPathComponent("session.json"))
        try write(#"{"traceID":"t","startTime":1787345117880722,"tags":[{"key":"span.category","value":"model.stream.eino"},{"key":"usage.input_tokens","value":10},{"key":"usage.output_tokens","value":2}]}"# + "\n",
                  to: session.appendingPathComponent("traces.jsonl"))
        try write(#"{"created_at":"2026-07-07T20:57:03.2208+08:00","agent_start":{}}"# + "\n",
                  to: session.appendingPathComponent("events.jsonl"))
        let parser = VibeTraeCLIParser(environment: ["VIBE_USAGE_TRAE_CLI_SESSIONS": root.path])
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
        #expect(first.entries.count == 1)
        // No usage.* tags on the model → session fallback model applies.
        #expect(first.entries.first?.model == "GLM-5.3")
        #expect(first.events.count == 1)
        #expect(first.events.first?.role == .user)
    }
}
