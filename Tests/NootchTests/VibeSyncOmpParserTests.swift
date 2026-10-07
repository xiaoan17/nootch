import Foundation
import Testing
@testable import Nootch

@Suite struct VibeSyncOmpParserTests {
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

    /// Mirrors vibe-usage test/pi-compatible.test.js sessionLines: a full
    /// SessionHeader plus id/parentId/timestamp message records. `titleSlot`
    /// adds OMP v3's title record, which the parser must ignore.
    private func sessionLines(
        sessionId: String = "session-1",
        cwd: String = "/work/project",
        titleSlot: Bool = false
    ) -> [String] {
        var lines: [String] = []
        if titleSlot {
            lines.append(#"{"type": "title", "v": 1, "title": "Current OMP v3 title slot", "updatedAt": "2026-07-27T13:19:56.000Z", "pad": ""}"#)
        }
        lines.append("""
            {"type": "session", "version": 3, "id": "\(sessionId)", \
            "timestamp": "2026-07-27T13:19:57.000Z", "cwd": "\(cwd)"}
            """)
        lines.append("""
            {"type": "message", "id": "user-1", "parentId": "\(sessionId)", \
            "timestamp": "2026-07-27T13:20:00.000Z", "message": {"role": "user", "content": []}}
            """)
        lines.append("""
            {"type": "message", "id": "assistant-1", "parentId": "user-1", \
            "timestamp": "2026-07-27T13:20:05.000Z", "message": {"role": "assistant", \
            "model": "test-model", "usage": {"input": 100, "output": 20, "cacheRead": 30, \
            "cacheWrite": 10, "reasoningTokens": 4}}}
            """)
        return lines
    }

    // MARK: - Token mapping

    @Test func cacheWritesCountAsInputAndReasoningSplitsFromOutput() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("omp-sessions")
        try writeSession(sessions, "--work-project--/omp.jsonl", sessionLines())

        let result = try VibeOmpParser(sessionsDirs: [sessions.path]).parse()

        #expect(result.skipped == false)
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.source == "omp")
        #expect(entry.project == "project")
        #expect(entry.inputTokens == 110)
        #expect(entry.outputTokens == 16)
        #expect(entry.cachedInputTokens == 30)
        #expect(entry.reasoningOutputTokens == 4)
    }

    // MARK: - Dedupe

    /// Upstream: "OMP scans multiple stores and deduplicates copied records".
    @Test func scansMultipleStoresAndDeduplicatesCopiedRecords() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try writeSession(first, "project/copy.jsonl", sessionLines(titleSlot: true))
        try writeSession(second, "project/copy.jsonl", sessionLines(titleSlot: true))

        let result = try VibeOmpParser(sessionsDirs: [first.path, second.path]).parse()

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "omp")
        #expect(entry.inputTokens == 110)
        #expect(entry.outputTokens == 16)
        #expect(entry.reasoningOutputTokens == 4)
        // Bucket-contract total (input + output + reasoning): 110+16+4 = 130.
        #expect(entry.inputTokens + entry.outputTokens + entry.reasoningOutputTokens == 130)
        #expect(result.events.count == 2)
    }

    // MARK: - Root discovery

    /// Upstream: "OMP discovers XDG profiles and does not also label its
    /// agent store as Pi" (the Pi-side guard is covered by VibePiParserTests).
    @Test func discoversXdgProfilesAndAgentOverride() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgSession = root.appendingPathComponent("xdg/omp/sessions")
        let xdgProfile = root.appendingPathComponent("xdg/omp/profiles/work/sessions")
        let overriddenSession = root.appendingPathComponent(".omp/agent/sessions")
        for directory in [xdgSession, xdgProfile, overriddenSession] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let environment = [
            // Point the default config root at a name that does not exist so
            // the real home directory cannot leak into the assertion.
            "PI_CONFIG_DIR": ".vibe-usage-test-missing-omp-config",
            "XDG_DATA_HOME": root.appendingPathComponent("xdg").path,
            "PI_CODING_AGENT_DIR": root.appendingPathComponent(".omp/agent").path,
        ]
        let dirs = VibeOmpParser.discoverSessionDirs(environment: environment)
        #expect(Set(dirs) == Set([xdgSession.path, xdgProfile.path, overriddenSession.path]))
    }

    @Test func sessionDirsOverrideReplacesDiscovery() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let missing = root.appendingPathComponent("missing")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let environment = [
            "VIBE_USAGE_OMP_SESSION_DIRS": first.path + ":" + second.path + ":" + missing.path,
            "XDG_DATA_HOME": root.appendingPathComponent("xdg").path,
        ]
        #expect(VibeOmpParser.discoverSessionDirs(environment: environment)
            == [first.path, second.path])
    }
}
