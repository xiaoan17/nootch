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
        speed: String? = nil,
        cwd: String? = "/Users/x/alpha",
        uuid: String = UUID().uuidString) -> String
    {
        var usage = "\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":\(cacheCreation),\"cache_read_input_tokens\":\(cacheRead)"
        if let breakdown = cacheCreationBreakdown {
            usage += ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(breakdown.fiveMin),\"ephemeral_1h_input_tokens\":\(breakdown.oneHour)}"
        }
        if let speed {
            usage += ",\"speed\":\"\(speed)\""
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
        #expect(entry.inputTokens == 100)  // cache creation is NOT folded in (upstream e9ae391)
        #expect(entry.cacheCreation5mTokens == 20)  // no TTL breakdown → remainder to the cheaper 5m bucket
        #expect(entry.cacheCreation1hTokens == 0)
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

    // Upstream e9ae391: cache creation splits by TTL; the unexplained
    // remainder of cache_creation_input_tokens (breakdown missing or short)
    // lands on the cheaper 5m bucket, never on 1h. The split total still
    // equals the old max(direct, breakdown) exactly.
    @Test("cache creation splits by TTL, unexplained remainder booked to 5m")
    func cacheCreationBreakdown() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            // Breakdown (40 + 30 = 70) exceeds the stated total (10): split wins as-is.
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1",
                          input: 100, cacheCreation: 10,
                          cacheCreationBreakdown: (fiveMin: 40, oneHour: 30)),
            // Breakdown short of the total: 70 explained, 20 unexplained → 5m.
            assistantLine("2026-09-01T10:00:02.000Z", id: "msg_2",
                          input: 100, cacheCreation: 90,
                          cacheCreationBreakdown: (fiveMin: 40, oneHour: 30)),
            // No breakdown at all: the whole total is unexplained → 5m.
            assistantLine("2026-09-01T10:00:03.000Z", id: "msg_3",
                          input: 3, output: 1, cacheCreation: 400),
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.map(\.inputTokens) == [100, 100, 3])
        #expect(result.entries.map(\.cacheCreation5mTokens) == [40, 60, 400])
        #expect(result.entries.map(\.cacheCreation1hTokens) == [30, 30, 0])
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

    // Upstream e9ae391: fast mode (usage.speed == "fast") is a priced service
    // tier; the parser tags the model with a `-fast` marker and the server's
    // pricing map resolves it, falling back to the base rate when no priority
    // tier is published.
    @Test("fast-mode records get a -fast model marker, standard records do not")
    func fastModeSpeedMarker() throws {
        let root = try makeRoot()
        try writeJsonl(root: root, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1", model: "claude-opus-5",
                          input: 10, output: 2, speed: "standard"),
            assistantLine("2026-09-01T10:00:02.000Z", id: "msg_2", model: "claude-opus-5",
                          input: 10, output: 2, speed: "fast"),
            // Already-suffixed models are not double-tagged; casing/whitespace
            // around "fast" is tolerated.
            assistantLine("2026-09-01T10:00:03.000Z", id: "msg_3", model: "claude-opus-5-fast",
                          input: 1, output: 1, speed: " Fast "),
            // message.speed is accepted too (a build that moves the field).
            """
            {"type":"assistant","timestamp":"2026-09-01T10:00:04.000Z","cwd":"/Users/x/alpha","sessionId":"sid","uuid":"u4","message":{"id":"msg_4","model":"claude-opus-5","speed":"fast","usage":{"input_tokens":5,"output_tokens":1}}}
            """,
        ])
        let result = try VibeClaudeCodeParser(roots: [root.path]).parse()
        #expect(result.entries.count == 4)
        let byId = Dictionary(grouping: result.entries, by: \.timestamp)
        #expect(byId[date("2026-09-01T10:00:01.000Z")]?.first?.model == "claude-opus-5")
        #expect(byId[date("2026-09-01T10:00:02.000Z")]?.first?.model == "claude-opus-5-fast")
        #expect(byId[date("2026-09-01T10:00:03.000Z")]?.first?.model == "claude-opus-5-fast")
        #expect(byId[date("2026-09-01T10:00:04.000Z")]?.first?.model == "claude-opus-5-fast")
        // Token mapping itself is unaffected by the marker.
        #expect(byId[date("2026-09-01T10:00:02.000Z")]?.first?.inputTokens == 10)
    }

    // Upstream 22cef3d: explicit extra roots are additive, and a session
    // copied between the primary and an extra root is scanned once.
    @Test("explicit extra roots are additive and copied sessions stay deduplicated")
    func extraRootsAdditive() throws {
        let container = try makeRoot()
        let primary = container.appendingPathComponent("primary")
        let extra = container.appendingPathComponent("extra")
        let copied = [
            userLine("2026-09-01T10:00:00.000Z"),
            assistantLine("2026-09-01T10:00:01.000Z", id: "call", requestId: "request", input: 10, output: 2),
        ]
        try writeJsonl(root: primary, subdir: "projects", path: "-Users-x-alpha/one", lines: copied)
        try writeJsonl(root: extra, subdir: "projects", path: "-Users-x-alpha/one", lines: copied)
        try writeJsonl(root: extra, subdir: "projects", path: "-Users-x-alpha/two", lines: [
            userLine("2026-09-01T10:01:00.000Z"),
            assistantLine("2026-09-01T10:01:01.000Z", id: "call2", requestId: "request2", input: 5, output: 1),
        ])

        // The primary root passed again as an extra root collapses in dedupe.
        let result = try VibeClaudeCodeParser(roots: [primary.path], extraRoots: [extra.path, primary.path]).parse()
        #expect(!result.skipped)
        #expect(result.entries.map(\.inputTokens).sorted() == [5, 10])  // 15 total, not 25
        #expect(Set(result.events.map(\.sessionId)) == ["one", "two"])
    }

    // Upstream 22cef3d: an extra root without a readable projects/ or
    // transcripts/ directory is invalid; the JS warning collapses into
    // `skipped: true` here so incremental state is never pruned on it.
    @Test("an invalid extra root flags the result skipped without dropping valid data")
    func invalidExtraRootSkips() throws {
        let primary = try makeRoot()
        try writeJsonl(root: primary, subdir: "projects", path: "-Users-x-alpha/sid", lines: [
            assistantLine("2026-09-01T10:00:01.000Z", id: "msg_1"),
        ])

        let missing = try VibeClaudeCodeParser(
            roots: [primary.path], extraRoots: [primary.appendingPathComponent("missing").path]).parse()
        #expect(missing.skipped)
        #expect(missing.entries.count == 1)

        // An existing directory without projects/ or transcripts/ is invalid too.
        let empty = try makeRoot()
        let noStore = try VibeClaudeCodeParser(roots: [primary.path], extraRoots: [empty.path]).parse()
        #expect(noStore.skipped)
        #expect(noStore.entries.count == 1)
    }

    // Upstream 5387113: a root that exists but is not a directory must not
    // pass as a successful empty scan (that would let incremental state be
    // pruned); a missing root stays a silent empty scan.
    @Test("a root that is a regular file flags skipped instead of an empty success")
    func fileRootIsInvalid() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("not-a-directory")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let invalid = try VibeClaudeCodeParser(roots: [file.path]).parse()
        #expect(invalid.skipped)
        #expect(invalid.entries.isEmpty)
        #expect(invalid.events.isEmpty)

        let missing = try VibeClaudeCodeParser(roots: [root.appendingPathComponent("missing").path]).parse()
        #expect(!missing.skipped)
        #expect(missing.entries.isEmpty)
    }
}
