import Foundation
import Testing
@testable import Nootch

@Suite("VibeClaudeCodeParser")
struct VibeSyncClaudeCodeParserTests {
    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write <root>/<subdir>/<sessionId>.jsonl (nested project dirs allowed
    /// via "/" in sessionId, e.g. "-Users-x-alpha/sid").
    @discardableResult
    private func writeJsonl(root: URL, subdir: String, path: String, lines: [String]) throws -> URL {
        let url = root.appendingPathComponent(subdir).appendingPathComponent(path + ".jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func userLine(_ timestamp: String, cwd: String? = "/Users/x/alpha", uuid: String = UUID().uuidString) -> String {
        """
        {"type":"user","timestamp":"\(timestamp)","cwd":\(cwd.map { "\"\($0)\"" } ?? "null"),"sessionId":"sid","uuid":"\(uuid)"}
        """
    }

    private func assistantLine(
        _ timestamp: String,
        id: String? = nil,
        requestId: String? = nil,
        model: String? = "claude-opus-4-1",
        input: Int = 100,
        output: Int = 50,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        cacheCreationBreakdown: (fiveMin: Int, oneHour: Int)? = nil,
        cwd: String? = "/Users/x/alpha",
        uuid: String = UUID().uuidString) -> String
    {
        var usage = "\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":\(cacheCreation),\"cache_read_input_tokens\":\(cacheRead)"
        if let breakdown = cacheCreationBreakdown {
            usage += ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(breakdown.fiveMin),\"ephemeral_1h_input_tokens\":\(breakdown.oneHour)}"
        }
        return """
        {"type":"assistant","timestamp":"\(timestamp)","cwd":\(cwd.map { "\"\($0)\"" } ?? "null"),"sessionId":"sid","uuid":"\(uuid)","requestId":\(requestId.map { "\"\($0)\"" } ?? "null"),"message":{"id":\(id.map { "\"\($0)\"" } ?? "null"),"model":\(model.map { "\"\($0)\"" } ?? "null"),"role":"assistant","usage":{\(usage)}}}
        """
    }

    private func date(_ string: String) -> Date {
        VibeSyncTime.parse(string) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("token fields map and project/model come from the session")
    func normalParsing() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            userLine("2026-09-01T10:00:00.000Z"),
            assistantLine("2026-09-01T10:00:05.000Z", id: "msg_1", requestId: "req_1",
                          input: 100, output: 50, cacheCreation: 20, cacheRead: 30),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(!result.skipped)
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "claude-code")
        #expect(entry.model == "claude-opus-4-1")
        #expect(entry.project == "alpha")
        #expect(entry.timestamp == date("2026-09-01T10:00:05.000Z"))
        #expect(entry.inputTokens == 120)  // input_tokens + cache_creation
        #expect(entry.outputTokens == 50)
        #expect(entry.cachedInputTokens == 30)
        #expect(entry.reasoningOutputTokens == 0)
        #expect(result.events.count == 2)
        #expect(result.events[0].role == .user)
        #expect(result.events[1].role == .assistant)
        #expect(result.events.allSatisfy { $0.sessionId == "sid" && $0.source == "claude-code" })
    }

    @Test("per-block repeats and streaming partials of one call dedupe to the fullest payload")
    func dedupeByCallIdentity() throws {
        let root = try makeRoot()
        // Same message.id/requestId: streaming partial (output 10) then final (output 50),
        // plus a block repeat with identical usage.
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:05.000Z", id: "msg_1", requestId: "req_1", output: 10),
            assistantLine("2026-09-01T10:00:06.000Z", id: "msg_1", requestId: "req_1", output: 50),
            assistantLine("2026-09-01T10:00:06.500Z", id: "msg_1", requestId: "req_1", output: 50),
            assistantLine("2026-09-01T10:00:10.000Z", id: "msg_2", requestId: "req_2", output: 7),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.count == 2)
        let firstCall = result.entries.filter { $0.timestamp == date("2026-09-01T10:00:06.000Z") }
        #expect(firstCall.count == 1)
        #expect(firstCall.first?.outputTokens == 50)
    }

