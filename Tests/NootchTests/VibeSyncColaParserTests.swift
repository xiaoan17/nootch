import Foundation
import Testing
@testable import Nootch

/// Swift port of vibe-usage test/cola.test.js. Upstream asserts on hashed
/// session ids and aggregated buckets; here the parser boundary is entries +
/// events, so session identity is asserted on `sessionId` and bucket totals
/// on entry sums.
@Suite struct VibeSyncColaParserTests {
    private let originalTime = "2026-09-10T01:00:00.000Z"
    private let copyTime = "2026-09-10T03:00:00.000Z"

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Upstream history(): one private user prompt and one assistant reply
    /// whose usage carries a cost object the parser must not retain.
    private func history(
        assistantTimestamp: String = "2026-09-10T01:00:02.000Z",
        parentId: String = "1234abcd",
        model: String = "claude-haiku-4-5-20251001",
        input: Int = 100
    ) -> [String] {
        [
            """
            {"type": "message", "id": "1234abcd", "parentId": null, \
            "timestamp": "2026-09-10T01:00:01.000Z", "message": {"role": "user", \
            "content": [{"type": "text", "text": "private prompt"}]}}
            """,
            """
            {"type": "message", "id": "5678abcd", "parentId": "\(parentId)", \
            "timestamp": "\(assistantTimestamp)", "message": {"role": "assistant", \
            "model": "\(model)", "content": [{"type": "text", "text": "private answer"}], \
            "usage": {"input": \(input), "output": 20, "cacheRead": 30, "cacheWrite": 10, \
            "reasoning": 4, "cost": {"total": 123}}}}
            """,
        ]
    }

    /// Upstream fixture().write: sessions/<scope>/session.jsonl with a
    /// Pi-style header (cwd optional) followed by the message records.
    @discardableResult
    private func write(
        _ sessionsDir: URL,
        _ scope: String,
        id: String = "original",
        timestamp: String = "2026-09-10T01:00:00.000Z",
        cwd: String? = "/work/project",
        messages: [String]? = nil
    ) throws -> URL {
        var header = #"{"type": "session", "version": 3, "id": "\#(id)", "timestamp": "\#(timestamp)""#
        if let cwd { header += #", "cwd": "\#(cwd)""# }
        header += "}"
        let lines = [header] + (messages ?? history())
        let file = sessionsDir.appendingPathComponent(scope + "/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func parser(root: URL) -> VibeColaParser {
        VibeColaParser(environment: ["COLA_DATA_DIR": root.path])
    }

    /// Bucket-contract total (VibeSync.swift): input + output + reasoning +
    /// cache creation; cached reads stay out of the total.
    private func totalTokens(_ entries: [VibeTokenEntry]) -> Double {
        entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens
            + $1.reasoningOutputTokens + $1.cacheCreation5mTokens + $1.cacheCreation1hTokens }
    }

    // MARK: - Basics

    /// Upstream: "Cola is registered and parses exclusive tokens without
    /// retaining content or cost" (registration is engine-side here).
    @Test func parsesExclusiveTokensWithoutRetainingContentOrCost() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "desktop-local")

