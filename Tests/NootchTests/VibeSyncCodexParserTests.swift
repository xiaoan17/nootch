import Foundation
import Testing
@testable import Nootch

// Fixture JSONL mirrors the Codex rollout shapes exercised by vibe-usage's
// src/parsers/codex.js: session_meta, turn_context, event_msg/token_count,
// task_started, forks and sub-agent copies.

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func writeRollout(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func sessionMeta(
    id: String, timestamp: String, cwd: String? = nil, gitURL: String? = nil,
    forkedFrom: String? = nil, source: Any? = nil, parentThreadId: String? = nil
) -> [String: Any] {
    var payload: [String: Any] = ["id": id, "timestamp": timestamp, "originator": "codex-tui"]
    if let cwd { payload["cwd"] = cwd }
    if let gitURL { payload["git"] = ["repository_url": gitURL] }
    if let forkedFrom { payload["forked_from_id"] = forkedFrom }
    if let source { payload["source"] = source }
    if let parentThreadId { payload["parent_thread_id"] = parentThreadId }
    return ["timestamp": timestamp, "type": "session_meta", "payload": payload]
}

private func turnContext(_ timestamp: String, model: String? = nil, serviceTier: String? = nil) -> [String: Any] {
    var payload: [String: Any] = [:]
    if let model { payload["model"] = model }
    if let serviceTier { payload["service_tier"] = serviceTier }
    return ["timestamp": timestamp, "type": "turn_context", "payload": payload]
}

private func usageDict(input: Double, output: Double, cached: Double, reasoning: Double) -> [String: Any] {
    [
        "input_tokens": input,
        "output_tokens": output,
        "cached_input_tokens": cached,
        "reasoning_output_tokens": reasoning,
        "total_tokens": input + output,
    ]
}

private func tokenCount(
    _ timestamp: String, total: [String: Any], last: [String: Any]? = nil, model: String? = nil
) -> [String: Any] {
    var info: [String: Any] = ["total_token_usage": total]
    if let last { info["last_token_usage"] = last }
    if let model { info["model"] = model }
    return ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "token_count", "info": info]]
}

private func responseItem(_ timestamp: String) -> [String: Any] {
    ["timestamp": timestamp, "type": "response_item", "payload": ["type": "message", "role": "assistant"]]
}

private func utc(_ string: String) -> Date {
    try! Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

@Test func codexParsesTokenCountWithNormalizedFields() throws {
    let root = try makeTempDirectory()
    let file = root.appendingPathComponent("sessions/2026/09/06/rollout-a.jsonl")
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-1", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/Users/x/projects/demo")),
        jsonLine(turnContext("2026-09-06T10:00:05.000Z", model: "gpt-5.6-sol")),
        jsonLine(responseItem("2026-09-06T10:00:08.000Z")),
        jsonLine(tokenCount(
            "2026-09-06T10:00:10.000Z",
            total: usageDict(input: 1000, output: 200, cached: 600, reasoning: 50),
            last: usageDict(input: 1000, output: 200, cached: 600, reasoning: 50),
            model: "gpt-5.6-sol")),
    ], to: file)

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(!result.skipped)
    #expect(result.entries.count == 1)
    let entry = try #require(result.entries.first)
    #expect(entry.source == "codex")
    #expect(entry.model == "gpt-5.6-sol")
    #expect(entry.project == "demo")
    #expect(entry.timestamp == utc("2026-09-06T10:00:10.000Z"))
    // input_tokens includes cached, output_tokens includes reasoning.
    #expect(entry.inputTokens == 400)
    #expect(entry.outputTokens == 150)
    #expect(entry.cachedInputTokens == 600)
    #expect(entry.reasoningOutputTokens == 50)

    // session_meta + turn_context are user-turn events; others assistant.
    #expect(result.events.map(\.role) == [.user, .user, .assistant, .assistant])
    #expect(Set(result.events.map(\.sessionId)) == ["sess-1"])
    #expect(result.events.allSatisfy { $0.source == "codex" && $0.project == "demo" })
}

