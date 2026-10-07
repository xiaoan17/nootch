import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage src/parsers/copilot-cli.js behavior (upstream has
// no dedicated copilot-cli test; assertions follow the parser source and the
// shared conventions of test/*.test.js). Layout:
// ~/.copilot/session-state/<sessionId>/events.jsonl — session.start/resume
// set the project, user.message/assistant.message are timing events, and
// session.shutdown carries the usage summary in data.modelMetrics.
@Suite("VibeCopilotCliParser")
struct VibeSyncCopilotCliParserTests {
    private static let iso = "2026-09-17T06:26:03.095Z"
    private static let isoLater = "2026-09-17T06:26:05.000Z"
    private static let isoShutdown = "2026-09-17T06:30:00.000Z"

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write <root>/<sessionId>/events.jsonl.
    @discardableResult
    private func writeEvents(root: URL, sessionId: String, lines: [String]) throws -> URL {
        let url = root.appendingPathComponent("\(sessionId)/events.jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func startLine(gitRoot: String? = "/Users/me/demo-project", cwd: String? = nil) -> String {
        var context: [String] = []
        if let gitRoot { context.append(#""gitRoot":"\#(gitRoot)""#) }
        if let cwd { context.append(#""cwd":"\#(cwd)""#) }
        return #"{"type":"session.start","timestamp":"\#(Self.iso)","data":{"context":{\#(context.joined(separator: ","))}}}"#
    }

    private func messageLine(_ type: String, timestamp: String) -> String {
        #"{"type":"\#(type)","timestamp":"\#(timestamp)","data":{"message":{"content":"DO NOT UPLOAD"}}}"#
    }

    private func shutdownLine(
        timestamp: String = isoShutdown,
        modelMetrics: String = #"{"gpt-5":{"requests":{"count":1},"usage":{"inputTokens":1200,"outputTokens":80,"cacheReadTokens":1000,"cacheWriteTokens":10}}}"#
    ) -> String {
        #"{"type":"session.shutdown","timestamp":"\#(timestamp)","data":{"modelMetrics":\#(modelMetrics)}}"#
    }

    @Test("default base dir is ~/.copilot/session-state")
    func defaultBaseDir() {
        #expect(VibeCopilotCliParser.defaultBaseDir(home: "/home/me") == "/home/me/.copilot/session-state")
    }

    @Test("shutdown summaries emit per-model entries; cache reads are split out of input")
    func normalParsing() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "session-abc", lines: [
            startLine(),
            messageLine("user.message", timestamp: Self.iso),
            messageLine("assistant.message", timestamp: Self.isoLater),
            shutdownLine(),
        ])
        let result = try VibeCopilotCliParser(baseDir: root.path).parse()
        #expect(!result.skipped)
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.source == "copilot-cli")
        #expect(entry.model == "gpt-5")
        #expect(entry.project == "demo-project")  // basename of gitRoot
        #expect(entry.timestamp == VibeSyncTime.parse(Self.isoShutdown))
        #expect(entry.inputTokens == 200)  // max(0, inputTokens − cacheReadTokens)
        #expect(entry.outputTokens == 80)
        #expect(entry.cachedInputTokens == 1000)
        #expect(entry.reasoningOutputTokens == 0)
        // cacheWriteTokens only gates the all-zero skip; cache writes are
        // already part of the reported input for this schema.
        #expect(entry.cacheCreation5mTokens == 0)
        #expect(entry.cacheCreation1hTokens == 0)

        #expect(result.events.map(\.role) == [.user, .assistant])
        #expect(result.events.allSatisfy {
            $0.sessionId == "session-abc" && $0.source == "copilot-cli" && $0.project == "demo-project"
        })

        // Never retain or upload the transcript's text.
        let retained = result.entries.map { "\($0.model)\($0.project)" }
            + result.events.map { "\($0.sessionId)\($0.project)" }
        #expect(retained.allSatisfy { !$0.contains("DO NOT UPLOAD") })
    }

    @Test("project context: gitRoot wins, cwd is the fallback, unknown before any start")
    func projectContext() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-1", lines: [
            // Before any session.start: project is "unknown".
            messageLine("user.message", timestamp: Self.iso),
            startLine(gitRoot: "", cwd: "/work/fallback-cwd"),  // "" is falsy → cwd (JS `||`)
            messageLine("user.message", timestamp: Self.isoLater),
            #"{"type":"session.resume","timestamp":"2026-09-17T06:27:00.000Z","data":{"context":{"gitRoot":"/work/resumed-proj/"}}}"#,
            messageLine("assistant.message", timestamp: "2026-09-17T06:27:01.000Z"),
        ])
        let events = try VibeCopilotCliParser(baseDir: root.path).parse().events
        #expect(events.map(\.project) == ["unknown", "fallback-cwd", "resumed-proj"])
    }

    @Test("cache reads can exceed input: input clamps at zero")
    func inputClampsAtZero() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-2", lines: [
            shutdownLine(modelMetrics: #"{"claude-sonnet-4.5":{"usage":{"inputTokens":100,"cacheReadTokens":300,"outputTokens":5}}}"#),
        ])
        let entry = try #require(try VibeCopilotCliParser(baseDir: root.path).parse().entries.first)
        #expect(entry.inputTokens == 0)
        #expect(entry.cachedInputTokens == 300)
        #expect(entry.outputTokens == 5)
        #expect(entry.project == "unknown")  // no session.start in the file
    }

    @Test("all-zero models and usage-less models are skipped; a cache-write-only model survives")
    func zeroGate() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-3", lines: [
            shutdownLine(modelMetrics: #"{"zeroed":{"usage":{"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0}},"no-usage":{"requests":{"count":2}},"write-only":{"usage":{"inputTokens":0,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":7}}}"#),
        ])
        let entries = try VibeCopilotCliParser(baseDir: root.path).parse().entries
        #expect(entries.count == 1)
        #expect(entries.first?.model == "write-only")
        #expect(entries.first?.inputTokens == 0)
        #expect(entries.first?.outputTokens == 0)
    }

    @Test("one shutdown summarizes several models")
    func multipleModels() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-4", lines: [
            shutdownLine(modelMetrics: #"{"gpt-5":{"usage":{"inputTokens":10,"outputTokens":1}},"gpt-5-mini":{"usage":{"inputTokens":20,"outputTokens":2}}}"#),
        ])
        let entries = try VibeCopilotCliParser(baseDir: root.path).parse().entries
        #expect(entries.map(\.model).sorted() == ["gpt-5", "gpt-5-mini"])
        #expect(entries.map(\.inputTokens).sorted() == [10, 20])
    }

    @Test("message events need a valid timestamp; shutdown without one emits nothing")
    func timestampGate() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-5", lines: [
            messageLine("user.message", timestamp: "not-a-date"),
            #"{"type":"user.message","data":{}}"#,  // no timestamp at all
            messageLine("assistant.message", timestamp: Self.isoLater),
            #"{"type":"session.shutdown","timestamp":"not-a-date","data":{"modelMetrics":{"gpt-5":{"usage":{"inputTokens":9}}}}}"#,
        ])
        let result = try VibeCopilotCliParser(baseDir: root.path).parse()
        #expect(result.events.map(\.role) == [.assistant])
        #expect(result.entries.isEmpty)
    }

    @Test("session id is the directory name, not the file path")
    func sessionIdIsDirectoryName() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "9f8e7d6c-1234", lines: [
            messageLine("user.message", timestamp: Self.iso),
        ])
        let events = try VibeCopilotCliParser(baseDir: root.path).parse().events
        #expect(events.map(\.sessionId) == ["9f8e7d6c-1234"])
    }

    @Test("only <dir>/events.jsonl pairs are collected")
    func discovery() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-6", lines: [shutdownLine()])
        // A plain file directly under the base dir is not a session dir.
        try shutdownLine().write(to: root.appendingPathComponent("events.jsonl"),
                                 atomically: true, encoding: .utf8)
        // A session dir without events.jsonl contributes nothing.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("s-7"), withIntermediateDirectories: true)
        let result = try VibeCopilotCliParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
    }

    @Test("corrupt lines are skipped, surrounding rows still parse")
    func corruptLines() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-8", lines: [
            "not json at all",
            #"{"type":"session.shutdown","timestamp":"#,
            messageLine("user.message", timestamp: Self.iso),
            shutdownLine(),
            "[1,2,3]",
        ])
        let result = try VibeCopilotCliParser(baseDir: root.path).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.count == 1)
        #expect(!result.skipped)
    }

    @Test("a missing base dir is simply empty, not skipped")
    func missingBaseDir() throws {
        let root = try makeRoot()
        let result = try VibeCopilotCliParser(baseDir: root.path + "/.copilot/session-state").parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
        #expect(!result.skipped)
    }

    @Test("an unreadable event file is dropped like the JS `continue`, source not skipped")
    func unreadableFileIsDropped() throws {
        let root = try makeRoot()
        let file = try writeEvents(root: root, sessionId: "s-9", lines: [shutdownLine()])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let result = try VibeCopilotCliParser(baseDir: root.path).parse()
        #expect(result.entries.isEmpty)
        #expect(!result.skipped)
    }

    @Test("a second parse over unchanged files returns the same snapshot from cache")
    func cacheConsistency() throws {
        let root = try makeRoot()
        try writeEvents(root: root, sessionId: "s-10", lines: [
            startLine(),
            messageLine("user.message", timestamp: Self.iso),
            shutdownLine(),
        ])
        let parser = VibeCopilotCliParser(baseDir: root.path)
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
    }
}
