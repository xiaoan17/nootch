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
        events: [String]? = nil,
        usageLedger: String? = nil,
        signals: String? = nil
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
        if let usageLedger {
            try usageLedger.write(to: directory.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)
        }
        if let signals {
            try signals.write(to: directory.appendingPathComponent("signals.json"), atomically: true, encoding: .utf8)
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

    // Upstream b4a3874: Grok 1.0 keeps token accounting out of the ACP stream —
    // turn_completed carries no usage, the totals live in usage.json.
    @Test func readsUsageJSONLedgerWhenUpdatesCarryNoUsage() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = """
            {"info": {"id": "sess-ledger", "cwd": "/Users/demo/Projects/my-app"}, \
            "created_at": "2026-09-20T02:16:15.000Z", "updated_at": "2026-09-20T02:20:00.000Z", \
            "current_model_id": "grok-4.6"}
            """
        let ledger = """
            {"session": {"inputTokens": 1100, "outputTokens": 250, "cachedReadTokens": 720, \
            "cacheCreationTokens": 50, "reasoningTokens": 43, "totalTokens": 1350, "modelCalls": 4}, \
            "turns": [\
            {"turnNumber": 1, "inputTokens": 1000, "outputTokens": 200, "cachedReadTokens": 700, \
            "cacheCreationTokens": 50, "reasoningTokens": 33, "totalTokens": 1200, "modelCalls": 2, \
            "modelUsage": {"grok-4.6-build": {"inputTokens": 1000, "outputTokens": 200, \
            "cachedReadTokens": 700, "cacheCreationTokens": 50, "reasoningTokens": 33, "modelCalls": 2}}}, \
            {"turnNumber": 2, "inputTokens": 100, "outputTokens": 50, "cachedReadTokens": 20, \
            "cacheCreationTokens": 0, "reasoningTokens": 10, "totalTokens": 150, "modelCalls": 2}]}
            """
        try makeSession(in: root, group: "%2FUsers%2Fdemo%2FProjects%2Fmy-app", id: "sess-ledger",
                        summary: summary, updates: [
                            updateLine(kind: "user_message_chunk", timestamp: 1_790_000_000),
                            updateLine(kind: "turn_completed", timestamp: 1_790_000_010),
                            updateLine(kind: "user_message_chunk", timestamp: 1_790_001_900),
                            updateLine(kind: "turn_completed", timestamp: 1_790_002_000),
                        ], usageLedger: ledger)

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(result.entries.count == 2)
        // A turn carrying modelUsage is attributed to the model it names; a
        // turn without one falls back to the summary's current_model_id.
        let byModel = Dictionary(grouping: result.entries, by: \.model)
        // cacheCreationTokens folds into input before cache reads come out:
        // input = (1000 + 50) - 700, output = 200 - 33.
        let build = try #require(byModel["grok-4.6-build"]?.first)
        #expect(build.inputTokens == 350)
        #expect(build.cachedInputTokens == 700)
        #expect(build.outputTokens == 167)
        #expect(build.reasoningOutputTokens == 33)
        let fallback = try #require(byModel["grok-4.6"]?.first)
        #expect(fallback.inputTokens == 80)
        #expect(fallback.outputTokens == 40)
        #expect(fallback.cachedInputTokens == 20)
        #expect(fallback.reasoningOutputTokens == 10)
        // Ledger records pair with the session's turn_completed timestamps by
        // order (the ledger itself has no timestamps).
        #expect(build.timestamp == Date(timeIntervalSince1970: 1_790_000_010))
        #expect(fallback.timestamp == Date(timeIntervalSince1970: 1_790_002_000))
        #expect(result.entries.allSatisfy { $0.project == "my-app" })
    }

    // Same turn present in both places: the ACP copy is authoritative (it has
    // the timestamp and model), so the ledger must not add a second entry.
    @Test func usageJSONIsIgnoredWhenUpdatesAlreadyCarryUsage() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = #", "usage": {"inputTokens": 100, "outputTokens": 50, "cachedReadTokens": 20, "reasoningTokens": 10}"#
        let ledger = """
            {"turns": [{"turnNumber": 1, "inputTokens": 100, "outputTokens": 50, \
            "cachedReadTokens": 20, "cacheCreationTokens": 0, "reasoningTokens": 10, "modelCalls": 1}]}
            """
        try makeSession(in: root, group: "%2Ftmp%2Fboth", id: "sess-both", summary: nil, updates: [
            updateLine(kind: "turn_completed", timestamp: 1_790_000_010, extra: usage),
        ], usageLedger: ledger)

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.inputTokens == 80)
        #expect(entry.outputTokens == 40)
        #expect(entry.cachedInputTokens == 20)
        #expect(entry.reasoningOutputTokens == 10)
    }

    // Canary for the next format move: signals.json reports completed turns
    // but neither source yields usage. The JS parser returns a `warnings`
    // entry; here it logs via OSLog (not observable), so assert the data side:
    // no entries, no skipped flag, and the session's events still land.
    @Test func signalsCanarySessionYieldsNoEntriesButKeepsEvents() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = """
            {"info": {"cwd": "/tmp/canary"}, "created_at": "2026-09-20T02:16:15.000Z", \
            "updated_at": "2026-09-20T02:20:00.000Z", "current_model_id": "grok-4.6"}
            """
        let signals = #"{"turnCount": 2, "modelsUsed": ["grok-4.6"], "primaryModelId": "grok-4.6"}"#
        try makeSession(in: root, group: "g", id: "sess-canary", summary: summary, updates: [
            updateLine(kind: "turn_completed", timestamp: 1_790_000_010),
        ], signals: signals)

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        #expect(result.entries.isEmpty)
        #expect(result.skipped == false)
        #expect(result.events.map(\.role) == [.assistant])
    }

    // A ledger without a turns array falls back to the session totals record,
    // and with no turn_completed timestamps available it takes the summary's
    // updated_at as its timestamp.
    @Test func ledgerSessionTotalsPairWithSummaryTimestamp() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = """
            {"info": {"cwd": "/tmp/totals"}, "created_at": "2026-09-20T02:16:15.000Z", \
            "updated_at": "2026-09-20T02:20:00.000Z", "current_model_id": "grok-4.6"}
            """
        let ledger = """
            {"session": {"inputTokens": 1100, "outputTokens": 250, "cachedReadTokens": 720, \
            "cacheCreationTokens": 50, "reasoningTokens": 43}}
            """
        try makeSession(in: root, group: "g", id: "sess-totals", summary: summary,
                        usageLedger: ledger)

        let result = try VibeGrokParser(sessionRoots: [root.path]).parse()
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.model == "grok-4.6")
        #expect(entry.inputTokens == 1150 - 720) // (1100 + 50 folded) - cache reads
        #expect(entry.outputTokens == 250 - 43)
        #expect(entry.timestamp == VibeSyncTime.parse("2026-09-20T02:20:00.000Z"))
    }

    // usage.json is part of the session fingerprint: a ledger landing after
    // the first scan must be picked up, not hidden behind the cache.
    @Test func cacheInvalidatesWhenUsageJSONAppears() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSession(in: root, group: "g", id: "sess-cache", summary: nil, updates: [
            updateLine(kind: "turn_completed", timestamp: 1_790_000_010),
        ])
        let parser = VibeGrokParser(sessionRoots: [root.path])
        #expect(try parser.parse().entries.isEmpty)

        let ledger = """
            {"turns": [{"turnNumber": 1, "inputTokens": 42, "outputTokens": 7, \
            "cachedReadTokens": 2, "reasoningTokens": 1}]}
            """
        try ledger.write(to: directory.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)

        let result = try parser.parse()
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.inputTokens == 40)
        #expect(entry.timestamp == Date(timeIntervalSince1970: 1_790_000_010))
    }
}