@Test func codexCumulativeDeltaFallbackAndReset() throws {
    let root = try makeTempDirectory()
    let file = root.appendingPathComponent("sessions/rollout-b.jsonl")
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-2", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/x/demo")),
        // First cumulative entry is used as-is.
        jsonLine(tokenCount("2026-09-06T10:01:00.000Z",
                            total: usageDict(input: 100, output: 10, cached: 20, reasoning: 5))),
        // Second entry emits the delta.
        jsonLine(tokenCount("2026-09-06T10:02:00.000Z",
                            total: usageDict(input: 300, output: 40, cached: 100, reasoning: 15))),
        // Counter reset (compaction): negative delta → fresh baseline.
        jsonLine(tokenCount("2026-09-06T10:03:00.000Z",
                            total: usageDict(input: 50, output: 5, cached: 0, reasoning: 0))),
    ], to: file)

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.entries.count == 3)
    #expect(result.entries[0].inputTokens == 80)
    #expect(result.entries[0].cachedInputTokens == 20)
    #expect(result.entries[0].outputTokens == 5)
    #expect(result.entries[0].reasoningOutputTokens == 5)
    #expect(result.entries[1].inputTokens == 120)
    #expect(result.entries[1].cachedInputTokens == 80)
    #expect(result.entries[1].outputTokens == 20)
    #expect(result.entries[1].reasoningOutputTokens == 10)
    #expect(result.entries[2].inputTokens == 50)
    #expect(result.entries[2].outputTokens == 5)
}

@Test func codexDuplicateEmissionCountsOnce() throws {
    let root = try makeTempDirectory()
    let file = root.appendingPathComponent("sessions/rollout-c.jsonl")
    let record = tokenCount(
        "2026-09-06T10:01:00.000Z",
        total: usageDict(input: 500, output: 100, cached: 100, reasoning: 0),
        last: usageDict(input: 500, output: 100, cached: 100, reasoning: 0))
    var duplicate = record
    duplicate["timestamp"] = "2026-09-06T10:01:01.000Z"
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-3", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/x/demo")),
        jsonLine(record),
        jsonLine(duplicate),
    ], to: file)

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.entries.count == 1)
    // The duplicate is still an assistant timing event, just not an entry.
    #expect(result.events.filter { $0.role == .assistant }.count == 2)
}

@Test func codexServiceTierDecoratesModelOnlyAfterAttributionStart() throws {
    let root = try makeTempDirectory()
    let file = root.appendingPathComponent("sessions/rollout-d.jsonl")
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-4", timestamp: "2026-08-30T10:00:00.000Z", cwd: "/x/demo")),
        jsonLine(turnContext("2026-08-30T10:00:05.000Z", model: "gpt-5.6-sol", serviceTier: "priority")),
        jsonLine(tokenCount("2026-08-30T10:01:00.000Z",
                            total: usageDict(input: 10, output: 5, cached: 0, reasoning: 0),
                            last: usageDict(input: 10, output: 5, cached: 0, reasoning: 0))),
        jsonLine(tokenCount("2026-09-01T10:01:00.000Z",
                            total: usageDict(input: 20, output: 10, cached: 0, reasoning: 0),
                            last: usageDict(input: 10, output: 5, cached: 0, reasoning: 0))),
    ], to: file)

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.entries.map(\.model) == ["gpt-5.6-sol", "gpt-5.6-sol-priority"])
}