    @Test("zero-usage synthetic rows and keyless lines follow the JS rules")
    func zeroUsageAndAnonymousEntries() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            // Zero usage: dropped entirely (model nil so no real model is recorded).
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_0", model: nil, input: 0, output: 0),
            // No message.id, requestId or uuid: always kept, model falls back.
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","cwd":"/Users/x/alpha","sessionId":"sid","message":{"usage":{"input_tokens":5,"output_tokens":3}}}
            """,
            // <synthetic> model falls back to the session's last real model.
            assistantLine("2026-09-01T10:00:09.000Z", id: "msg_9", model: nil, input: 1, output: 1),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.count == 2)
        #expect(result.entries.allSatisfy { $0.model == "claude-unknown" })
        #expect(Set(result.entries.map(\.inputTokens)) == [5, 1])
        // All three lines are still assistant timing events.
        #expect(result.events.filter { $0.role == .assistant }.count == 3)
    }

    @Test("last real model wins for <synthetic> rows")
    func syntheticModelFallback() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1", model: "claude-sonnet-4-5"),
            assistantLine("2026-09-01T10:00:02.000Z", id: "msg_2", model: "<synthetic>"),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.map(\.model) == ["claude-sonnet-4-5", "claude-sonnet-4-5"])
    }

    @Test("cache creation counts max(total, 5m + 1h breakdown)")
    func cacheCreationBreakdown() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1",
                          input: 100, cacheCreation: 10,
                          cacheCreationBreakdown: (fiveMin: 40, oneHour: 30)),
            assistantLine("2026-09-01T10:00:02.000Z", id: "msg_2",
                          input: 100, cacheCreation: 90,
                          cacheCreationBreakdown: (fiveMin: 40, oneHour: 30)),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.map(\.inputTokens) == [170, 190])
    }

    @Test("the most complete copy wins when a session exists under several roots")
    func bestCandidateAcrossRoots() throws {
        let rootA = try makeRoot()
        let rootB = try makeRoot()
        try writeJsonl(root: rootA, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1"),
        ])
        try writeJsonl(root: rootB, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1"),
            assistantLine("2026-09-01T10:00:02.000Z", id: "msg_2"),
            assistantLine("2026-09-01T10:00:03.000Z", id: "msg_3"),
        ])
        let result = try VibeClaudeCodeParser(roots: [rootA.path, rootB.path]).parse()
        #expect(result.entries.count == 3)  // larger copy, not 1 + 3
    }

    @Test("the same call copied into another session counts once")
    func crossSessionDedupe() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid-a", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1", requestId: "req_1", output: 10),
        ])
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid-b", lines: [
            assistantLine("2026-09-01T10:00:02.000Z", id: "msg_1", requestId: "req_1", output: 50),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.outputTokens == 50)
        // Both sessions still emit their timing events.
        #expect(Set(result.events.map(\.sessionId)) == ["sid-a", "sid-b"])
    }

    @Test("missing roots and directories yield an empty, non-skipped result")
    func missingDirectories() throws {
        let result = try VibeClaudeCodeParser(roots: ["/nonexistent/vibe-claude-root"]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
        #expect(!result.skipped)
    }

    @Test("corrupt lines are skipped, surrounding rows still parse")
    func corruptLines() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            "not json at all",
            "{\"type\":\"assistant\",\"timestamp\":",  // truncated mid-write
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1"),
            "[1,2,3]",
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.count == 1)
        #expect(!result.skipped)
    }

    @Test("project falls back to the directory name when no cwd is recorded")
    func projectFallbackFromDirectory() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-anbc-myproj/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1", cwd: nil),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.first?.project == "myproj")
        #expect(result.events.first?.project == "myproj")
    }

    @Test("transcripts contribute timing only for sessions projects/ lacks")
    func transcriptsTimingOnly() throws {
        let root = try makeRoot()
        // Session known to projects/: transcripts copy is ignored entirely.
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1"),
        ])
        try writeJsonl(root: root, subdir: "transcripts", path: "sid", lines: [
            userLine("2026-09-01T09:59:00.000Z", cwd: "/elsewhere/wrong"),
        ])
        // Transcript-only session: timing events, per-line cwd project, no entries.
        try writeJsonl(root: root, subdir: "transcripts", path: "other-session", lines: [
            userLine("2026-09-02T08:00:00.000Z", cwd: "/Users/x/beta"),
            assistantLine("2026-09-02T08:00:05.000Z", id: "msg_1", cwd: "/Users/x/beta"),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        let transcriptEvents = result.events.filter { $0.sessionId == "other-session" }
        #expect(transcriptEvents.count == 2)
        #expect(transcriptEvents.allSatisfy { $0.project == "beta" })
        #expect(transcriptEvents.map(\.role) == [.user, .assistant])
        // No event with the transcript copy's cwd-based project leaked in.
        #expect(result.events.allSatisfy { $0.project != "wrong" })
    }

    @Test("VIBE_USAGE_CLAUDE_DIRS replaces default discovery")
    func environmentOverride() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1"),
        ])
        let parser = VibeClaudeCodeParser(environment: [
            "VIBE_USAGE_CLAUDE_DIRS": "/nonexistent/a:" + root.path,
            "CLAUDE_CONFIG_DIR": "/nonexistent/b",
        ])
        let result = try parser.parse()
        #expect(result.entries.count == 1)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            userLine("2026-09-01T10:00:00.000Z"),
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1"),
        ])
        let parser = VibeClaudeCodeParser(roots: [root.path])
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
    }
}
