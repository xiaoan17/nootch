import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage src/parsers/gemini-cli.js behavior (upstream has no
// dedicated gemini-cli test; assertions follow the parser source and the
// shared conventions of test/*.test.js). Fixtures copy both store shapes:
// current .jsonl (metadata line + one message per line) and legacy .json
// (single ConversationRecord with messages[]).
@Suite("VibeGeminiCliParser")
struct VibeSyncGeminiCliParserTests {
    private static let iso = "2026-09-17T06:26:03.095Z"
    private static let isoLater = "2026-09-17T06:26:05.000Z"

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write <root>/<projectHash>/chats/<name> (name decides .json/.jsonl).
    @discardableResult
    private func writeSession(
        root: URL, projectHash: String = "a1b2c3", name: String, content: String
    ) throws -> URL {
        let url = root.appendingPathComponent("\(projectHash)/chats/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func metadataLine(directories: String = #"["/Users/me/demo-project"]"#) -> String {
        #"{"sessionId":"s-1","startTime":"2026-09-17T06:25:00.000Z","directories":\#(directories)}"#
    }

    private func userLine(timestamp: String = iso) -> String {
        #"{"type":"user","timestamp":"\#(timestamp)","content":[{"text":"DO NOT UPLOAD"}]}"#
    }

    private func geminiLine(
        model: String? = "gemini-2.5-pro",
        timestamp: String = isoLater,
        tokens: String = #"{"input":1200,"output":80,"cached":1000,"thoughts":30}"#
    ) -> String {
        let modelField = model.map { #""model":"\#($0)""# } ?? ""
        return """
        {"type":"gemini",\(modelField.isEmpty ? "" : modelField + ",")"timestamp":"\(timestamp)","tokens":\(tokens),"content":"DO NOT UPLOAD"}
        """
    }

    @Test("default base dir is ~/.gemini/tmp")
    func defaultBaseDir() {
        #expect(VibeGeminiCliParser.defaultBaseDir(home: "/home/me") == "/home/me/.gemini/tmp")
    }

    @Test("jsonl: metadata directories give the project; inclusive tokens are split")
    func normalJSONL() throws {
        let root = try makeRoot()
        let file = try writeSession(root: root, name: "session-1.jsonl", content: [
            metadataLine(),
            userLine(),
            geminiLine(),
        ].joined(separator: "\n") + "\n")
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(!result.skipped)
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "gemini-cli")
        #expect(entry.model == "gemini-2.5-pro")
        #expect(entry.project == "demo-project")  // basename of directories[0]
        #expect(entry.timestamp == VibeSyncTime.parse(Self.isoLater))
        #expect(entry.inputTokens == 200)   // input − cached
        #expect(entry.outputTokens == 50)   // output − thoughts
        #expect(entry.cachedInputTokens == 1000)
        #expect(entry.reasoningOutputTokens == 30)
        #expect(entry.cacheCreation5mTokens == 0)
        #expect(entry.cacheCreation1hTokens == 0)

        #expect(result.events.count == 2)
        #expect(result.events.map(\.role) == [.user, .assistant])
        #expect(result.events.allSatisfy {
            $0.sessionId == file.path && $0.source == "gemini-cli" && $0.project == "demo-project"
        })

        // Never retain or upload the transcript's text.
        let retained = result.entries.map { "\($0.model)\($0.project)" }
            + result.events.map { "\($0.sessionId)\($0.project)" }
        #expect(retained.allSatisfy { !$0.contains("DO NOT UPLOAD") })
    }

    @Test("legacy .json ConversationRecord with messages[] and usageMetadata fallback")
    func legacyJSON() throws {
        let root = try makeRoot()
        let content = """
        {"sessionId":"s-2","directories":["/work/legacy-proj/"],"messages":[
          {"type":"user","timestamp":"\(Self.iso)"},
          {"type":"gemini","model":"gemini-2.5-flash","timestamp":"\(Self.isoLater)",
           "usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":40,
                            "cachedContentTokenCount":300,"thoughtsTokenCount":10}}
        ]}
        """
        try writeSession(root: root, name: "session-2.json", content: content)
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.project == "legacy-proj")  // trailing slash stripped before basename
        #expect(entry.inputTokens == 200)
        #expect(entry.outputTokens == 30)
        #expect(entry.cachedInputTokens == 300)
        #expect(entry.reasoningOutputTokens == 10)
        #expect(result.events.count == 2)
    }

    @Test("legacy .json falls back to history[] and input_tokens/output_tokens keys")
    func legacyJSONHistory() throws {
        let root = try makeRoot()
        let content = """
        {"history":[
          {"role":"user","createTime":"\(Self.iso)"},
          {"role":"model","timestamp":"\(Self.isoLater)",
           "usage":{"input_tokens":90,"output_tokens":7}}
        ]}
        """
        try writeSession(root: root, name: "session-3.json", content: content)
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.project == "unknown")  // no directories anywhere
        #expect(entry.inputTokens == 90)
        #expect(entry.outputTokens == 7)
        // `role` is accepted as the classifier fallback for older formats.
        #expect(result.events.map(\.role) == [.user, .assistant])
    }

    @Test("role classification: gemini/model/assistant are assistant turns; info/error noise is dropped")
    func roleClassification() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-4.jsonl", content: [
            metadataLine(),
            #"{"type":"info","timestamp":"2026-09-17T06:25:30.000Z","content":"boot"}"#,
            #"{"type":"error","timestamp":"2026-09-17T06:25:31.000Z","content":"boom"}"#,
            #"{"type":"model","timestamp":"\#(Self.isoLater)","tokens":{"input":10,"output":5}}"#,
            #"{"role":"assistant","timestamp":"2026-09-17T06:26:06.000Z","tokens":{"input":1,"output":1}}"#,
        ].joined(separator: "\n") + "\n")
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.events.map(\.role) == [.assistant, .assistant])
        #expect(result.entries.count == 2)
    }

    @Test("records without a valid timestamp are dropped entirely")
    func invalidTimestamps() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-5.jsonl", content: [
            metadataLine(),
            #"{"type":"user","content":"no timestamp at all"}"#,
            #"{"type":"user","timestamp":"not-a-date"}"#,
            // timestamp falsy (0) falls through to createTime (JS `||` chain).
            #"{"type":"user","timestamp":0,"createTime":"\#(Self.iso)"}"#,
        ].joined(separator: "\n") + "\n")
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.events.count == 1)
        #expect(result.events.first?.timestamp == VibeSyncTime.parse(Self.iso))
    }

    @Test("epoch-millisecond numeric timestamps parse")
    func numericTimestamp() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-6.jsonl", content: [
            metadataLine(),
            #"{"type":"user","timestamp":1789663563095}"#,
        ].joined(separator: "\n") + "\n")
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.events.first?.timestamp == Date(timeIntervalSince1970: 1_789_663_563.095))
    }

    @Test("nested subagent session files are collected one level below chats/")
    func nestedSubagentFiles() throws {
        let root = try makeRoot()
        let nested = root.appendingPathComponent("a1b2c3/chats/parent-9/sub-1.jsonl")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (metadataLine() + "\n" + geminiLine() + "\n").write(to: nested, atomically: true, encoding: .utf8)
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.count == 1)
    }

    @Test("an assistant message with an all-zero tokens block still emits an entry")
    func zeroTokensEntry() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-7.jsonl", content: [
            metadataLine(),
            geminiLine(tokens: #"{"input":0,"output":0,"cached":0,"thoughts":0}"#),
        ].joined(separator: "\n") + "\n")
        // JS pushes the entry unconditionally once extractTokens matches.
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.inputTokens == 0)
        #expect(result.entries.first?.model == "gemini-2.5-pro")
    }

    @Test("an assistant message without any tokens emits only the timing event")
    func noTokensEventOnly() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-8.jsonl", content: [
            metadataLine(),
            #"{"type":"gemini","timestamp":"\#(Self.isoLater)","content":"thinking"}"#,
        ].joined(separator: "\n") + "\n")
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.map(\.role) == [.assistant])
    }

    @Test("model falls back to unknown; project to unknown without directories")
    func unknownFallbacks() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-9.jsonl", content: [
            #"{"type":"gemini","timestamp":"\#(Self.isoLater)","tokens":{"input":5,"output":2}}"#,
        ].joined(separator: "\n") + "\n")
        let entry = try #require(try VibeGeminiCliParser(baseDir: root.path).parse().entries.first)
        #expect(entry.model == "unknown")
        #expect(entry.project == "unknown")
    }

    @Test("corrupt lines are skipped, surrounding rows still parse")
    func corruptLines() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-10.jsonl", content: [
            "not json at all",
            #"{"type":"gemini","timestamp":"#,  // truncated mid-write
            metadataLine(),
            userLine(),
            geminiLine(),
            "[1,2,3]",
        ].joined(separator: "\n") + "\n")
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.count == 2)
        #expect(!result.skipped)
    }

    @Test("a missing base dir is simply empty, not skipped")
    func missingBaseDir() throws {
        let root = try makeRoot()
        let result = try VibeGeminiCliParser(baseDir: root.path + "/.gemini/tmp").parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
        #expect(!result.skipped)
    }

    @Test("an unreadable session file is dropped like the JS `continue`, source not skipped")
    func unreadableFileIsDropped() throws {
        let root = try makeRoot()
        let file = try writeSession(root: root, name: "session-11.jsonl", content: geminiLine() + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let result = try VibeGeminiCliParser(baseDir: root.path).parse()
        #expect(result.entries.isEmpty)
        #expect(!result.skipped)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "session-12.jsonl", content: [
            metadataLine(), userLine(), geminiLine(),
        ].joined(separator: "\n") + "\n")
        let parser = VibeGeminiCliParser(baseDir: root.path)
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
    }
}
