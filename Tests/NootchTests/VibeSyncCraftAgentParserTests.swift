import Foundation
import Testing
@testable import Nootch

@Suite struct VibeSyncCraftAgentParserTests {
    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func writeSession(_ sessionsDir: URL, _ relativePath: String, _ lines: [String]) throws -> URL {
        let file = sessionsDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Same fixture shape as vibe-usage test/pi-compatible.test.js; craft
    /// sessions may carry no cwd (the branch directory names the project).
    private func sessionLines(sessionId: String = "session-1", cwd: String? = "/work/project") -> [String] {
        var header = #"{"type": "session", "version": 3, "id": "\#(sessionId)", "timestamp": "2026-07-27T13:19:57.000Z""#
        if let cwd { header += #", "cwd": "\#(cwd)""# }
        header += "}"
        return [
            header,
            """
            {"type": "message", "id": "user-1", "parentId": "\(sessionId)", \
            "timestamp": "2026-07-27T13:20:00.000Z", "message": {"role": "user", "content": []}}
            """,
            """
            {"type": "message", "id": "assistant-1", "parentId": "user-1", \
            "timestamp": "2026-07-27T13:20:05.000Z", "message": {"role": "assistant", \
            "model": "test-model", "usage": {"input": 100, "output": 20, "cacheRead": 30, \
            "cacheWrite": 10, "reasoningTokens": 4}}}
            """,
        ]
    }

    /// Upstream (pi-compatible.test.js): the craft half of "Pi-compatible
    /// parsers count cache writes as input tokens".
    @Test func countsCacheWritesAndDerivesProjectFromBranchDir() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let craftRoot = root.appendingPathComponent("craft")
        try writeSession(
            craftRoot.appendingPathComponent("workspaces"),
            "workspace/sessions/branch-name/.pi-sessions/craft.jsonl",
            sessionLines(cwd: nil))

        let result = try VibeCraftAgentParser(environment: ["CRAFT_AGENT_DIR": craftRoot.path]).parse()

        #expect(result.skipped == false)
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.source == "craft-agent")
        #expect(entry.project == "branch-name")
        #expect(entry.inputTokens == 110)
        #expect(entry.outputTokens == 16)
        #expect(entry.cachedInputTokens == 30)
        #expect(entry.reasoningOutputTokens == 4)
        #expect(result.events.count == 2)
        #expect(result.events.allSatisfy { $0.sessionId == "session-1" && $0.project == "branch-name" })
    }

    @Test func ignoresJsonlFilesOutsidePiSessions() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaces = root.appendingPathComponent("workspaces")
        try writeSession(workspaces, "workspace/sessions/branch/plain.jsonl", sessionLines())
        try writeSession(workspaces, "workspace/other.jsonl", sessionLines(sessionId: "other"))

        let result = try VibeCraftAgentParser(workspacesDir: workspaces.path).parse()

        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }

    /// A session header's cwd wins over the branch-derived project (shared
    /// pi-session-jsonl.js behavior).
    @Test func sessionHeaderCwdOverridesBranchProject() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaces = root.appendingPathComponent("workspaces")
        try writeSession(
            workspaces, "workspace/sessions/branch-name/.pi-sessions/craft.jsonl",
            sessionLines(cwd: "/x/actualproj"))

        let result = try VibeCraftAgentParser(workspacesDir: workspaces.path).parse()
        #expect(result.entries.first?.project == "actualproj")
    }

    // MARK: - projectFromCraftPath

    @Test func projectFromCraftPathUsesSegmentAfterLastSessions() {
        #expect(VibeCraftAgentParser.projectFromCraftPath(
            "/home/u/.craft-agent/workspaces/ws/sessions/branch/.pi-sessions/x.jsonl") == "branch")
        // No `sessions` component: JS falls back to parts[0], empty for
        // absolute paths, then "unknown".
        #expect(VibeCraftAgentParser.projectFromCraftPath(
            "/home/u/.craft-agent/workspaces/ws/.pi-sessions/x.jsonl") == "unknown")
        // A trailing `sessions` has no next segment.
        #expect(VibeCraftAgentParser.projectFromCraftPath(
            "/home/u/workspaces/ws/sessions") == "unknown")
        // Windows separators are normalized first.
        #expect(VibeCraftAgentParser.projectFromCraftPath(
            #"C:\u\.craft-agent\workspaces\ws\sessions\branch\.pi-sessions\x.jsonl"#) == "branch")
    }

    // MARK: - Root discovery

    @Test func workspacesDirHonorsBothEnvironmentNames() {
        #expect(VibeCraftAgentParser.workspacesDir(environment: ["CRAFT_AGENT_DIR": "/tmp/craft"])
            == "/tmp/craft/workspaces")
        #expect(VibeCraftAgentParser.workspacesDir(environment: ["CRAFTAGENT_DIR": "/tmp/craft-alt"])
            == "/tmp/craft-alt/workspaces")
        #expect(VibeCraftAgentParser.workspacesDir(environment: [
            "CRAFT_AGENT_DIR": "  ", "CRAFTAGENT_DIR": "/tmp/craft-alt",
        ]) == "/tmp/craft-alt/workspaces")
        #expect(VibeCraftAgentParser.workspacesDir(environment: [:])
            == NSHomeDirectory() + "/.craft-agent/workspaces")
    }
}