@Test func codexForkReplayIsDeduplicated() throws {
    let root = try makeTempDirectory()
    let parentA = tokenCount("2026-09-06T10:01:00.000Z",
                             total: usageDict(input: 100, output: 10, cached: 0, reasoning: 0),
                             last: usageDict(input: 100, output: 10, cached: 0, reasoning: 0))
    let parentB = tokenCount("2026-09-06T10:02:00.000Z",
                             total: usageDict(input: 200, output: 20, cached: 0, reasoning: 0),
                             last: usageDict(input: 100, output: 10, cached: 0, reasoning: 0))
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-parent", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/x/demo")),
        jsonLine(parentA),
        jsonLine(parentB),
    ], to: root.appendingPathComponent("sessions/rollout-parent.jsonl"))

    // The fork copies the parent's token records verbatim under fresh outer
    // timestamps, then appends its own usage.
    var copiedA = parentA
    copiedA["timestamp"] = "2026-09-07T09:00:01.000Z"
    var copiedB = parentB
    copiedB["timestamp"] = "2026-09-07T09:00:02.000Z"
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-child", timestamp: "2026-09-07T09:00:00.000Z",
                             cwd: "/x/demo", forkedFrom: "sess-parent")),
        jsonLine(copiedA),
        jsonLine(copiedB),
        jsonLine(tokenCount("2026-09-07T09:05:00.000Z",
                            total: usageDict(input: 500, output: 50, cached: 0, reasoning: 0),
                            last: usageDict(input: 300, output: 30, cached: 0, reasoning: 0))),
    ], to: root.appendingPathComponent("sessions/rollout-child.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    // Parent contributes its two records, the fork only its own new usage.
    #expect(result.entries.count == 3)
    let childEntries = result.entries.filter { $0.timestamp >= utc("2026-09-07T00:00:00.000Z") }
    #expect(childEntries.count == 1)
    #expect(childEntries.first?.inputTokens == 300)
    // Copied parent history must not inflate the child's session timing.
    #expect(!result.events.contains { $0.sessionId == "sess-child" && $0.timestamp < utc("2026-09-07T00:00:00.000Z") })
}

