import Foundation
import Testing
@testable import Nootch

@Suite struct VibeGrokParserTests {
    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// sessions/<encoded-cwd>/<session-id>/ with optional files.
    @discardableResult
    private func makeSession(
        in root: URL,
        group: String,
        id: String,
        summary: String? = nil,
        updates: [String] = [],
        events: [String]? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent(group).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let summary {
            try summary.write(to: directory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        }
        if !updates.isEmpty {
            try (updates.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        }
        if let events {
            try (events.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func updateLine(kind: String, timestamp: Any, extra: String = "") -> String {
        let ts: String = switch timestamp {
        case let number as Int: String(number)
        case let string as String: "\"\(string)\""
        default: "null"
        }
        return """
            {"timestamp": \(ts), "method": "session/update", "params": {"sessionId": "s", \
            "update": {"sessionUpdate": "\(kind)"\(extra)}}}
            """
    }

    @Test func parsesTurnCompletedUsageWithModelUsage() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = """
            {"info": {"cwd": "/Users/x/awesome-project"}, "current_model_id": "grok-4.5", \
            "created_at": "2026-09-06T10:00:00.000Z"}
            """
        let usage = """
            , "usage": {"inputTokens": 1000, "outputTokens": 200, "cachedReadTokens": 300, \
            "reasoningTokens": 50, "modelUsage": {"grok-4.6-latest": {"inputTokens": 800, \
            "outputTokens": 120, "cachedReadTokens": 100, "reasoningTokens": 20}, \
            "grok-4.5": {"inputTokens": 200, "outputTokens": 80, "cachedReadTokens": 200, \
            "reasoningTokens": 30}}}
            """
        try makeSession(in: root, group: "%2FUsers%2Fx%2Fawesome-project", id: "sess-1",
                        summary: summary, updates: [
                            updateLine(kind: "user_message_chunk", timestamp: 1_787_480_000),
                            updateLine(kind: "agent_message_chunk", timestamp: 1_787_480_010),
                            updateLine(kind: "turn_completed", timestamp: 1_787_480_035, extra: usage),
                        ])

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()

        #expect(result.skipped == false)
        #expect(result.entries.count == 2)
        let byModel = Dictionary(grouping: result.entries, by: \.model)
        let fast = try #require(byModel["grok-4.6-latest"]?.first)
        // input = total - cache reads, output = output - reasoning (no double count)
        #expect(fast.inputTokens == 700)
        #expect(fast.cachedInputTokens == 100)
        #expect(fast.outputTokens == 100)
        #expect(fast.reasoningOutputTokens == 20)
        #expect(fast.project == "awesome-project")
        #expect(fast.source == "grok")
        #expect(fast.timestamp == Date(timeIntervalSince1970: 1_787_480_035))
        let small = try #require(byModel["grok-4.5"]?.first)
        #expect(small.inputTokens == 0) // fully cached
        #expect(small.outputTokens == 50)

        // user chunk, agent chunk, turn_completed → user + 2 assistant events
        #expect(result.events.map(\.role) == [.user, .assistant, .assistant])
        #expect(result.events.allSatisfy { $0.sessionId == "sess-1" && $0.project == "awesome-project" })
    }

    @Test func fallsBackToSummaryModelWithoutModelUsage() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = #"{"info": {"cwd": "/tmp/proj"}, "current_model_id": "grok-4.5"}"#
        let usage = #", "usage": {"inputTokens": 500, "outputTokens": 100, "cachedReadTokens": 0, "reasoningTokens": 0}"#
        try makeSession(in: root, group: "whatever", id: "sess-2", summary: summary, updates: [
            updateLine(kind: "turn_completed", timestamp: 1_787_480_035, extra: usage),
        ])

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.model == "grok-4.5")
        #expect(entry.project == "proj")
        #expect(entry.inputTokens == 500)
        #expect(entry.outputTokens == 100)
    }

    @Test func zeroUsageTurnEmitsNoEntryButKeepsEvent() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = #", "usage": {"inputTokens": 0, "outputTokens": 0, "cachedReadTokens": 0, "reasoningTokens": 0}"#
        try makeSession(in: root, group: "%2Ftmp%2Fp", id: "sess-3", summary: nil, updates: [
            updateLine(kind: "turn_completed", timestamp: 1_787_480_035, extra: usage),
        ])

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.map(\.role) == [.assistant])
        // no summary.json → project falls back to the decoded group dirname
        #expect(result.events.first?.project == "p")
    }

