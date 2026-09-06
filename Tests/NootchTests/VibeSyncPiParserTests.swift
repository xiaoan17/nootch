import Foundation
import Testing
@testable import Nootch

@Suite struct VibePiParserTests {
    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a `.jsonl` session file at `relativePath` under `sessionsDir`.
    @discardableResult
    private func writeSession(_ sessionsDir: URL, _ relativePath: String, _ lines: [String]) throws -> URL {
        let file = sessionsDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Mirrors a real Pi store: the header carries a full SessionHeader
    /// (version/id/timestamp/cwd) and message records carry id/parentId/
    /// timestamp (same fixture shape as vibe-usage test/pi-compatible.test.js).
    private func sessionLines(
        sessionId: String = "session-1",
        cwd: String = "/work/project",
        usage: String = """
            {"input": 100, "output": 20, "cacheRead": 30, "cacheWrite": 10, "reasoningTokens": 4}
            """
    ) -> [String] {
        [
            """
            {"type": "session", "version": 3, "id": "\(sessionId)", \
            "timestamp": "2026-07-27T13:19:57.000Z", "cwd": "\(cwd)"}
            """,
            """
            {"type": "message", "id": "user-1", "parentId": "\(sessionId)", \
            "timestamp": "2026-07-27T13:20:00.000Z", "message": {"role": "user", "content": []}}
            """,
            """
            {"type": "message", "id": "assistant-1", "parentId": "user-1", \
            "timestamp": "2026-07-27T13:20:05.000Z", "message": {"role": "assistant", \
            "model": "test-model", "usage": \(usage)}}
            """,
        ]
    }

    // MARK: - Token mapping

    @Test func cacheWritesCountAsInputAndReasoningSplitsFromOutput() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("pi-sessions")
        try writeSession(sessions, "--work-project--/pi.jsonl", sessionLines())

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()

        #expect(result.skipped == false)
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "pi-coding-agent")
        #expect(entry.model == "test-model")
        #expect(entry.project == "project")
        // input = usage.input + cacheWrite; output = usage.output - reasoning
        #expect(entry.inputTokens == 110)
        #expect(entry.outputTokens == 16)
        #expect(entry.cachedInputTokens == 30)
        #expect(entry.reasoningOutputTokens == 4)
        #expect(result.events.count == 2)
        #expect(Set(result.events.map(\.role)) == [.user, .assistant])
        #expect(result.events.allSatisfy { $0.sessionId == "session-1" && $0.project == "project" })
    }

    @Test func prefersPiReasoningFieldOverLegacySpelling() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        // Pi's own field wins when both spellings are present.
        try writeSession(sessions, "pi.jsonl", sessionLines(
            usage: #"{"input": 100, "output": 20, "cacheRead": 0, "cacheWrite": 0, "reasoning": 8, "reasoningTokens": 99}"#))

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.reasoningOutputTokens == 8)
        #expect(entry.outputTokens == 12)
        // Reasoning is a subset of output, so the total must not change.
        #expect(entry.inputTokens + entry.outputTokens + entry.reasoningOutputTokens == 120)
    }

    @Test func readsLegacyReasoningTokensSpelling() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try writeSession(sessions, "pi.jsonl", sessionLines(
            usage: #"{"input": 100, "output": 20, "cacheRead": 0, "cacheWrite": 0, "reasoningTokens": 8}"#))

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()
        let entry = try #require(result.entries.first)
        #expect(entry.reasoningOutputTokens == 8)
        #expect(entry.outputTokens == 12)
    }

    // MARK: - Dedupe

    @Test func deduplicatesRecordsCopiedAcrossStores() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try writeSession(first, "project/copy.jsonl", sessionLines())
        // Same record ids, but a higher usage score in the second copy: the
        // more complete payload wins, counted once.
        try writeSession(second, "project/copy.jsonl", sessionLines(
            usage: #"{"input": 500, "output": 20, "cacheRead": 30, "cacheWrite": 10, "reasoningTokens": 4}"#))

        let result = try VibePiParser(sessionsDirs: [first.path, second.path]).parse()

        #expect(result.entries.count == 1)
        #expect(result.entries.first?.inputTokens == 510)
        #expect(result.events.count == 2)
    }

    @Test func anonymousRecordsAreCountedOncePerCanonicalFile() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A store written by a harness that only appends can carry usage
        // records with no `id`, which record-level dedup cannot see; the
        // ancestor + descendant roots must not count the file twice.
        let parent = root.appendingPathComponent("store")
        let child = parent.appendingPathComponent("nested")
        try writeSession(child, "session-anonymous.jsonl", [
            """
            {"type": "session", "version": 3, "id": "anonymous-1", \
            "timestamp": "2026-07-27T13:19:57.000Z", "cwd": "/work/project"}
            """,
            """
            {"type": "message", "timestamp": "2026-07-27T13:20:05.000Z", \
            "message": {"role": "assistant", "model": "test-model", \
            "usage": {"input": 10, "output": 0, "cacheRead": 0, "cacheWrite": 0}}}
            """,
        ])

        let result = try VibePiParser(sessionsDirs: [parent.path, child.path]).parse()

        #expect(result.entries.count == 1)
        #expect(result.entries.first?.inputTokens == 10)
        #expect(result.events.count == 1)
        #expect(result.events.first?.role == .assistant)
    }

    // MARK: - Root discovery

    @Test func discoversSessionDirsFromEnvironment() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentDir = root.appendingPathComponent("agent")
        let agentSessions = agentDir.appendingPathComponent("sessions")
        let relocated = root.appendingPathComponent("relocated")
        let configured = root.appendingPathComponent("configured")
        for directory in [agentSessions, relocated, configured] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var environment = [
            "PI_CODING_AGENT_DIR": agentDir.path,
            "PI_CODING_AGENT_SESSION_DIR": relocated.path,
        ]
        // sessionDir from settings.json is honored; project-relative values
        // resolve against a cwd the scanner does not have, so they are ignored.
        try #"{"sessionDir": "\#(configured.path)"}"#
            .write(to: agentDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(Set(VibePiParser.discoverSessionDirs(environment: environment))
            == Set([agentSessions.path, relocated.path, configured.path]))

        try #"{"sessionDir": ".pi/sessions"}"#
            .write(to: agentDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(Set(VibePiParser.discoverSessionDirs(environment: environment))
            == Set([agentSessions.path, relocated.path]))

        // A malformed settings file must not break discovery.
        try "{ not json"
            .write(to: agentDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(Set(VibePiParser.discoverSessionDirs(environment: environment))
            == Set([agentSessions.path, relocated.path]))

        // The fixture override replaces default discovery entirely.
        environment["VIBE_USAGE_PI_SESSION_DIRS"] = relocated.path + ":" + configured.path
        #expect(Set(VibePiParser.discoverSessionDirs(environment: environment))
            == Set([relocated.path, configured.path]))
    }

    @Test func ompStoreIsNotParsedAsPi() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // OMP inherits PI_CODING_AGENT_DIR from Pi; an identifiable OMP store
        // (agent.db marker) must not also be scanned as pi-coding-agent.
        let ompAgent = root.appendingPathComponent(".omp/agent")
        try FileManager.default.createDirectory(
            at: ompAgent.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data().write(to: ompAgent.appendingPathComponent("agent.db"))

        let dirs = VibePiParser.discoverSessionDirs(environment: ["PI_CODING_AGENT_DIR": ompAgent.path])
        #expect(dirs.isEmpty)
    }

    // MARK: - Session identity

    @Test func sessionHeaderOverridesFileDerivedIdentity() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try writeSession(sessions, "2026-07-27-misc/whatever.jsonl", sessionLines(
            sessionId: "s-9", cwd: "/x/actualproj"))
        // No header: the project falls back to the first directory segment's
        // last dash-component (JS projectFromFirstDir).
        try writeSession(sessions, "2026-07-27-fallbackproj/headerless.jsonl", [
            """
            {"type": "message", "id": "m1", "parentId": null, \
            "timestamp": "2026-07-27T13:20:05.000Z", "message": {"role": "assistant", \
            "model": "test-model", "usage": {"input": 10, "output": 5}}}
            """,
        ])

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()

        let headerEntry = try #require(result.entries.first { $0.project == "actualproj" })
        #expect(headerEntry.inputTokens == 110)
        let fallback = try #require(result.entries.first { $0.project == "fallbackproj" })
        #expect(fallback.inputTokens == 10)
        // The headerless file's session id is its filename (minus .jsonl).
        #expect(result.events.first { $0.sessionId == "headerless" }?.project == "fallbackproj")
        #expect(result.events.contains { $0.sessionId == "s-9" })
    }

    @Test func modelFallsBackThroughTheChain() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try writeSession(sessions, "models.jsonl", [
            // message.modelId when message.model is absent.
            """
            {"type": "message", "timestamp": "2026-07-27T13:20:00.000Z", \
            "message": {"role": "assistant", "modelId": "msg-model-id", \
            "usage": {"input": 1, "output": 1}}}
            """,
            // obj.model when the message carries neither.
            """
            {"type": "message", "timestamp": "2026-07-27T13:20:01.000Z", "model": "obj-model", \
            "message": {"role": "assistant", "usage": {"input": 2, "output": 1}}}
            """,
            // "unknown" when nothing names a model.
            """
            {"type": "message", "timestamp": "2026-07-27T13:20:02.000Z", \
            "message": {"role": "assistant", "usage": {"input": 3, "output": 1}}}
            """,
        ])

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()

        #expect(Dictionary(grouping: result.entries, by: \.model).mapValues(\.count)
            == ["msg-model-id": 1, "obj-model": 1, "unknown": 1])
    }

    // MARK: - Timestamp coercion

    @Test func missingTimestampLandsOnEpochAndInvalidDropsRecord() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try writeSession(sessions, "times.jsonl", [
            // JS `new Date(obj.timestamp || message.timestamp || 0)`: no
            // timestamp anywhere means the epoch, and the record is kept.
            """
            {"type": "message", "id": "no-ts", \
            "message": {"role": "assistant", "model": "m", "usage": {"input": 5, "output": 1}}}
            """,
            // A present but unparseable timestamp drops the record entirely.
            """
            {"type": "message", "id": "bad-ts", "timestamp": "not-a-date", \
            "message": {"role": "assistant", "model": "m", "usage": {"input": 50, "output": 1}}}
            """,
            // Numeric timestamps are epoch milliseconds.
            """
            {"type": "message", "id": "num-ts", "timestamp": 1787480000000, \
            "message": {"role": "assistant", "model": "m", "usage": {"input": 7, "output": 1}}}
            """,
        ])

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()

        #expect(result.entries.count == 2)
        let byId = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.inputTokens, $0.timestamp) })
        #expect(byId[5] == Date(timeIntervalSince1970: 0))
        #expect(byId[7] == Date(timeIntervalSince1970: 1_787_480_000))
    }

    @Test func zeroUsageAssistantStillEmitsAnEventButNoEntry() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try writeSession(sessions, "zero.jsonl", [
            """
            {"type": "message", "id": "t1", "timestamp": "2026-07-27T13:20:00.000Z", \
            "message": {"role": "toolResult", "content": []}}
            """,
            """
            {"type": "message", "id": "a1", "timestamp": "2026-07-27T13:20:01.000Z", \
            "message": {"role": "assistant", "model": "m", \
            "usage": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}}
            """,
        ])

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()

        #expect(result.entries.isEmpty)
        // toolResult counts as assistant activity.
        #expect(result.events.count == 2)
        #expect(result.events.allSatisfy { $0.role == .assistant })
    }

    // MARK: - Cache and robustness

    @Test func reparseSkipsUnchangedFilesAndPicksUpAppends() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let file = try writeSession(sessions, "pi.jsonl", sessionLines())
        let parser = VibePiParser(sessionsDirs: [sessions.path])

        let first = try parser.parse()
        #expect(first.entries.count == 1)
        // Cached re-parse yields an identical snapshot.
        #expect(try parser.parse() == first)

        let appended = """
            {"type": "message", "id": "assistant-2", "parentId": "assistant-1", \
            "timestamp": "2026-07-27T13:20:30.000Z", "message": {"role": "assistant", \
            "model": "test-model", "usage": {"input": 40, "output": 10}}}
            """
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((appended + "\n").utf8))
        handle.closeFile()

        let second = try parser.parse()
        #expect(second.entries.count == 2)
        #expect(second.entries.contains { $0.inputTokens == 40 })
    }

    @Test func unreadableFilesMarkTheResultSkipped() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let file = try writeSession(sessions, "pi.jsonl", sessionLines())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()
        #expect(result.skipped == true)
        #expect(result.entries.isEmpty)
    }

    @Test func corruptLinesAreSkippedNeverFatal() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try writeSession(sessions, "pi.jsonl", sessionLines() + [
            "{ not json",
            // A truncated tail as Pi mid-append would leave it.
            #"{"type": "message", "id": "partial""#,
        ])

        let result = try VibePiParser(sessionsDirs: [sessions.path]).parse()
        #expect(result.skipped == false)
        #expect(result.entries.count == 1)
        #expect(result.events.count == 2)
    }
}