        #expect(VibeColaParser.sessionsDir(environment: ["COLA_DATA_DIR": root.path])
            == sessionsDir.path)
        let result = try parser(root: root).parse()

        #expect(result.skipped == false)
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.source == "cola")
        #expect(entry.model == "claude-haiku-4-5-20251001")
        #expect(entry.project == "project")
        #expect(entry.inputTokens == 110)
        #expect(entry.outputTokens == 16)
        #expect(entry.reasoningOutputTokens == 4)
        #expect(entry.cachedInputTokens == 30)
        #expect(entry.cacheCreation5mTokens == 0)
        #expect(entry.cacheCreation1hTokens == 0)
        #expect(totalTokens(result.entries) == 130)
        #expect(result.events.count == 2)
        // Message contents, cost, and the raw cwd never reach the output.
        let serialized = String(describing: result)
        #expect(!serialized.contains("private"))
        #expect(!serialized.contains("cost"))
        #expect(!serialized.contains("/work/"))
    }

    // MARK: - Copied-session dedup

    /// Upstream: "Cola copies with new headers count once and stay attributed
    /// to the original session" (the newer copy is deliberately visited first).
    @Test func copiesWithNewHeadersCountOnceAndStayAttributedToOriginal() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "a-copy", id: "copy", timestamp: copyTime, cwd: "/work/copied-project")
        try write(sessionsDir, "z-original")

        let result = try parser(root: root).parse()

        #expect(result.entries.count == 1)
        #expect(totalTokens(result.entries) == 130)
        #expect(result.entries.first?.project == "project")
        #expect(result.events.count == 2)
        #expect(result.events.allSatisfy { $0.sessionId == "original" && $0.project == "project" })
    }

    /// Upstream: "Cola counts new calls after copied history in the child
    /// session".
    @Test func countsNewCallsAfterCopiedHistoryInChildSession() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "original")
        let newMessages = [
            """
            {"type": "message", "id": "new-0", "parentId": "5678abcd", \
            "timestamp": "2026-09-10T03:00:01.000Z", "message": {"role": "user", \
            "content": [{"type": "text", "text": "private prompt"}]}}
            """,
            """
            {"type": "message", "id": "new-1", "parentId": "new-0", \
            "timestamp": "2026-09-10T03:00:02.000Z", "message": {"role": "assistant", \
            "model": "claude-haiku-4-5-20251001", \
            "content": [{"type": "text", "text": "private answer"}], \
            "usage": {"input": 100, "output": 20, "cacheRead": 30, "cacheWrite": 10, \
            "reasoning": 4, "cost": {"total": 123}}}}
            """,
        ]
        try write(sessionsDir, "copy", id: "copy", timestamp: copyTime,
                  messages: history() + newMessages)

        let result = try parser(root: root).parse()

        #expect(totalTokens(result.entries) == 260)
        let messageCounts = Dictionary(grouping: result.events, by: \.sessionId).mapValues(\.count)
        #expect(messageCounts == ["original": 2, "copy": 2])
    }

    /// Upstream: "Cola retains the only remaining copy of a session".
    @Test func retainsOnlyRemainingCopy() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "copy", id: "copy", timestamp: copyTime)

        let result = try parser(root: root).parse()

        #expect(totalTokens(result.entries) == 130)
        #expect(result.events.allSatisfy { $0.sessionId == "copy" })
    }

    /// Upstream: "Cola keeps richer usage from a copy without changing
    /// original project ownership".
    @Test func keepsRicherUsageFromCopyWithoutChangingOwnership() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "original")
        try write(sessionsDir, "copy", id: "copy", timestamp: copyTime, cwd: "/work/copy",
                  messages: history(input: 200))

        let result = try parser(root: root).parse()

        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.inputTokens == 210)
        #expect(entry.project == "project")
        #expect(result.events.allSatisfy { $0.sessionId == "original" })
    }

    /// Upstream: "Cola does not merge short message-id collisions with a
    /// different timestamp / parentId / model".
    @Test(arguments: ["timestamp", "parentId", "model"])
    func doesNotMergeShortMessageIdCollisions(dimension: String) throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "first")
        let mutated: [String]
        switch dimension {
        case "timestamp":
            mutated = history(assistantTimestamp: "2026-09-10T01:00:03.000Z")
        case "parentId":
            mutated = history(parentId: "other-parent")
        default:
            mutated = history(model: "gpt-5.6-luna")
        }
        try write(sessionsDir, "second", id: "second", messages: mutated)

        let result = try parser(root: root).parse()

        #expect(totalTokens(result.entries) == 260)
    }

    /// Upstream: "Cola never derives a project from a channel or contact
    /// scope".
    @Test func neverDerivesProjectFromChannelOrContactScope() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "channel-person-123", cwd: nil)

        let result = try parser(root: root).parse()

        #expect(result.entries.first?.project == "unknown")
        #expect(result.events.first?.project == "unknown")
        #expect(!String(describing: result).contains("channel-person"))
    }

    /// Upstream: "Cola copy dedup leaves existing Pi-family session
    /// identities unchanged" — the same store parsed without the dedup flag
    /// keeps sessionId:id identities, counting both copies.
    @Test func copyDedupLeavesPiFamilyIdentitiesUnchanged() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "original")
        try write(sessionsDir, "copy", id: "copy", timestamp: copyTime)

        let result = try VibePiSessionJSONLParser(
            source: "pi-coding-agent", sessionsDirs: [sessionsDir.path]).parse()

        #expect(totalTokens(result.entries) == 260)
        #expect(Set(result.events.map(\.sessionId)) == ["original", "copy"])
    }

    // MARK: - Robustness

    /// Upstream: "Cola ignores missing stores and malformed non-record
    /// values".
    @Test func ignoresMissingStoresAndMalformedNonRecordValues() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var result = try parser(root: root).parse()
        #expect(result.skipped == false)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)

        let file = try write(root.appendingPathComponent("sessions"), "desktop")
        try "null\n\"not a record\"\n{broken\n".write(to: file, atomically: true, encoding: .utf8)

        result = try parser(root: root).parse()
        #expect(result.skipped == false)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }

    /// Upstream: "Cola suppresses partial results and protects state when a
    /// scope is unreadable" (POSIX chmod fixture; root bypasses the denial).
    @Test func suppressesPartialResultsWhenScopeIsUnreadable() throws {
        guard getuid() != 0 else { return }
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try write(sessionsDir, "readable")
        try write(sessionsDir, "blocked", id: "blocked")
        let blocked = sessionsDir.appendingPathComponent("blocked")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }

        let result = try parser(root: root).parse()
        #expect(result.skipped == true)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }
}