@Test func codexSubagentReplayIsDeduplicated() throws {
    let root = try makeTempDirectory()
    let parentRecord = tokenCount("2026-09-06T10:01:00.000Z",
                                  total: usageDict(input: 100, output: 10, cached: 0, reasoning: 0),
                                  last: usageDict(input: 100, output: 10, cached: 0, reasoning: 0))
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-main", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/x/demo")),
        jsonLine(parentRecord),
    ], to: root.appendingPathComponent("sessions/rollout-main.jsonl"))

    var copied = parentRecord
    copied["timestamp"] = "2026-09-06T11:00:01.000Z"
    try writeRollout([
        jsonLine(sessionMeta(
            id: "sess-sub", timestamp: "2026-09-06T11:00:00.000Z", cwd: "/x/demo",
            source: ["subagent": ["thread_spawn": ["parent_thread_id": "sess-main"]]])),
        jsonLine(copied),
        jsonLine(tokenCount("2026-09-06T11:10:00.000Z",
                            total: usageDict(input: 400, output: 40, cached: 0, reasoning: 0),
                            last: usageDict(input: 300, output: 30, cached: 0, reasoning: 0))),
    ], to: root.appendingPathComponent("sessions/rollout-sub.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.entries.count == 2)
    #expect(result.entries.map(\.inputTokens).sorted() == [100, 300])
}

@Test func codexLiveAndArchiveCopiesAreDeduplicated() throws {
    let root = try makeTempDirectory()
    let meta = sessionMeta(id: "sess-dupe", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/x/demo")
    let first = tokenCount("2026-09-06T10:01:00.000Z",
                           total: usageDict(input: 100, output: 10, cached: 0, reasoning: 0),
                           last: usageDict(input: 100, output: 10, cached: 0, reasoning: 0))
    let second = tokenCount("2026-09-06T10:02:00.000Z",
                            total: usageDict(input: 200, output: 20, cached: 0, reasoning: 0),
                            last: usageDict(input: 100, output: 10, cached: 0, reasoning: 0))
    // Live copy is shorter; the archived copy is the complete one.
    try writeRollout([jsonLine(meta), jsonLine(first)],
                     to: root.appendingPathComponent("sessions/rollout-dupe.jsonl"))
    try writeRollout([jsonLine(meta), jsonLine(first), jsonLine(second)],
                     to: root.appendingPathComponent("archived_sessions/rollout-dupe.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.entries.count == 2)
    #expect(result.events.filter { $0.sessionId == "sess-dupe" && $0.role == .user }.count == 1)
}

@Test func codexCorruptAndBlankLinesAreSkipped() throws {
    let root = try makeTempDirectory()
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-bad", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/x/demo")),
        "not json at all {{{",
        "",
        "{\"type\":\"event_msg\",\"payload\":",
        jsonLine(tokenCount("2026-09-06T10:01:00.000Z",
                            total: usageDict(input: 42, output: 7, cached: 2, reasoning: 1),
                            last: usageDict(input: 42, output: 7, cached: 2, reasoning: 1))),
    ], to: root.appendingPathComponent("sessions/rollout-bad.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.entries.count == 1)
    #expect(result.entries.first?.inputTokens == 40)
}

@Test func codexMissingAndEmptyDirectoriesYieldEmptyResult() throws {
    let missing = try makeTempDirectory().appendingPathComponent("nope")
    let missingResult = try VibeSyncCodexParser(codexHome: missing.path).parse()
    #expect(missingResult.entries.isEmpty && missingResult.events.isEmpty)
    #expect(!missingResult.skipped)

    let empty = try makeTempDirectory()
    try FileManager.default.createDirectory(at: empty.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let emptyResult = try VibeSyncCodexParser(codexHome: empty.path).parse()
    #expect(emptyResult.entries.isEmpty && emptyResult.events.isEmpty)
    #expect(!emptyResult.skipped)
}

@Test func codexProjectExtraction() throws {
    let root = try makeTempDirectory()
    let usage = usageDict(input: 1, output: 1, cached: 0, reasoning: 0)
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-git", timestamp: "2026-09-06T10:00:00.000Z",
                             cwd: "/x/wrong", gitURL: "https://github.com/org/repo.git")),
        jsonLine(tokenCount("2026-09-06T10:01:00.000Z", total: usage, last: usage)),
    ], to: root.appendingPathComponent("sessions/rollout-git.jsonl"))
    try writeRollout([
        jsonLine(["timestamp": "2026-09-06T10:00:00.000Z", "type": "session_meta",
                  "payload": ["timestamp": "2026-09-06T10:00:00.000Z"]]),
        jsonLine(tokenCount("2026-09-06T10:01:00.000Z", total: usage, last: usage)),
    ], to: root.appendingPathComponent("sessions/rollout-nometa.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.entries.count == 2)
    let byModel = result.entries.map(\.project)
    #expect(byModel.contains("org/repo"))
    #expect(byModel.contains("unknown"))
}

@Test func codexChangedFileIsReparsedUnchangedIsCached() throws {
    let root = try makeTempDirectory()
    let file = root.appendingPathComponent("sessions/rollout-live.jsonl")
    let parser = VibeSyncCodexParser(codexHome: root.path)
    try writeRollout([
        jsonLine(sessionMeta(id: "sess-live", timestamp: "2026-09-06T10:00:00.000Z", cwd: "/x/demo")),
        jsonLine(tokenCount("2026-09-06T10:01:00.000Z",
                            total: usageDict(input: 10, output: 1, cached: 0, reasoning: 0),
                            last: usageDict(input: 10, output: 1, cached: 0, reasoning: 0))),
    ], to: file)
    #expect(try parser.parse().entries.count == 1)

    // Append a record and bump the mtime so the signature changes.
    let appended = tokenCount("2026-09-06T10:02:00.000Z",
                              total: usageDict(input: 25, output: 3, cached: 0, reasoning: 0),
                              last: usageDict(input: 15, output: 2, cached: 0, reasoning: 0))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((jsonLine(appended) + "\n").utf8))
    try handle.close()
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

    let result = try parser.parse()
    #expect(result.entries.count == 2)
    #expect(result.entries.map(\.inputTokens).sorted() == [10, 15])
}

// MARK: - Continuation segments (upstream 84d007b, issue #94)
//
// Codex can split one session into disjoint continuation rollouts sharing a
// session id. The Swift fixture helpers differ from upstream's: tokenCount
// takes total:/last: dictionaries and usageDict is (input, output, cached,
// reasoning).

/// Upstream tokenCount(ts, usage, total): last_token_usage + a cumulative
/// total carrying only total_tokens.
private func segmentToken(_ timestamp: String, input: Double, total: Double) -> [String: Any] {
    tokenCount(timestamp, total: ["total_tokens": total],
               last: usageDict(input: input, output: 0, cached: 0, reasoning: 0))
}

