import Foundation
import Testing
@testable import Nootch

@Suite struct VibeSyncRemainingParserTests {
    typealias P = VibeParserSupport
    func write(_ value: Any, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
    func jsonl(_ values: [[String: Any]]) throws -> String {
        try values.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }
    @Test func registryContainsAll34AgreedSourcesExactlyOnce() async {
        let expected = Set("claude-code codearts-agent codex cola grok copilot-cli craft-agent cursor dimagent gemini-cli opencode openclaw omp pi-coding-agent qoder qoder-cn qwen-code kimi-code amp alma droid dsh antigravity trae-cli hermes kiro mcode mimocode cline roo-code workbuddy zcode devin codebuddy".split(separator: " ").map(String.init))
        let sources = VibeSyncEngine.defaultParsers().map(\.source)
        #expect(sources.count == expected.count)
        #expect(Set(sources) == expected)
        #expect(Set(await VibeSyncEngine.shared.parsers.map(\.source)) == expected)
    }
    @Test func heterogeneousParserResultsRetainEverySource() async throws {
        let dir = makeTempDirectory("heterogeneous-parsers")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["apiKey": "fixture-only", "hostname": "test"], dir.path + "/config.json")
        let parsers: [any VibeLogParser] = [VibeSyncAmpParser(threadsDir: dir.path + "/absent"),
            VibeSyncDshParser(sessionsDir: dir.path + "/absent"), VibeSyncClineParser(roots: [], sessionDirs: []),
            VibeSyncCursorParser(dbPath: dir.path + "/absent")]
        let engine = VibeSyncEngine(parsers: parsers, configPath: dir.path + "/config.json", dataLoader: { request in
            (Data(#"{"uploadProject":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let report = await engine.sync(dryRun: true)
        #expect(report.status == .dryRun)
        #expect(report.okSources == ["amp", "cline", "cursor", "dsh"])
        #expect(report.failedSources.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/state.json"))
    }
    @Test func ampLedgerWinsOverMessageUsageAndRecoversTimes() throws {
        let dir = makeTempDirectory("amp-port"); defer { try? FileManager.default.removeItem(at: dir) }
        try write(["id": "T-1", "created": "2026-01-01T00:00:00Z", "messages": [["role": "user"], ["role": "assistant", "usage": ["inputTokens": 999, "cacheReadInputTokens": 30, "cacheCreationInputTokens": 7]]], "usageLedger": ["events": [["timestamp": "2026-01-01T01:00:00Z", "fromMessageId": 0, "toMessageId": 1, "model": "claude-sonnet-4", "tokens": ["input": 100, "output": 20]]]]], dir.path + "/T-1.json")
        let r = try VibeSyncAmpParser(threadsDir: dir.path).parse()
        #expect(r.entries.count == 1); #expect(r.entries[0].inputTokens == 107)
        #expect(r.entries[0].cachedInputTokens == 30); #expect(r.events.count == 2)
        #expect(r.events[0].timestamp == P.date("2026-01-01T01:00:00Z"))
    }
    @Test func clineLegacyCopiesSelectRicherUsageAndRooFindsPerTaskHistory() throws {
        let dir = makeTempDirectory("cline-port"); defer { try? FileManager.default.removeItem(at: dir) }
        for root in ["a", "b"] {
            try write([["id": "t", "ulid": "same", "cwd": "/private/project", "modelId": "fallback"]], dir.path + "/\(root)/state/taskHistory.json")
            let text = "{\"tokensIn\":10,\"tokensOut\":20,\"cacheWrites\":3,\"cacheReads\":5,\"model\":\"actual\"}"
            var rows: [[String: Any]] = [["ts": 1767225600000, "type": "say", "say": "api_req_started", "text": text]]
            if root == "b" { rows.insert(["ts": 1767225590000, "type": "ask"], at: 0) }
            try write(rows, dir.path + "/\(root)/tasks/t/ui_messages.json")
        }
        let r = try VibeSyncClineParser(roots: [dir.path + "/a", dir.path + "/b"], sessionDirs: []).parse()
        #expect(r.entries.count == 1); #expect(r.events.count == 2)
        #expect(r.entries[0].inputTokens == 13); #expect(r.entries[0].model == "actual")
        try write(["id": "t", "workspace": "/repo/roo", "apiConfigName": "fallback"], dir.path + "/b/tasks/t/history_item.json")
        let roo = try VibeSyncClineParser(roo: true, roots: [dir.path + "/b"]).parse()
        #expect(roo.entries[0].source == "roo-code"); #expect(roo.entries[0].project == "roo")
    }
    @Test func clineSDKClampsCacheAndDeduplicatesRestoredMessages() throws {
        let dir = makeTempDirectory("cline-sdk"); defer { try? FileManager.default.removeItem(at: dir) }
        for id in ["original", "restored"] {
            try write(["version": 1, "session_id": id, "started_at": id == "original" ? "2026-01-01T00:00:00Z" : "2026-01-02T00:00:00Z", "cwd": "/repo/" + id], dir.path + "/\(id)/\(id).json")
            try write(["version": 1, "sessionId": id, "agent": "lead", "messages": [
                ["id": "u", "ts": 1767225600000, "role": "user"],
                ["id": "tool", "ts": 1767225600001, "role": "user", "content": [["type": "tool_result"]]],
                ["id": "a", "ts": 1767225601000, "role": "assistant", "modelInfo": ["id": "model"], "metrics": ["inputTokens": 100, "cacheReadTokens": 999, "outputTokens": id == "original" ? 10 : 20]]
            ]], dir.path + "/\(id)/lead.messages.json")
        }
        let r = try VibeSyncClineParser(roots: [], sessionDirs: [dir.path]).parse()
        #expect(r.entries.count == 1); #expect(r.events.count == 2)
        #expect(r.entries[0].inputTokens == 0); #expect(r.entries[0].cachedInputTokens == 100)
        #expect(r.entries[0].outputTokens == 20); #expect(r.entries[0].project == "original")
        try write(["version": 2, "session_id": "restored"], dir.path + "/restored/restored.json")
        let unsupported = try VibeSyncClineParser(roots: [], sessionDirs: [dir.path]).parse()
        #expect(unsupported.skipped); #expect(unsupported.entries.isEmpty)
    }
    @Test func cursorCSVUsesAccountWideIdentityAndRejectsSchemaDrift() {
        let r = VibeSyncCursorParser.parseCSV("Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens\r\n2026-01-01,\"model,fast\",\"1,000\",20,50,10\r\n")
        #expect(r.entries.count == 1); #expect(r.entries[0].inputTokens == 1020)
        let a = VibeAggregation.aggregateToBuckets(r.entries, hostname: "machine-a")
        let b = VibeAggregation.aggregateToBuckets(r.entries, hostname: "machine-b")
        #expect(a == b); #expect(a[0].hostname == "cursor-cloud")
        #expect(VibeAggregation.reaggregateHiddenProjectBuckets(a)[0].hostname == "cursor-cloud")
        #expect(VibeSyncCursorParser.parseCSV("Date,Model,Renamed\n2026-01-01,m,12").skipped)
        #expect(VibeSyncCursorParser.parseCSV("Date,Model,Output Tokens\n2026-01-01,\"unfinished,12").skipped)
    }
    actor Requests { var headers: [String] = []; func add(_ request: URLRequest) { headers.append(request.value(forHTTPHeaderField: "Cookie") ?? "bearer") }; func count() -> Int { headers.count } }
    @Test func cursorRetriesOnlyAuthenticationAndSoftSkipsServerFailure() async throws {
        let dir = makeTempDirectory("cursor-port"); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state.vscdb")
        let db = try SQLiteFixture(at: path, sql: "CREATE TABLE ItemTable(key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','fake.eyJzdWIiOiJhdXRofHVzZXIifQ.sig');")
        defer { db.close() }
        let requests = Requests()
        let parser = VibeSyncCursorParser(dbPath: path.path, loader: { request in
            await requests.add(request)
            let n = await requests.count(), status = n == 1 ? 401 : 200
            return (Data("Date,Model,Output Tokens\n2026-01-01,m,7".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let r = try await parser.parse(); #expect(r.entries[0].outputTokens == 7); #expect(await requests.count() == 2)
        let fail = VibeSyncCursorParser(dbPath: path.path, loader: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await fail.parse().skipped)
    }
    func dshRecords(_ id: String = "parent", version: Int = 4) -> [[String: Any]] {
        [["type": "session", "version": version, "id": id, "cwd": "/repo/project", "isSeeded": false],
         ["type": "user/message", "seq": 1, "time": 1767225600000, "data": ["id": "u", "source": ["kind": "user"]]],
         ["type": "assistant/message", "seq": 2, "time": 1767225601000, "data": ["message": ["id": "a", "source": ["model": "deepseek-v4"]], "usage": ["inputTokens": 100, "cacheWriteTokens": 10, "cacheReadTokens": 20, "outputTokens": 40, "reasoningTokens": 15]]]]
    }
    @Test func dshV4ForkDedupIsEvidenceBasedAndUnknownVersionsSkip() throws {
        let parent = try VibeSyncDshParser.decode(jsonl(dshRecords()), version: 4)
        var records = dshRecords("child")
        records[0]["isSeeded"] = true; records[0]["parentSession"] = "parent"
        records.append(["type": "session/end-seed", "seq": 3, "time": 1767225602000, "data": ["inherited": true]])
        let child = try VibeSyncDshParser.decode(jsonl(records), version: 4)
        #expect(VibeSyncDshParser.replayCount(child, parent) == 2)
        var different = parent; different.messages[1].usage[0] = 111
        #expect(VibeSyncDshParser.replayCount(child, different) == 0)
        #expect(parent.messages[1].usage == [110, 25, 20, 15])
        let dir = makeTempDirectory("dsh-port"); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(atPath: dir.path + "/p/s", withIntermediateDirectories: true)
        try jsonl(dshRecords()).write(toFile: dir.path + "/p/s/session.v4.jsonl", atomically: true, encoding: .utf8)
        #expect(try VibeSyncDshParser(sessionsDir: dir.path).parse().entries.count == 1)
        try "newer".write(toFile: dir.path + "/p/s/session.v5.jsonl", atomically: true, encoding: .utf8)
        let invalid = try VibeSyncDshParser(sessionsDir: dir.path).parse()
        #expect(invalid.skipped); #expect(invalid.entries.isEmpty)
    }
    func rawZstd(_ text: String) -> Data {
        let bytes = Array(text.utf8); precondition(bytes.count < 256)
        let header = (bytes.count << 3) | 1
        return Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(bytes.count), UInt8(header & 255), UInt8((header >> 8) & 255), UInt8((header >> 16) & 255)] + bytes)
    }
    @Test func zstdConcatenatedFramesSkipMetadataAndRecoverTornTail() throws {
        let first = rawZstd("header\n"), second = rawZstd("record\n")
        let skippable = Data([0x50, 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 1, 2, 3])
        let data = first + skippable + second + first.prefix(7)
        #expect(try VibeZstd.frames(data).count == 2)
        #expect(String(decoding: try VibeZstd.decompress(data), as: UTF8.self) == "header\nrecord\n")
        #expect(throws: (any Error).self) { try VibeZstd.frames(Data([0, 1, 2, 3])) }
    }
    @Test func kiroStreamExcludesSignatureFromOutputButIncludesResentContext() {
        let events: [[String: Any]] = [
            ["kind": "Prompt", "data": ["meta": ["timestamp": 1767225600], "content": [["kind": "text", "data": "12345678"]]]],
            ["kind": "AssistantMessage", "data": ["content": [["kind": "thinking", "data": ["text": "12345678", "signature": "1234567890123456", "modelId": "claude"]], ["kind": "text", "data": "1234"]]]],
            ["kind": "ToolResults", "data": ["content": [["data": "12345678"]]]],
            ["kind": "AssistantMessage", "data": ["content": [["kind": "text", "data": "1234"]]]],
            ["kind": "Compaction", "data": ["summary": "1234"]],
            ["kind": "AssistantMessage", "data": ["content": [["kind": "text", "data": "1234"]]]]
        ]
        let entries = VibeSyncKiroParser.streamEntries(events, project: "project", model: nil, fallback: .distantPast)
        #expect(entries.count == 3); #expect(entries[0].inputTokens == 2)
        #expect(entries[0].outputTokens == 1); #expect(entries[0].reasoningOutputTokens == 2)
        #expect(entries[1].cachedInputTokens == 9); #expect(entries[2].cachedInputTokens == 1)
    }
    @Test func kiroCreditsTelescopeFractionalUsageAndResetAtCycleBoundary() {
        let snapshots = [(0.2, "a"), (0.8, "a"), (1.1, "a"), (2.9, "a"), (0.2, "b"), (1.0, "b")].enumerated().map {
            VibeSyncKiroParser.Snapshot(date: Date(timeIntervalSince1970: Double($0.offset)), usage: $0.element.0, reset: $0.element.1)
        }
        let entries = VibeSyncKiroParser.creditEntries(snapshots)
        #expect(entries.map(\.outputTokens) == [1, 1, 1])
        #expect(entries.allSatisfy { $0.model == "kiro-credits" })
    }
    func varint(_ n: UInt64) -> Data {
        var n = n, data = Data()
        repeat { let b = UInt8(n & 127); n >>= 7; data.append(b | (n > 0 ? 128 : 0)) } while n > 0
        return data
    }
    func number(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    func bytes(_ field: Int, _ data: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data }
    func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    @Test func antigravityOfflineTimestampJoinResponseDedupAndLegacyExclusion() async throws {
        let dir = makeTempDirectory("agy-port"); defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = bytes(1, number(1, 1767225600)) + number(3, 4)
        let usage = number(2, 100) + number(3, 20) + number(5, 30) + number(9, 4) + bytes(11, Data("response".utf8))
        let blob = bytes(1, bytes(4, usage) + bytes(19, Data("gemini-3-flash-a".utf8)))
        let workspace = bytes(1, bytes(1, Data("file:///repo/project".utf8)))
        let db = try SQLiteFixture(at: dir.appendingPathComponent("s.db"), sql: "CREATE TABLE steps(idx INTEGER, metadata BLOB); CREATE TABLE gen_metadata(idx INTEGER, data BLOB); CREATE TABLE trajectory_metadata_blob(data BLOB); INSERT INTO steps VALUES(1,X'\(hex(stamp))'); INSERT INTO gen_metadata VALUES(1,X'\(hex(blob))'),(1,X'\(hex(blob))'); INSERT INTO trajectory_metadata_blob VALUES(X'\(hex(workspace))');")
        defer { db.close() }
        try Data().write(to: dir.appendingPathComponent("s.pb"))
        let parser = VibeSyncAntigravityParser(directories: [dir.path], rpc: { _ in throw VibeSQLiteError(message: "must not call RPC for DB cascade") })
        let r = try await parser.parse()
        #expect(!r.skipped); #expect(r.entries.count == 1); #expect(r.events.count == 1)
        #expect(r.entries[0].project == "project"); #expect(r.entries[0].cachedInputTokens == 30)
        #expect(r.entries[0].model == "gemini-3-flash-a")
    }
    @Test func antigravityLegacyRPCAndMalformedProto() async throws {
        let dir = makeTempDirectory("agy-rpc"); defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("legacy.pb"))
        let chat: [String: Any] = ["responseModel": "claude-opus-4-6-thinking",
                                  "chatStartMetadata": ["createdAt": "2026-01-01T00:00:00Z"],
                                  "retryInfos": [["usage": ["inputTokens": 10, "outputTokens": 2, "responseId": "a"]]]]
        let payload: [String: Any] = ["trajectory": ["generatorMetadata": [["chatModel": chat]]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let r = try await VibeSyncAntigravityParser(directories: [dir.path], rpc: { _ in data }).parse()
        #expect(r.entries[0].model == "claude-opus-4-6")
        let failure = try await VibeSyncAntigravityParser(directories: [dir.path], rpc: { _ in Data("{}".utf8) }).parse()
        #expect(failure.skipped)
        #expect(throws: (any Error).self) { try VibeProto(Data([0x0a, 0xff])) }
        #expect(throws: (any Error).self) { try VibeProto(Data(repeating: 0xff, count: 12)) }
    }
}
