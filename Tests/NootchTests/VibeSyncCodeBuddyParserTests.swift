import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage test/codebuddy.test.js (upstream feb7ec4 + the
// real-record fixes of 08c3129). The fixtures copy the verified real shapes:
// local turns are {type:"message", role, content, sessionId, cwd}; model calls
// are the API message shape carrying message.usage, with NO message.id and
// message.model null — identity and routed model live in providerData.
@Suite("VibeCodeBuddyParser")
struct VibeSyncCodeBuddyParserTests {
    private static let startMs = 1_789_663_563_095  // 2026-09-17T06:26:03.095Z
    private static let sessionId = "01a0ae1f-5636-772f-af89-4d1f303fff8f"

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write <root>/projects/<folder>/<sessionId>.jsonl.
    @discardableResult
    private func writeTranscript(root: URL, folder: String, sessionId: String, lines: [String]) throws -> URL {
        let url = root.appendingPathComponent("projects/\(folder)/\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func date(_ milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// Local user turn. `providerData` is a raw JSON fragment so a test can
    /// inject the CLI's meta markers (isMeta / skipRun / …).
    private func userRecord(
        id: String = "b7f0c1de-1111-4a11-8a11-000000000001",
        timestamp: Int = Self.startMs,
        sessionId: String = Self.sessionId,
        cwd: String? = "/work/demo-project",
        providerData: String = #"{"agent":"main"}"#
    ) -> String {
        """
        {"id":"\(id)","parentId":null,"timestamp":\(timestamp),"type":"message","role":"user","content":[{"type":"input_text","text":"DO NOT UPLOAD"}],"sessionId":"\(sessionId)","cwd":\(cwd.map { "\"\($0)\"" } ?? "null"),"providerData":\(providerData)}
        """
    }

    /// One billable model call (API message shape). Defaults mirror the real
    /// 2.151.0 store: no message.id, message.model null, identity and model in
    /// providerData; `cache_creation` (the TTL breakdown) is always null and
    /// switch-provider runs omit `cache_creation_input_tokens` entirely.
    private func assistantRecord(
        id: String? = "01a0ae23-f645-7ffe-8821-efceb64efe3c",
        timestamp: Int = Self.startMs + 2000,
        sessionId: String = Self.sessionId,
        cwd: String? = "/work/demo-project",
        messageId: String? = nil,
        messageModel: String? = nil,
        providerMessageId: String? = "01a0ae23f6457ffe8821efcda5e1f952",
        requestModelId: String? = "claude-sonnet-4-6",
        providerModel: String? = "claude-sonnet-4-6",
        input: Int = 100,
        output: Int = 47,
        cacheRead: Int = 1344,
        cacheCreation: Int? = 10
    ) -> String {
        func field(_ key: String, _ value: String?) -> String {
            value.map { ",\"\(key)\":\"\($0)\"" } ?? ""
        }
        let usage = """
        "input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation":null\
        \(cacheCreation.map { ",\"cache_creation_input_tokens\":\($0)" } ?? "")
        """
        let providerData = """
        {"agent":"cli","conversationRequestId":"01a0ae23f3467747a460570ef66d510f"\
        \(field("messageId", providerMessageId))\
        \(field("requestModelId", requestModelId))\
        \(field("model", providerModel))}
        """
        return """
        {"id":\(id.map { "\"\($0)\"" } ?? "null"),"timestamp":\(timestamp),"type":"assistant","sessionId":"\(sessionId)","cwd":\(cwd.map { "\"\($0)\"" } ?? "null"),"message":{"id":\(messageId.map { "\"\($0)\"" } ?? "null"),"model":\(messageModel.map { "\"\($0)\"" } ?? "null"),"role":"assistant","type":"message","stop_reason":"end_turn","usage":{\(usage)}},"providerData":\(providerData)}
        """
    }

    @Test("root resolution: fixture override splits on ':', CODEBUDDY_CONFIG_DIR and ~/.codebuddy defaults")
    func rootResolution() throws {
        #expect(VibeCodeBuddyParser.resolveRoots(environment: ["VIBE_USAGE_CODEBUDDY_DIRS": "/a:/b"]) == ["/a", "/b"])
        #expect(VibeCodeBuddyParser.resolveRoots(environment: ["VIBE_USAGE_CODEBUDDY_DIRS": "/x:/y"]) == ["/x", "/y"])
        #expect(VibeCodeBuddyParser.resolveRoots(environment: ["CODEBUDDY_CONFIG_DIR": "/custom/.codebuddy"]) == ["/custom/.codebuddy"])
        #expect(VibeCodeBuddyParser.resolveRoots(environment: [:], home: "/home/me") == ["/home/me/.codebuddy"])
        // The override replaces all discovery, including a configured home.
        #expect(VibeCodeBuddyParser.resolveRoots(
            environment: ["VIBE_USAGE_CODEBUDDY_DIRS": "/a", "CODEBUDDY_CONFIG_DIR": "/custom/.codebuddy"]) == ["/a"])
    }

    @Test("reads API-message usage, folds cache writes into input, keeps prompts human")
    func normalParsing() throws {
        let root = try makeRoot()
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            userRecord(),
            // Injected/tool-driven turns must not count as human prompts.
            userRecord(id: "meta-1", providerData: #"{"isMeta":true,"skipRun":true}"#),
            assistantRecord(),
        ])
        // Resolved through the environment override, like the upstream fixture.
        let parser = VibeCodeBuddyParser(environment: ["VIBE_USAGE_CODEBUDDY_DIRS": root.path])
        let result = try parser.parse()
        #expect(!result.skipped)
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "codebuddy")
        #expect(entry.model == "claude-sonnet-4-6")  // providerData.requestModelId: message.model is null
        #expect(entry.project == "demo-project")  // from the record's cwd
        #expect(entry.timestamp == date(Self.startMs + 2000))
        #expect(entry.inputTokens == 110)  // input_tokens + cache_creation_input_tokens
        #expect(entry.cachedInputTokens == 1344)
        #expect(entry.outputTokens == 47)
        #expect(entry.reasoningOutputTokens == 0)
        #expect(entry.cacheCreation5mTokens == 0)  // no TTL breakdown exists in this store
        #expect(entry.cacheCreation1hTokens == 0)

        #expect(result.events.count == 2)
        #expect(result.events.filter { $0.role == .user }.count == 1)
        #expect(result.events.filter { $0.role == .assistant }.count == 1)
        #expect(result.events.allSatisfy {
            $0.sessionId == Self.sessionId && $0.source == "codebuddy" && $0.project == "demo-project"
        })

        // Never retain or upload the transcript's text.
        let retained = result.entries.map { "\($0.model)\($0.project)" }
            + result.events.map { "\($0.sessionId)\($0.project)" }
        #expect(retained.allSatisfy { !$0.contains("DO NOT UPLOAD") })
    }

    @Test("a retried/copied call collapses onto its most complete payload")
    func dedupeKeepsFullestPayload() throws {
        let root = try makeRoot()
        // Same providerData.messageId = same logical call; the zeroed copy
        // must not win (JS keeps the highest usageScore per key).
        let zeroed = assistantRecord(id: "01a0ae23-f645-7ffe-8821-efceb64efe99",
                                     input: 0, output: 0, cacheRead: 0, cacheCreation: nil)
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            userRecord(), zeroed, assistantRecord(),
        ])
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1, "one logical call must produce one entry")
        #expect(result.entries.first?.inputTokens == 110, "the zeroed copy must not win")
    }

    @Test("routing tiers are namespaced so they cannot match another vendor price")
    func routingTierNamespacing() throws {
        let root = try makeRoot()
        // `auto` is priced as Cursor's auto server-side — a bare tier label
        // must never be billed at another product's rate (the Qoder #83 bug).
        let tiered = assistantRecord(id: "tier-1", providerMessageId: "tier-msg",
                                     requestModelId: "auto", providerModel: "Auto")
        let concrete = assistantRecord(id: "tier-2", providerMessageId: "concrete-msg",
                                       requestModelId: "claude-sonnet-4-6")
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            userRecord(), tiered, concrete,
        ])
        let models = try VibeCodeBuddyParser(roots: [root.path]).parse().entries.map(\.model).sorted()
        #expect(models == ["claude-sonnet-4-6", "codebuddy-auto"], "tier namespaced, real model untouched")
    }

    @Test("every distinct call counts, including records with no id at all")
    func idlessRecordsAreNotMerged() throws {
        let root = try makeRoot()
        // Regression (upstream 08c3129): the real record has no `message.id`,
        // so a dedup key built from it alone is empty and collapses the whole
        // session onto one call. A record with no identity anywhere must
        // still count as its own call.
        let anonymous = assistantRecord(id: nil, providerMessageId: nil)
        // Same providerData.messageId as the base record = same logical call.
        let copy = assistantRecord(id: "01a0ae23-f645-7ffe-8821-efceb64efe77")
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            userRecord(), assistantRecord(), anonymous, copy,
        ])
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(result.entries.count == 2, "two distinct calls plus one collapsed copy")
        #expect(result.entries.map(\.inputTokens).sorted() == [110, 110])
        #expect(result.entries.map(\.outputTokens).sorted() == [47, 47])
    }

    @Test("model falls back through providerData.requestModelId and providerData.model")
    func modelFallbackChain() throws {
        let root = try makeRoot()
        // message.model wins when present (e.g. an Anthropic-shaped writer).
        let direct = assistantRecord(id: "m-1", messageId: nil, messageModel: "claude-opus-4-1",
                                     providerMessageId: "msg-1")
        // message.model null, requestModelId missing → providerData.model.
        let routed = assistantRecord(id: "m-2", providerMessageId: "msg-2",
                                     requestModelId: nil, providerModel: "deepseek-v3.2")
        // Nothing anywhere → "unknown".
        let unknown = assistantRecord(id: "m-3", providerMessageId: "msg-3",
                                      requestModelId: nil, providerModel: nil)
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            direct, routed, unknown,
        ])
        let models = try VibeCodeBuddyParser(roots: [root.path]).parse().entries.map(\.model).sorted()
        #expect(models == ["claude-opus-4-1", "deepseek-v3.2", "unknown"])
    }

    @Test("project falls back to the compressed folder name when a record has no cwd")
    func projectFallbackFromFolder() throws {
        let root = try makeRoot()
        try writeTranscript(root: root, folder: "private-tmp-cb-probe", sessionId: "session-2", lines: [
            userRecord(timestamp: Self.startMs, cwd: nil),
            assistantRecord(timestamp: Self.startMs + 4000, cwd: nil,
                            providerMessageId: "msg_other"),
        ])
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.project == "probe")
        // Usage entries use the folder fallback; user events follow the JS
        // quirk `projectFromCwd(cwd) || fallback` where 'unknown' is truthy.
        #expect(result.events.first { $0.role == .assistant }?.project == "probe")
        #expect(result.events.first { $0.role == .user }?.project == "unknown")
    }

    @Test("a numeric timestamp of zero falls back to the message ISO timestamp")
    func timestampFallback() throws {
        let root = try makeRoot()
        // JS: Number(obj.timestamp) || Date.parse(obj.message?.timestamp).
        let line = """
        {"id":"z-1","timestamp":0,"type":"assistant","sessionId":"session-1","cwd":"/work/demo-project","message":{"timestamp":"2026-09-17T06:26:05.000Z","role":"assistant","usage":{"input_tokens":10,"output_tokens":2}},"providerData":{"messageId":"z-msg","requestModelId":"claude-sonnet-4-6"}}
        """
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [line])
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.timestamp == VibeSyncTime.parse("2026-09-17T06:26:05.000Z"))
        // readTimestamp(0) is finite, so the assistant event lands at the epoch.
        #expect(result.events.first?.timestamp == Date(timeIntervalSince1970: 0))
    }

    @Test("missing cache_creation_input_tokens (switch-provider runs) reads as zero")
    func missingCacheCreationField() throws {
        let root = try makeRoot()
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            assistantRecord(cacheCreation: nil),
        ])
        let entry = try #require(try VibeCodeBuddyParser(roots: [root.path]).parse().entries.first)
        #expect(entry.inputTokens == 100)
    }

    @Test("a session id on the record beats the file name; keyless records use the file name")
    func sessionIdResolution() throws {
        let root = try makeRoot()
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "file-name-session", lines: [
            assistantRecord(id: "s-1", providerMessageId: "msg-1"),  // carries Self.sessionId
            assistantRecord(id: "s-2", sessionId: "", providerMessageId: "msg-2"),
        ])
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(Set(result.events.map(\.sessionId)) == [Self.sessionId, "file-name-session"])
    }

    @Test("corrupt lines are skipped, surrounding rows still parse")
    func corruptLines() throws {
        let root = try makeRoot()
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            "not json at all",
            "{\"type\":\"assistant\",\"timestamp\":",  // truncated mid-write
            assistantRecord(),
            "[1,2,3]",
        ])
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.count == 1)
        #expect(!result.skipped)
    }

    @Test("without a projects dir the result is simply empty, not skipped")
    func missingProjectsDir() throws {
        let root = try makeRoot()
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
        #expect(!result.skipped)
    }

    @Test("an unreadable transcript skips the whole source with empty output")
    func unreadableFileSkipsSource() throws {
        let root = try makeRoot()
        let file = try writeTranscript(root: root, folder: "private-work-demo-project",
                                       sessionId: "session-1", lines: [assistantRecord()])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let result = try VibeCodeBuddyParser(roots: [root.path]).parse()
        #expect(result.skipped)
        // JS returns `{buckets: [], sessions: [], skipped: true}`.
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        try writeTranscript(root: root, folder: "private-work-demo-project", sessionId: "session-1", lines: [
            userRecord(),
            assistantRecord(),
        ])
        let parser = VibeCodeBuddyParser(roots: [root.path])
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
    }
}
