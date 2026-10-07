import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage src/parsers/qwen-code.js behavior (upstream has no
// dedicated qwen-code test; assertions follow the parser source and the shared
// conventions of test/*.test.js). Qwen Code is a Gemini CLI fork: JSONL at
// ~/.qwen/tmp/<project_id>/chats/<sessionId>.jsonl with usageMetadata counts.
@Suite("VibeQwenCodeParser")
struct VibeSyncQwenCodeParserTests {
    private static let iso = "2026-09-17T06:26:03.095Z"
    private static let isoLater = "2026-09-17T06:26:05.000Z"

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write <root>/<projectId>/chats/<name>.
    @discardableResult
    private func writeSession(
        root: URL, projectId: String = "proj-hash-1", name: String = "session-1.jsonl", lines: [String]
    ) throws -> URL {
        let url = root.appendingPathComponent("\(projectId)/chats/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func userLine(timestamp: String = iso, cwd: String? = "/work/demo-project") -> String {
        let cwdField = cwd.map { #","cwd":"\#($0)""# } ?? ""
        return #"{"type":"user","timestamp":"\#(timestamp)","content":[{"text":"DO NOT UPLOAD"}]\#(cwdField)}"#
    }

    private func assistantLine(
        uuid: String? = "uuid-1",
        model: String? = "qwen3-coder-plus",
        timestamp: String = isoLater,
        cwd: String? = "/work/demo-project",
        usage: String? = #"{"promptTokenCount":1200,"candidatesTokenCount":80,"cachedContentTokenCount":1000,"thoughtsTokenCount":30}"#
    ) -> String {
        var fields = [#""type":"assistant""#, #""timestamp":"\#(timestamp)""#]
        if let uuid { fields.append(#""uuid":"\#(uuid)""#) }
        if let model { fields.append(#""model":"\#(model)""#) }
        if let cwd { fields.append(#""cwd":"\#(cwd)""#) }
        if let usage { fields.append(#""usageMetadata":\#(usage)"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test("default base dir is ~/.qwen/tmp")
    func defaultBaseDir() {
        #expect(VibeQwenCodeParser.defaultBaseDir(home: "/home/me") == "/home/me/.qwen/tmp")
    }

    @Test("inclusive counts are split; project comes from the record cwd")
    func normalParsing() throws {
        let root = try makeRoot()
        let file = try writeSession(root: root, lines: [userLine(), assistantLine()])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(!result.skipped)
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "qwen-code")
        #expect(entry.model == "qwen3-coder-plus")
        #expect(entry.project == "demo-project")  // last component of cwd
        #expect(entry.timestamp == VibeSyncTime.parse(Self.isoLater))
        #expect(entry.inputTokens == 200)   // promptTokenCount − cached
        #expect(entry.outputTokens == 50)   // candidatesTokenCount − thoughts
        #expect(entry.cachedInputTokens == 1000)
        #expect(entry.reasoningOutputTokens == 30)
        #expect(entry.cacheCreation5mTokens == 0)
        #expect(entry.cacheCreation1hTokens == 0)

        #expect(result.events.map(\.role) == [.user, .assistant])
        #expect(result.events.allSatisfy {
            $0.sessionId == file.path && $0.source == "qwen-code" && $0.project == "demo-project"
        })

        // Never retain or upload the transcript's text.
        let retained = result.entries.map { "\($0.model)\($0.project)" }
            + result.events.map { "\($0.sessionId)\($0.project)" }
        #expect(retained.allSatisfy { !$0.contains("DO NOT UPLOAD") })
    }

    @Test("project falls back to the <project_id> path segment, then unknown")
    func projectFallback() throws {
        let root = try makeRoot()
        // No cwd on the record → first path segment under the tmp dir.
        try writeSession(root: root, projectId: "hashed-project", lines: [assistantLine(cwd: nil)])
        // cwd "/" splits to no components → same path fallback (JS `parts.length > 0` gate).
        try writeSession(root: root, projectId: "hashed-project", name: "session-2.jsonl",
                         lines: [assistantLine(uuid: "uuid-2", cwd: "/")])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.count == 2)
        #expect(result.entries.allSatisfy { $0.project == "hashed-project" })
    }

    @Test("a truthy uuid dedupes globally, first occurrence wins; events still count both")
    func uuidDedupe() throws {
        let root = try makeRoot()
        // Same uuid in two files = one copied record; the copy carries
        // different counts to prove the first (sorted-path) file wins.
        try writeSession(root: root, name: "a-session.jsonl", lines: [assistantLine()])
        try writeSession(root: root, name: "b-session.jsonl", lines: [
            assistantLine(usage: #"{"promptTokenCount":9,"candidatesTokenCount":9}"#),
        ])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1, "one logical record must produce one entry")
        #expect(result.entries.first?.inputTokens == 200, "the first occurrence wins")
        #expect(result.events.count == 2, "the dedupe gate sits after event emission (JS order)")
    }

    @Test("empty or missing uuids are never merged")
    func idlessRecordsAreNotMerged() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            assistantLine(uuid: nil),
            assistantLine(uuid: nil),
            assistantLine(uuid: ""),  // JS `if (uuid)`: empty string is falsy
        ])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.count == 3)
    }

    @Test("an assistant line with both token counts missing emits only the event")
    func usageGate() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            assistantLine(uuid: "u-a", usage: nil),  // no usageMetadata at all
            assistantLine(uuid: "u-b", usage: #"{"cachedContentTokenCount":50}"#),
            // One of the two counts present (0 is present, JS `== null` gate):
            // the entry survives with a zero side.
            assistantLine(uuid: "u-c", usage: #"{"promptTokenCount":0,"cachedContentTokenCount":0}"#),
        ])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.inputTokens == 0)
        #expect(result.events.map(\.role) == [.assistant, .assistant, .assistant])
    }

    @Test("records without a valid timestamp are dropped entirely")
    func invalidTimestamps() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            #"{"type":"user","content":"no timestamp"}"#,
            #"{"type":"user","timestamp":"not-a-date"}"#,
            #"{"type":"assistant","timestamp":1789663565095,"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}"#,
        ])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.events.count == 1)
        #expect(result.events.first?.timestamp == Date(timeIntervalSince1970: 1_789_663_565.095))
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.model == "unknown")
    }

    @Test("non-user/assistant types contribute nothing")
    func otherTypes() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            #"{"type":"system","timestamp":"\#(Self.iso)"}"#,
            #"{"type":"tool_result","timestamp":"\#(Self.iso)"}"#,
        ])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }

    @Test("only flat *.jsonl under chats/ are collected (no recursion, no .json)")
    func discovery() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-1.jsonl", lines: [assistantLine(uuid: "u-1")])
        try writeSession(root: root, name: "session-2.json", lines: [assistantLine(uuid: "u-2")])
        let nested = root.appendingPathComponent("proj-hash-1/chats/nested/session-3.jsonl")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (assistantLine(uuid: "u-3") + "\n").write(to: nested, atomically: true, encoding: .utf8)
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
    }

    @Test("corrupt lines are skipped, surrounding rows still parse")
    func corruptLines() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            "not json at all",
            #"{"type":"assistant","timestamp":"#,
            userLine(),
            assistantLine(),
            "[1,2,3]",
        ])
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.count == 2)
        #expect(!result.skipped)
    }

    @Test("a missing base dir is simply empty, not skipped")
    func missingBaseDir() throws {
        let root = try makeRoot()
        let result = try VibeQwenCodeParser(baseDir: root.path + "/.qwen/tmp").parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
        #expect(!result.skipped)
    }

    @Test("an unreadable session file is dropped like the JS `continue`, source not skipped")
    func unreadableFileIsDropped() throws {
        let root = try makeRoot()
        let file = try writeSession(root: root, lines: [assistantLine()])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let result = try VibeQwenCodeParser(baseDir: root.path).parse()
        #expect(result.entries.isEmpty)
        #expect(!result.skipped)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [userLine(), assistantLine()])
        let parser = VibeQwenCodeParser(baseDir: root.path)
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
    }
}
