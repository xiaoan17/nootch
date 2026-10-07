import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage test/workbuddy.test.js (upstream cb255fb + the
// current-store/function_call fixes of ebe797e). Fixtures copy the upstream
// shapes verbatim: usage lives in providerData.usage (mirrored into
// message.usage), rawUsage carries the OpenAI-shaped exclusive counts, and
// `conversationRequestId` is explicitly not a dedup key.
@Suite("VibeWorkBuddyParser")
struct VibeSyncWorkBuddyParserTests {
    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write <root>/projects/<folder>/<name>.
    @discardableResult
    private func writeTranscript(root: URL, folder: String, name: String, lines: [String]) throws -> URL {
        let url = root.appendingPathComponent("projects/\(folder)/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Completed assistant message; `usage`/`rawUsage` are raw JSON fragments
    /// so a test can shape the details arrays exactly like the store.
    private func assistantRecord(
        id: String, model: String, timestamp: String,
        usage: String?, rawUsage: String? = nil, status: String = "completed",
        sessionId: String? = nil, cwd: String = "/private/repo/actual-project"
    ) -> String {
        let usageJson = usage ?? "null"
        let sessionField = sessionId.map { ",\"sessionId\":\"\($0)\"" } ?? ""
        let rawField = rawUsage.map { ",\"rawUsage\":\($0)" } ?? ""
        return """
        {"id":"\(id)","timestamp":"\(timestamp)","type":"message","role":"assistant","status":"\(status)","cwd":"\(cwd)","content":[{"type":"text","text":"PRIVATE_WORKBUDDY_RESPONSE"}],"message":{"role":"assistant","usage":\(usageJson)},"providerData":{"requestModelId":"\(model)","usage":\(usageJson)\(rawField),"conversationRequestId":"not-the-request-dedup-key"}\(sessionField)}
        """
    }

    private func userRecord(
        id: String = "user-1", timestamp: String = "2026-08-10T00:50:00.000Z",
        sessionId: String? = nil, cwd: String = "/private/repo/actual-project"
    ) -> String {
        let sessionField = sessionId.map { ",\"sessionId\":\"\($0)\"" } ?? ""
        return """
        {"id":"\(id)","timestamp":"\(timestamp)","type":"message","role":"user","cwd":"\(cwd)","content":[{"type":"text","text":"PRIVATE_WORKBUDDY_PROMPT"}],"message":{"role":"user"}\(sessionField)}
        """
    }

    @Test("root resolution: ':'-delimited override normalizes to projects dirs, dual default roots")
    func rootResolution() {
        // Entries may name the home or its projects/ directory; both forms
        // normalize to the projects dir and duplicates collapse.
        #expect(VibeWorkBuddyParser.resolveProjectDirs(
            environment: ["VIBE_USAGE_WORKBUDDY_DIRS": "/tmp/workbuddy-a:/tmp/workbuddy-b"])
            == ["/tmp/workbuddy-a/projects", "/tmp/workbuddy-b/projects"])
        #expect(VibeWorkBuddyParser.resolveProjectDirs(
            environment: ["VIBE_USAGE_WORKBUDDY_DIRS": "/x/projects:/x"])
            == ["/x/projects"])
        // Current store alongside the legacy one (ebe797e).
        #expect(VibeWorkBuddyParser.resolveProjectDirs(environment: [:], home: "/home/me")
            == ["/home/me/.workbuddy-ai/projects", "/home/me/.workbuddy/projects"])
    }

    @Test("maps routed models, exclusive usage, deduplicated requests, and sessions")
    func normalParsing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let hy3Usage = """
        {"inputTokens":34824,"outputTokens":31,"inputTokensDetails":[{"cached_tokens":7488}],"outputTokensDetails":[{"reasoning_tokens":27}]}
        """
        let hy3Raw = """
        {"prompt_tokens":34824,"prompt_cache_hit_tokens":7488,"prompt_cache_miss_tokens":27336,"completion_tokens":31,"completion_thinking_tokens":27}
        """
        let hy3 = assistantRecord(
            id: "request-hy3", model: "hy3", timestamp: "2026-08-10T00:50:10.000Z",
            usage: hy3Usage, rawUsage: hy3Raw)
        let autoRouted = assistantRecord(
            id: "request-auto-routed", model: "model-routed-by-auto", timestamp: "2026-08-10T00:50:20.000Z",
            usage: #"{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":40}"#)
        let pending = assistantRecord(
            id: "request-pending", model: "must-not-count", timestamp: "2026-08-10T00:50:25.000Z",
            usage: #"{"inputTokens":100,"outputTokens":20}"#, status: "pending")

        try writeTranscript(root: root, folder: "encoded-project", name: "session-a.jsonl", lines: [
            userRecord(), hy3, autoRouted, pending, "{malformed",
        ])
        // A copied transcript of the same session: the hy3 record must dedupe
        // by id across files, not count twice.
        try writeTranscript(root: root, folder: "copied-project", name: "session-a.jsonl", lines: [hy3])

        let parser = VibeWorkBuddyParser(environment: ["VIBE_USAGE_WORKBUDDY_DIRS": root.path])
        let result = try parser.parse()
        #expect(!result.skipped)

        #expect(result.entries.count == 2)
        let byModel = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.model, $0) })
        let hy3Entry = try #require(byModel["hy3"])
        #expect(hy3Entry.source == "workbuddy")
        #expect(hy3Entry.project == "actual-project")  // from the record's cwd
        #expect(hy3Entry.timestamp == VibeSyncTime.parse("2026-08-10T00:50:10.000Z"))
        #expect(hy3Entry.inputTokens == 27336)  // rawUsage.prompt_cache_miss_tokens wins
        #expect(hy3Entry.outputTokens == 4)  // 31 − 27 reasoning
        #expect(hy3Entry.cachedInputTokens == 7488)
        #expect(hy3Entry.reasoningOutputTokens == 27)
        #expect(hy3Entry.cacheCreation5mTokens == 0)
        #expect(hy3Entry.cacheCreation1hTokens == 0)
        let autoEntry = try #require(byModel["model-routed-by-auto"])
        #expect(autoEntry.inputTokens == 60)  // 100 − 40 cache reads
        #expect(autoEntry.outputTokens == 20)
        #expect(autoEntry.cachedInputTokens == 40)
        #expect(autoEntry.reasoningOutputTokens == 0)

        // Upstream bucket assertions, via the shared aggregation.
        let buckets = VibeAggregation.aggregateToBuckets(result.entries, hostname: "test-host")
        #expect(buckets.count == 2)
        let bucketByModel = Dictionary(uniqueKeysWithValues: buckets.map { ($0.model, $0) })
        let hy3Bucket = try #require(bucketByModel["hy3"])
        #expect(hy3Bucket.project == "actual-project")
        #expect(hy3Bucket.bucketStart == "2026-08-10T00:30:00.000Z")
        #expect(hy3Bucket.totalTokens == 27367)
        #expect(bucketByModel["model-routed-by-auto"]?.totalTokens == 80)

        // Pending records emit no timing event; the copied transcript's events
        // dedupe onto the same keys. Turn = 00:50:10 → 00:50:20.
        let sessions = VibeAggregation.extractSessions(result.events)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.project == "actual-project")
        #expect(session.messageCount == 3)
        #expect(session.userMessageCount == 1)
        #expect(session.activeSeconds == 10)

        // Never retain or upload prompt/response text or absolute paths.
        let retained = String(describing: result)
        #expect(!retained.contains("PRIVATE_WORKBUDDY"))
        #expect(!retained.contains("/private/repo"))
    }

    @Test("parses function_call usage and raw token details")
    func functionCallUsage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Raw strings keep the JSON backslash escapes literal.
        let userJson = #"{"id":"user-function-call","sessionId":"real-session","timestamp":"2026-08-10T00:50:00.000Z","type":"message","role":"user","cwd":"C:\\private\\repo\\windows-project","content":[{"type":"text","text":"PRIVATE_WORKBUDDY_PROMPT"}],"message":{"role":"user"}}"#
        let functionCall = #"{"id":"request-function-call","sessionId":"real-session","timestamp":"2026-08-10T00:50:10.000Z","type":"function_call","cwd":"C:\\private\\repo\\windows-project","providerData":{"requestModelId":"gpt-routed","requestModelName":"Fast","model":"gpt-routed","usage":{"requests":1,"inputTokens":100,"outputTokens":20,"totalTokens":120,"inputTokensDetails":[{"cached_tokens":40}],"outputTokensDetails":[{"reasoning_tokens":5}]},"rawUsage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":40},"completion_tokens_details":{"reasoning_tokens":5}}}}"#
        try writeTranscript(root: root, folder: "encoded-project", name: "session.jsonl", lines: [
            userJson, functionCall,
        ])

        let result = try VibeWorkBuddyParser(environment: ["VIBE_USAGE_WORKBUDDY_DIRS": root.path]).parse()
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.model == "gpt-routed")  // providerData.requestModelId wins over requestModelName
        #expect(entry.project == "windows-project")  // Windows cwd, drive letter dropped
        #expect(entry.inputTokens == 60)
        #expect(entry.outputTokens == 15)
        #expect(entry.cachedInputTokens == 40)
        #expect(entry.reasoningOutputTokens == 5)
        #expect(VibeAggregation.aggregateToBuckets(result.entries, hostname: "h").first?.totalTokens == 80)

        let sessions = VibeAggregation.extractSessions(result.events)
        #expect(sessions.count == 1)
        #expect(sessions.first?.messageCount == 2)
        #expect(sessions.first?.userMessageCount == 1)
    }

    @Test("session dedup keeps same record ids in separate sessions")
    func sessionDedup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for (sessionId, minute) in [("session-a", "00"), ("session-b", "10")] {
            try writeTranscript(root: root, folder: "encoded-project", name: "\(sessionId).jsonl", lines: [
                userRecord(id: "shared-user-id", timestamp: "2026-08-10T01:\(minute):00.000Z", sessionId: sessionId),
                // Completed assistant with usage null: a timing event, no entry.
                assistantRecord(
                    id: "shared-assistant-id", model: "model",
                    timestamp: "2026-08-10T01:\(minute):10.000Z",
                    usage: nil, sessionId: sessionId),
            ])
        }

        let result = try VibeWorkBuddyParser(environment: ["VIBE_USAGE_WORKBUDDY_DIRS": root.path]).parse()
        #expect(result.entries.isEmpty)
        // Event dedup keys are session-scoped: identical record ids in two
        // sessions stay two sessions.
        let sessions = VibeAggregation.extractSessions(result.events)
        #expect(sessions.count == 2)
        #expect(sessions.map(\.messageCount) == [2, 2])
    }

    @Test("corrupt lines are skipped, surrounding rows still parse")
    func corruptLines() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root: root, folder: "encoded-project", name: "session.jsonl", lines: [
            "not json at all",
            "{\"type\":\"message\",\"timestamp\":",  // truncated mid-write
            assistantRecord(id: "ok", model: "hy3", timestamp: "2026-08-10T00:50:10.000Z",
                            usage: #"{"inputTokens":10,"outputTokens":2}"#),
            "[1,2,3]",
        ])
        let result = try VibeWorkBuddyParser(environment: ["VIBE_USAGE_WORKBUDDY_DIRS": root.path]).parse()
        #expect(!result.skipped)
        #expect(result.entries.count == 1)
    }

    @Test("an unreadable transcript flags skipped but keeps the parsed data (JS warning semantics)")
    func unreadableFileWarnsButKeepsData() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root: root, folder: "encoded-project", name: "a-good.jsonl", lines: [
            assistantRecord(id: "ok", model: "hy3", timestamp: "2026-08-10T00:50:10.000Z",
                            usage: #"{"inputTokens":10,"outputTokens":2}"#),
        ])
        let bad = try writeTranscript(root: root, folder: "encoded-project", name: "b-bad.jsonl", lines: [
            assistantRecord(id: "lost", model: "hy3", timestamp: "2026-08-10T00:50:10.000Z",
                            usage: #"{"inputTokens":10,"outputTokens":2}"#),
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bad.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad.path) }

        let result = try VibeWorkBuddyParser(environment: ["VIBE_USAGE_WORKBUDDY_DIRS": root.path]).parse()
        // JS: warn() sets skipped yet the parse result keeps its buckets.
        #expect(result.skipped)
        #expect(result.entries.count == 1)
    }

    @Test("without a projects dir the result is simply empty, not skipped")
    func missingProjectsDir() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try VibeWorkBuddyParser(environment: ["VIBE_USAGE_WORKBUDDY_DIRS": root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
        #expect(!result.skipped)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTranscript(root: root, folder: "encoded-project", name: "session.jsonl", lines: [
            userRecord(),
            assistantRecord(id: "request-hy3", model: "hy3", timestamp: "2026-08-10T00:50:10.000Z",
                            usage: #"{"inputTokens":100,"outputTokens":20,"inputTokensDetails":[{"cached_tokens":40}]}"#),
        ])
        let parser = VibeWorkBuddyParser(environment: ["VIBE_USAGE_WORKBUDDY_DIRS": root.path])
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
    }
}