    @Test func deduplicatesAcrossRootsKeepingMoreCompleteCopy() throws {
        let rootA = makeTempDirectory()
        let rootB = makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        // Same session id in both roots; B has the larger updates.jsonl.
        let usage = #", "usage": {"inputTokens": 42, "outputTokens": 7, "cachedReadTokens": 2, "reasoningTokens": 1}"#
        try makeSession(in: rootA, group: "%2Ftmp%2FfromA", id: "dup", summary: nil, updates: [
            updateLine(kind: "user_message_chunk", timestamp: 1_787_480_000),
        ])
        try makeSession(in: rootB, group: "%2Ftmp%2FfromB", id: "dup", summary: nil, updates: [
            updateLine(kind: "user_message_chunk", timestamp: 1_787_480_000),
            updateLine(kind: "turn_completed", timestamp: 1_787_480_035, extra: usage),
        ])

        let result = try VibeGrokParser(sessionRoots: [rootA.path, rootB.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.project == "fromB")
        #expect(result.entries.first?.inputTokens == 40)
        #expect(result.events.allSatisfy { $0.project == "fromB" })
    }

    @Test func missingOrEmptySessionsDirectoryReturnsEmptyResult() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = try VibeGrokParser(sessionRoots: [root.appendingPathComponent("nope").path]).parse()
        #expect(missing.entries.isEmpty && missing.events.isEmpty && !missing.skipped)

        let empty = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(empty.entries.isEmpty && empty.events.isEmpty && !empty.skipped)
    }

    @Test func skipsCorruptLinesAndKeepsParsing() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = #", "usage": {"inputTokens": 10, "outputTokens": 5}"#
        let directory = try makeSession(in: root, group: "g", id: "sess-6", summary: nil)
        let lines = [
            "not json at all",
            updateLine(kind: "user_message_chunk", timestamp: 1_787_480_000),
            "{\"broken\": ",
            updateLine(kind: "turn_completed", timestamp: 1_787_480_035, extra: usage),
            "",
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(result.entries.count == 1)
        #expect(result.events.map(\.role) == [.user, .assistant])
    }

    @Test func fallsBackToEventsJSONLWhenUpdatesLackMessageChunks() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSession(in: root, group: "%2Ftmp%2Fevproj", id: "sess-7", summary: nil,
                        updates: [updateLine(kind: "tool_call", timestamp: 1_787_480_001)],
                        events: [
                            #"{"ts": "2026-09-06T10:00:00.000Z", "type": "turn_started"}"#,
                            #"{"ts": "2026-09-06T10:01:00.000Z", "type": "first_token"}"#,
                            #"{"ts": "2026-09-06T10:02:00.000Z", "type": "turn_ended"}"#,
                        ])

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.events.map(\.role) == [.user, .assistant, .assistant])
        #expect(result.events.first?.timestamp == VibeSyncTime.parse("2026-09-06T10:00:00.000Z"))
        #expect(result.events.first?.project == "evproj")
    }

    @Test func summaryEnvelopeIsLastResortForSessionEvents() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = """
            {"info": {"cwd": "/tmp/envproj"}, "created_at": "2026-09-05T08:00:00.000Z", \
            "updated_at": "2026-09-06T09:30:00.000Z"}
            """
        try makeSession(in: root, group: "g", id: "sess-8", summary: summary)

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(result.events.map(\.role) == [.user, .assistant])
        #expect(result.events[0].timestamp == VibeSyncTime.parse("2026-09-05T08:00:00.000Z"))
        #expect(result.events[1].timestamp == VibeSyncTime.parse("2026-09-06T09:30:00.000Z"))
    }

    @Test func acceptsUnixSecondsAndMillisecondsTimestamps() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = #", "usage": {"inputTokens": 1, "outputTokens": 1}"#
        try makeSession(in: root, group: "g", id: "sess-9", summary: nil, updates: [
            updateLine(kind: "turn_completed", timestamp: 1_787_480_035_000, extra: usage), // ms
        ])

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        let entry = try #require(result.entries.first)
        #expect(entry.timestamp == Date(timeIntervalSince1970: 1_787_480_035))
    }
}
