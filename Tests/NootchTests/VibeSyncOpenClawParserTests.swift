import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage src/parsers/openclaw.js behavior (upstream has no
// dedicated openclaw test; assertions follow the parser source and the shared
// conventions of test/*.test.js). Layout: <root>/agents/<agentId>/sessions/
// *.jsonl; roots are the legacy homes plus .openclaw[-<profile>] directories.
@Suite("VibeOpenClawParser")
struct VibeSyncOpenClawParserTests {
    private static let iso = "2026-09-17T06:26:03.095Z"
    private static let isoLater = "2026-09-17T06:26:05.000Z"

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write <root>/agents/<agent>/sessions/<name>.jsonl.
    @discardableResult
    private func writeSession(
        root: URL, agent: String = "main-agent", name: String = "session-1.jsonl", lines: [String]
    ) throws -> URL {
        let url = root.appendingPathComponent("agents/\(agent)/sessions/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func userLine(timestamp: String = iso) -> String {
        #"{"type":"message","timestamp":"\#(timestamp)","message":{"role":"user","content":[{"text":"DO NOT UPLOAD"}]}}"#
    }

    private func assistantLine(
        model: String? = "kimi-k2",
        outerModel: String? = nil,
        timestamp: String = isoLater,
        usage: String? = #"{"input":100,"output":47,"cacheRead":30,"cacheCreation":10}"#
    ) -> String {
        var fields = [#""type":"message""#, #""timestamp":"\#(timestamp)""#]
        if let outerModel { fields.append(#""model":"\#(outerModel)""#) }
        var message = [#""role":"assistant""#]
        if let model { message.append(#""model":"\#(model)""#) }
        if let usage { message.append(#""usage":\#(usage)"#) }
        fields.append(#""message":{\#(message.joined(separator: ","))}"#)
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test("root resolution: override splits on ':'; default is legacy homes plus .openclaw[-<profile>] dirs")
    func rootResolution() throws {
        #expect(VibeOpenClawParser.resolveRoots(environment: ["VIBE_USAGE_OPENCLAW_DIRS": "/a:/b"]) == ["/a", "/b"])
        #expect(VibeOpenClawParser.resolveRoots(environment: ["VIBE_USAGE_OPENCLAW_DIRS": " /x : /y "]) == ["/x ", " /y"],
                "JS trims the override as a whole, not each part")

        let home = try makeRoot()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".openclaw"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".openclaw-work"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".openclawx"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("openclaw"), withIntermediateDirectories: true)
        let roots = VibeOpenClawParser.resolveRoots(environment: [:], home: home.path)
        #expect(roots.prefix(3) == [home.path + "/.clawdbot", home.path + "/.moltbot", home.path + "/.moldbot"])
        #expect(roots.contains(home.path + "/.openclaw"))
        #expect(roots.contains(home.path + "/.openclaw-work"))
        #expect(!roots.contains(home.path + "/.openclawx"), "regex ^\\.openclaw-.+ requires the dash")
        #expect(!roots.contains(home.path + "/openclaw"))
    }

    @Test("usage key variants resolve; cache writes fold into input")
    func normalParsing() throws {
        let root = try makeRoot()
        let file = try writeSession(root: root, lines: [userLine(), assistantLine()])
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
        #expect(!result.skipped)
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "openclaw")
        #expect(entry.model == "kimi-k2")
        #expect(entry.project == "main-agent")  // the agent directory name
        #expect(entry.timestamp == VibeSyncTime.parse(Self.isoLater))
        #expect(entry.inputTokens == 110)  // input + cacheCreation
        #expect(entry.outputTokens == 47)
        #expect(entry.cachedInputTokens == 30)
        #expect(entry.reasoningOutputTokens == 0)
        #expect(entry.cacheCreation5mTokens == 0)
        #expect(entry.cacheCreation1hTokens == 0)

        #expect(result.events.map(\.role) == [.user, .assistant])
        #expect(result.events.allSatisfy {
            $0.sessionId == file.path && $0.source == "openclaw" && $0.project == "main-agent"
        })

        // Never retain or upload the transcript's text.
        let retained = result.entries.map { "\($0.model)\($0.project)" }
            + result.events.map { "\($0.sessionId)\($0.project)" }
        #expect(retained.allSatisfy { !$0.contains("DO NOT UPLOAD") })
    }

    @Test("every documented alias is accepted, and the first positive key wins")
    func usageAliases() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "a.jsonl", lines: [
            assistantLine(usage: #"{"input_tokens":11,"output_tokens":3,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}"#),
        ])
        try writeSession(root: root, name: "b.jsonl", lines: [
            assistantLine(usage: #"{"promptTokens":12,"completion_tokens":4,"cache_read":5,"cache_write":6}"#),
        ])
        // First *positive* key wins: input 0 falls through to inputTokens 13
        // (JS getTokens: Number(value) must be finite and > 0).
        try writeSession(root: root, name: "c.jsonl", lines: [
            assistantLine(usage: #"{"input":0,"inputTokens":13,"output":-1,"outputTokens":7,"cacheRead":0,"cache_read":8}"#),
        ])
        let entries = try VibeOpenClawParser(roots: [root.path]).parse().entries
        #expect(entries.count == 3)
        // a: input_tokens 11 + cache_creation 1; b: promptTokens 12 + cache_write 6;
        // c: input 0 falls through to inputTokens 13.
        #expect(entries.map(\.inputTokens).sorted() == [12, 13, 18])
        // c: output -1 is not positive → output_tokens 7.
        #expect(entries.map(\.outputTokens).sorted() == [3, 4, 7])
        // c: cacheRead 0 falls through to cache_read 8.
        #expect(entries.map(\.cachedInputTokens).sorted() == [2, 5, 8])
    }

    @Test("non-user roles count as assistant activity but only exact 'assistant' carries usage")
    func roleTernary() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            #"{"type":"message","timestamp":"\#(Self.iso)","message":{"role":"system","content":"x"}}"#,
            #"{"type":"message","timestamp":"\#(Self.isoLater)","message":{"content":"roleless"}}"#,
            #"{"type":"message","timestamp":"2026-09-17T06:26:07.000Z","message":{"role":"tool","usage":{"input":9,"output":9}}}"#,
        ])
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
        // JS: msg.role === 'user' ? 'user' : 'assistant' — everything else is
        // assistant activity; the entry gate is the exact 'assistant' role.
        #expect(result.events.map(\.role) == [.assistant, .assistant, .assistant])
        #expect(result.entries.isEmpty)
    }

    @Test("model falls back msg.model → obj.model → unknown")
    func modelFallback() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "a.jsonl", lines: [
            assistantLine(model: nil, outerModel: "outer-model"),
        ])
        try writeSession(root: root, name: "b.jsonl", lines: [
            assistantLine(model: nil, outerModel: nil),
        ])
        let models = try VibeOpenClawParser(roots: [root.path]).parse().entries.map(\.model).sorted()
        #expect(models == ["outer-model", "unknown"])
    }

    @Test("timestamp falls back to message.timestamp; records without one are dropped")
    func timestampFallback() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            #"{"type":"message","message":{"role":"user","timestamp":"\#(Self.iso)"}}"#,
            #"{"type":"message","message":{"role":"user","timestamp":1789663565095}}"#,
            #"{"type":"message","message":{"role":"user"}}"#,
            #"{"type":"message","timestamp":"not-a-date","message":{"role":"user"}}"#,
        ])
        let events = try VibeOpenClawParser(roots: [root.path]).parse().events
        #expect(events.count == 2)
        #expect(events[0].timestamp == VibeSyncTime.parse(Self.iso))
        #expect(events[1].timestamp == Date(timeIntervalSince1970: 1_789_663_565.095))
    }

    @Test("an assistant message with an all-zero usage still emits an entry")
    func zeroUsageEntry() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [assistantLine(usage: #"{"input":0,"output":0}"#)])
        // JS pushes unconditionally once msg.usage exists (no zero guard).
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.inputTokens == 0)
    }

    @Test("an assistant message without usage emits only the timing event")
    func noUsageEventOnly() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [assistantLine(usage: nil)])
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.map(\.role) == [.assistant])
    }

    @Test("legacy and profile roots are all scanned")
    func multipleRoots() throws {
        let legacy = try makeRoot()
        let profile = try makeRoot()
        try writeSession(root: legacy, agent: "agent-a", lines: [assistantLine()])
        try writeSession(root: profile, agent: "agent-b", lines: [assistantLine()])
        let result = try VibeOpenClawParser(roots: [legacy.path, profile.path]).parse()
        #expect(result.entries.count == 2)
        #expect(Set(result.entries.map(\.project)) == ["agent-a", "agent-b"])
    }

    @Test("only flat *.jsonl under sessions/ are collected")
    func discovery() throws {
        let root = try makeRoot()
        try writeSession(root: root, name: "a.jsonl", lines: [assistantLine()])
        try writeSession(root: root, name: "b.json", lines: [assistantLine()])
        let nested = root.appendingPathComponent("agents/main-agent/sessions/nested/c.jsonl")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (assistantLine() + "\n").write(to: nested, atomically: true, encoding: .utf8)
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
    }

    @Test("corrupt lines are skipped, surrounding rows still parse")
    func corruptLines() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [
            "not json at all",
            #"{"type":"message","timestamp":"#,
            userLine(),
            assistantLine(),
            "[1,2,3]",
        ])
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.count == 2)
        #expect(!result.skipped)
    }

    @Test("a root without agents/ is simply empty, not skipped")
    func missingAgentsDir() throws {
        let root = try makeRoot()
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
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
        let result = try VibeOpenClawParser(roots: [root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(!result.skipped)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        try writeSession(root: root, lines: [userLine(), assistantLine()])
        let parser = VibeOpenClawParser(roots: [root.path])
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
    }
}