@Test func codexContinuationSegmentsAreMergedAcrossFiles() throws {
    let root = try makeTempDirectory()
    let t = "2026-09-06T00:00:00.000Z"
    let header = [
        jsonLine(sessionMeta(id: "segments", timestamp: t)),
        jsonLine(turnContext(t, model: "test-model")),
    ]
    // The active continuation (b) is shorter than the older segment (a); the
    // old "most complete copy wins" rule dropped its usage entirely.
    try writeRollout(header + [
        jsonLine(segmentToken("2026-09-06T00:01:00.000Z", input: 10, total: 10)),
        jsonLine(segmentToken("2026-09-06T00:02:00.000Z", input: 10, total: 20)),
    ], to: root.appendingPathComponent("sessions/rollout-a.jsonl"))
    try writeRollout(header + [
        jsonLine(segmentToken("2026-09-06T00:03:00.000Z", input: 10, total: 30)),
    ], to: root.appendingPathComponent("sessions/rollout-b.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(!result.skipped)
    #expect(result.entries.map(\.inputTokens).reduce(0, +) == 30)
    // One logical session across both physical files.
    #expect(Set(result.events.map(\.sessionId)) == ["segments"])
}

@Test func codexOverlappingSegmentsPreserveCumulativeBaselinesAndResets() throws {
    let root = try makeTempDirectory()
    let t = "2026-09-06T00:00:00.000Z"
    let header = [
        jsonLine(sessionMeta(id: "segments", timestamp: t)),
        jsonLine(turnContext(t, model: "test-model")),
    ]
    // Cumulative-only records (no last_token_usage): the merged baseline chain
    // must survive the overlap, the archived copy, and the counter reset.
    func total(_ minute: Int, _ input: Double) -> String {
        jsonLine(tokenCount("2026-09-06T00:0\(minute):00.000Z",
                            total: usageDict(input: input, output: 0, cached: 0, reasoning: 0)))
    }
    let a = total(1, 10), b = total(2, 20), c = total(3, 30), reset = total(4, 5), next = total(5, 8)
    try writeRollout(header + [a, b], to: root.appendingPathComponent("sessions/rollout-a.jsonl"))
    try writeRollout(header + [b, c, reset, next], to: root.appendingPathComponent("sessions/rollout-b.jsonl"))
    try writeRollout(header + [a, b], to: root.appendingPathComponent("archived_sessions/rollout-copy.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(!result.skipped)
    // 10 (first total as-is) + 10 (delta) + 10 (delta) + 5 (reset baseline) + 3 (delta).
    #expect(result.entries.map(\.inputTokens).reduce(0, +) == 38)
    #expect(Set(result.events.map(\.sessionId)) == ["segments"])
}

@Test func codexSegmentModelAndTierContextsSurviveFileNameReversal() throws {
    let t = "2026-09-06T00:00:00.000Z"
    // One segment carries model-a/priority, the other model-b/flex; each
    // token_count keeps the context in effect where it was written, whichever
    // member file sorts first.
    func parse(_ root: URL, _ files: [(name: String, model: String, tier: String, minute: Int, total: Double)]) throws -> VibeParseResult {
        for file in files {
            try writeRollout([
                jsonLine(sessionMeta(id: "segments", timestamp: t)),
                jsonLine(turnContext(t, model: file.model, serviceTier: file.tier)),
                jsonLine(tokenCount("2026-09-06T00:0\(file.minute):00.000Z",
                                    total: usageDict(input: file.total, output: 0, cached: 0, reasoning: 0),
                                    last: usageDict(input: 10, output: 0, cached: 0, reasoning: 0))),
            ], to: root.appendingPathComponent("sessions/rollout-\(file.name).jsonl"))
        }
        return try VibeSyncCodexParser(codexHome: root.path).parse()
    }
    let first = try parse(try makeTempDirectory(),
                          [(name: "a", model: "model-a", tier: "priority", minute: 1, total: 10),
                           (name: "b", model: "model-b", tier: "flex", minute: 2, total: 20)])
    let reversed = try parse(try makeTempDirectory(),
                             [(name: "b", model: "model-a", tier: "priority", minute: 1, total: 10),
                              (name: "a", model: "model-b", tier: "flex", minute: 2, total: 20)])
    #expect(first.entries == reversed.entries)
    #expect(first.events == reversed.events)
    #expect(first.entries.first { $0.model == "model-a-priority" }?.inputTokens == 10)
    #expect(first.entries.first { $0.model == "model-b-flex" }?.inputTokens == 10)
}

@Test func codexCrossFileDedupRetainsSingleFileRepetitions() throws {
    let root = try makeTempDirectory()
    let t = "2026-09-06T00:00:00.000Z"
    let meta = jsonLine(sessionMeta(id: "segments", timestamp: t))
    let repeated = jsonLine(segmentToken(t, input: 10, total: 0))
    let later = jsonLine(segmentToken("2026-09-06T00:01:00.000Z", input: 10, total: 0))
    // Occurrence N in one file matches occurrence N in the other: the two
    // in-file repetitions both survive, the cross-file copy collapses.
    try writeRollout([meta, repeated, repeated], to: root.appendingPathComponent("sessions/rollout-a.jsonl"))
    try writeRollout([meta, repeated, later], to: root.appendingPathComponent("sessions/rollout-b.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(!result.skipped)
    #expect(result.entries.map(\.inputTokens).reduce(0, +) == 30)
}

@Test func codexForkReplayMatchesParentSpreadOverContinuationFiles() throws {
    let root = try makeTempDirectory()
    let t = "2026-09-06T00:00:00.000Z"
    let a = segmentToken("2026-09-06T00:01:00.000Z", input: 10, total: 10)
    let b = segmentToken("2026-09-06T00:02:00.000Z", input: 10, total: 20)
    let childTime = "2026-09-06T00:03:00.000Z"
    var copiedA = a, copiedB = b
    copiedA["timestamp"] = childTime
    copiedB["timestamp"] = childTime
    let child = [
        jsonLine(sessionMeta(id: "child", timestamp: childTime, forkedFrom: "parent")),
        jsonLine(copiedA), jsonLine(copiedB),
        jsonLine(segmentToken("2026-09-06T00:04:00.000Z", input: 5, total: 25)),
    ]
    try writeRollout([jsonLine(sessionMeta(id: "parent", timestamp: t)), jsonLine(a)],
                     to: root.appendingPathComponent("sessions/rollout-a.jsonl"))
    try writeRollout([jsonLine(sessionMeta(id: "parent", timestamp: t)), jsonLine(b)],
                     to: root.appendingPathComponent("sessions/rollout-b.jsonl"))
    try writeRollout(child, to: root.appendingPathComponent("sessions/rollout-child.jsonl"))
    try writeRollout(child, to: root.appendingPathComponent("archived_sessions/rollout-child-copy.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(!result.skipped)
    // Parent 10 + 10; the fork contributes only its own 5 — the replay prefix
    // matches against the parent's MERGED fingerprint sequence.
    #expect(result.entries.map(\.inputTokens).reduce(0, +) == 25)
    #expect(Set(result.events.map(\.sessionId)) == ["parent", "child"])
}

@Test func codexSegmentedSessionMatchesUnsplitTranscript() throws {
    let t = "2026-09-06T00:00:00.000Z"
    let meta = jsonLine(sessionMeta(id: "segments", timestamp: t, cwd: "/x/demo"))
    let a = jsonLine(tokenCount("2026-09-06T00:01:00.000Z", total: ["total_tokens": 14],
                                last: usageDict(input: 10, output: 4, cached: 3, reasoning: 1)))
    // Chat text is dropped from merged records; only type/timestamp survive,
    // which is all the timing pass reads.
    let chat = jsonLine([
        "timestamp": "2026-09-06T00:02:00.000Z",
        "type": "response_item",
        "payload": ["role": "assistant", "content": [["text": "PRIVATE_SEGMENT_CHAT_SENTINEL"]]],
    ] as [String: Any])
    let b = jsonLine(tokenCount("2026-09-06T00:03:00.000Z", total: ["total_tokens": 42],
                                last: usageDict(input: 20, output: 8, cached: 6, reasoning: 2)))

    let wholeRoot = try makeTempDirectory()
    try writeRollout([meta, a, chat, b], to: wholeRoot.appendingPathComponent("sessions/rollout-whole.jsonl"))
    let expected = try VibeSyncCodexParser(codexHome: wholeRoot.path).parse()

    let splitRoot = try makeTempDirectory()
    try writeRollout([meta, a, chat], to: splitRoot.appendingPathComponent("sessions/rollout-a.jsonl"))
    try writeRollout([meta, chat, b], to: splitRoot.appendingPathComponent("sessions/rollout-b.jsonl"))
    let result = try VibeSyncCodexParser(codexHome: splitRoot.path).parse()

    #expect(!result.skipped)
    #expect(result.entries == expected.entries)
    #expect(result.events == expected.events)
}

@Test func codexConflictingSegmentOrderSkipsSource() throws {
    let root = try makeTempDirectory()
    let t = "2026-09-06T00:00:00.000Z"
    let meta = jsonLine(sessionMeta(id: "segments", timestamp: t))
    // Same timestamps, distinct payloads, contradictory order across the two
    // copies: skip the source instead of inventing a possibly
    // double-counting sequence.
    let a = jsonLine(segmentToken(t, input: 10, total: 10))
    let b = jsonLine(segmentToken(t, input: 10, total: 20))
    try writeRollout([meta, a, b], to: root.appendingPathComponent("sessions/rollout-a.jsonl"))
    try writeRollout([meta, b, a], to: root.appendingPathComponent("sessions/rollout-b.jsonl"))

    let result = try VibeSyncCodexParser(codexHome: root.path).parse()
    #expect(result.skipped)
    #expect(result.entries.isEmpty)
    #expect(result.events.isEmpty)
}

@Test func codexSegmentCacheFollowsAppendsAndMemberRemoval() throws {
    let root = try makeTempDirectory()
    let parser = VibeSyncCodexParser(codexHome: root.path)
    let t = "2026-09-06T00:00:00.000Z"
    let meta = jsonLine(sessionMeta(id: "segments", timestamp: t))
    let fileA = root.appendingPathComponent("sessions/rollout-a.jsonl")
    let fileB = root.appendingPathComponent("sessions/rollout-b.jsonl")
    try writeRollout([meta, jsonLine(segmentToken(t, input: 10, total: 10))], to: fileA)
    try writeRollout([meta, jsonLine(segmentToken("2026-09-06T00:01:00.000Z", input: 10, total: 20))], to: fileB)

    func inputSum() throws -> Double {
        try parser.parse().entries.map(\.inputTokens).reduce(0, +)
    }
    func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    }

    #expect(try inputSum() == 20)
    // A re-parse over unchanged files comes entirely from the cache.
    #expect(try parser.parse() == parser.parse())

    try append(jsonLine(segmentToken("2026-09-06T00:02:00.000Z", input: 10, total: 30)), to: fileB)
    #expect(try inputSum() == 30)
    try append(jsonLine(segmentToken("2026-09-06T00:03:00.000Z", input: 10, total: 40)), to: fileA)
    #expect(try inputSum() == 40)

    // Removing one member leaves the other as a standalone session.
    try FileManager.default.removeItem(at: fileB)
    #expect(try inputSum() == 20)
}

@Test func codexUnreadableContinuationSuppressesPartialResults() throws {
    // POSIX chmod fixture; root bypasses the denial.
    guard getuid() != 0 else { return }
    let root = try makeTempDirectory()
    let parser = VibeSyncCodexParser(codexHome: root.path)
    let t = "2026-09-06T00:00:00.000Z"
    let meta = jsonLine(sessionMeta(id: "segments", timestamp: t))
    let fileA = root.appendingPathComponent("sessions/rollout-a.jsonl")
    let fileB = root.appendingPathComponent("sessions/rollout-b.jsonl")
    try writeRollout([meta, jsonLine(segmentToken(t, input: 10, total: 10))], to: fileA)
    try writeRollout([meta, jsonLine(segmentToken("2026-09-06T00:01:00.000Z", input: 10, total: 20))], to: fileB)

    // An unreadable member may hide part of the session: the readable
    // remainder must never upload as the complete total (upstream 84d007b —
    // its test disables the disk cache to force the re-read; here the denial
    // applies from the first, cold parse instead).
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileB.path)
    let failed = try parser.parse()
    #expect(failed.skipped)
    #expect(failed.entries.isEmpty)
    #expect(failed.events.isEmpty)

    // The denial is transient: once readable again, the session parses whole.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileB.path)
    #expect(try parser.parse().entries.map(\.inputTokens).reduce(0, +) == 20)
}
