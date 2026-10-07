import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage test/droid.test.js (upstream 7c48693 + the fix
// chain 1db0c8f / c55b82c / 8dd5c95). Parsers are constructed with explicit
// sessionsDir/settingsPaths instead of mutating process env (the JS fixture
// overrides VIBE_USAGE_DROID_SESSIONS / VIBE_USAGE_DROID_SETTINGS), so tests
// can run in parallel and never touch the real ~/.factory catalog.
@Suite("VibeSyncDroidParser")
struct VibeSyncDroidParserTests {
    private func makeRoot() throws -> URL {
        makeTempDirectory("droid")
    }

    /// Write <root>/<slug>/<sessionId>.jsonl plus the <sessionId>.settings.json
    /// sidecar (JS writeSession).
    private func writeSession(
        root: URL, slug: String, sessionId: String,
        settings: [String: Any], records: [[String: Any]]
    ) throws {
        let dir = root.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = try records.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("\(sessionId).jsonl"), atomically: true, encoding: .utf8)
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try (String(decoding: settingsData, as: UTF8.self) + "\n")
            .write(to: dir.appendingPathComponent("\(sessionId).settings.json"), atomically: true, encoding: .utf8)
    }

    private func records(_ ts: String = "2026-09-17T09:51:33.807Z") -> [[String: Any]] {
        [
            [
                "type": "message", "id": "u1", "timestamp": ts,
                "message": ["role": "user", "content": [["type": "text", "text": "DO NOT UPLOAD"]]],
            ],
            [
                "type": "message", "id": "a1", "timestamp": "2026-09-17T09:52:06.089Z",
                "message": ["role": "assistant", "content": [["type": "text", "text": "VIBE-REPRO-OK"]]],
            ],
        ]
    }

    @Test("resolves Factory slot ids to the upstream API model")
    func modelResolution() {
        let catalog = [
            "custom:deepseek-v4.1-flash-[gw]-1": "acme/deepseek-v4.1-flash",
            "custom:Union-Alpha-Free-0": "union-alpha",
            "custom:auto-[gw]-0": "auto",
        ]
        #expect(VibeSyncDroidParser.resolveModel("custom:gpt-6-astra-[gw]-0", catalog: [:]) == "gpt-6-astra")
        #expect(VibeSyncDroidParser.resolveModel("custom:gpt-5.4-[gw]-0", catalog: [:]) == "gpt-5.4")
        #expect(VibeSyncDroidParser.resolveModel("custom:gpt-5.4-fast-[gw]-17", catalog: [:]) == "gpt-5.4-fast")
        #expect(VibeSyncDroidParser.resolveModel("custom:claude-opus-4-6-[gw]-13", catalog: [:]) == "claude-opus-4-6")
        #expect(VibeSyncDroidParser.resolveModel("custom:deepseek-v4.1-flash-[gw]-1", catalog: catalog) == "acme/deepseek-v4.1-flash")
        #expect(VibeSyncDroidParser.resolveModel("custom:deepseek-v4.1-flash-[gw]-1", catalog: [:]) == "deepseek-v4.1-flash")
        #expect(VibeSyncDroidParser.resolveModel("custom:Union-Alpha-Free-0", catalog: catalog) == "union-alpha")
        #expect(VibeSyncDroidParser.resolveModel("custom:Union-Alpha-Free-0", catalog: [:]) == "custom:Union-Alpha-Free-0")
        #expect(VibeSyncDroidParser.resolveModel("claude-opus-4-6", catalog: [:]) == "claude-opus-4-6")
        #expect(VibeSyncDroidParser.resolveModel("custom:auto-[gw]-0", catalog: catalog) == "droid-auto")
        #expect(VibeSyncDroidParser.resolveModel("", catalog: [:]) == "unknown")
    }

    @Test("keeps Factory sidecar inputTokens as uncached input")
    func sidecarInputIsUncached() throws {
        let root = try makeRoot()
        // Numbers from a live 2026-09-17 BYOK exec (custom:gpt-6-astra,
        // providerLock openai). Factory's own log recorded inputTokens=1048 as
        // uncached and cacheReadInputTokens=10752 separately
        // (totalInputTokens=11800).
        try writeSession(root: root, slug: "private-tmp", sessionId: "11111111-1111-1111-1111-111111111111",
                         settings: [
                            "model": "custom:gpt-6-astra-[gw]-0",
                            "providerLock": "openai",
                            "tokenUsage": [
                                "inputTokens": 1048,
                                "outputTokens": 11,
                                "cacheCreationTokens": 0,
                                "cacheReadTokens": 10752,
                                "thinkingTokens": 0,
                                "factoryCredits": 8713,
                            ],
                         ],
                         records: records())
        let result = try VibeSyncDroidParser(sessionsDir: root.path).parse()
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "droid")
        #expect(bucket.model == "gpt-6-astra")
        #expect(bucket.project == "tmp")
        #expect(bucket.inputTokens == 1048)
        #expect(bucket.cachedInputTokens == 10752)
        #expect(bucket.outputTokens == 11)
        #expect(bucket.reasoningOutputTokens == 0)
        #expect(bucket.cacheCreation5mTokens == 0)
        #expect(bucket.totalTokens == 1059)
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions.first?.userMessageCount == 1)
        // 这份 fixture 埋了提示词文本,解析器只应产出计量与时序字段。
        let retained = result.entries.map { "\($0.model)\($0.project)" }
            + result.events.map { "\($0.sessionId)\($0.project)" }
        #expect(retained.allSatisfy { !$0.contains("DO NOT UPLOAD") && !$0.contains("VIBE-REPRO-OK") })
    }

    @Test("catalog maps a slot id whose slug is not the API model")
    func catalogMapsSlotId() throws {
        let root = try makeRoot()
        let catalogPath = root.appendingPathComponent("factory-settings.json")
        let catalog = try JSONSerialization.data(withJSONObject: [
            "customModels": [["id": "custom:deepseek-v4.1-flash-[gw]-1", "model": "acme/deepseek-v4.1-flash"]],
        ])
        try catalog.write(to: catalogPath)
        try writeSession(root: root, slug: "demo-ses", sessionId: "flash-1",
                         settings: [
                            "model": "custom:deepseek-v4.1-flash-[gw]-1",
                            "tokenUsage": ["inputTokens": 10, "outputTokens": 2, "cacheReadTokens": 4],
                         ],
                         records: records())
        let parser = VibeSyncDroidParser(sessionsDir: root.path, settingsPaths: [catalogPath.path])
        let buckets = vibeBuckets(try parser.parse())
        let bucket = try #require(buckets.first)
        #expect(bucket.model == "acme/deepseek-v4.1-flash")
        #expect(bucket.inputTokens == 10)
    }

    @Test("session fixtures do not read the real Factory settings catalog")
    func fixturesDoNotReadRealCatalog() throws {
        let root = try makeRoot()
        try writeSession(root: root, slug: "union-project", sessionId: "union-1",
                         settings: [
                            "model": "custom:Union-Alpha-Free-0",
                            "tokenUsage": ["inputTokens": 5, "outputTokens": 1],
                         ],
                         records: records("2026-09-16T02:00:00.000Z"))
        // No settingsPaths given: an explicit sessionsDir must disable the
        // machine catalog entirely.
        let buckets = vibeBuckets(try VibeSyncDroidParser(sessionsDir: root.path).parse())
        #expect(buckets.first?.model == "custom:Union-Alpha-Free-0")
    }

    @Test("books cache writes to the 5m column and splits thinking out of output")
    func cacheWriteAndThinkingSplit() throws {
        let root = try makeRoot()
        try writeSession(root: root, slug: "demo-project", sessionId: "think-cache-write",
                         settings: [
                            "model": "custom:glm-5-[gw]-11",
                            "tokenUsage": [
                                "inputTokens": 100,
                                "outputTokens": 80,
                                "cacheCreationTokens": 40,
                                "cacheReadTokens": 20,
                                "thinkingTokens": 30,
                            ],
                         ],
                         records: [
                            [
                                "type": "message", "id": "u1", "timestamp": "2026-03-16T09:30:01.000Z",
                                "message": ["role": "user", "content": [["type": "text", "text": "hi"]]],
                            ],
                            [
                                "type": "message", "id": "a1", "timestamp": "2026-03-16T09:30:02.000Z",
                                "message": ["role": "assistant", "content": [["type": "text", "text": "ok"]]],
                            ],
                         ])
        let bucket = try #require(vibeBuckets(try VibeSyncDroidParser(sessionsDir: root.path).parse()).first)
        #expect(bucket.model == "glm-5")
        #expect(bucket.inputTokens == 100)
        #expect(bucket.cachedInputTokens == 20)
        #expect(bucket.outputTokens == 50)
        #expect(bucket.reasoningOutputTokens == 30)
        #expect(bucket.cacheCreation5mTokens == 40)
        #expect(bucket.cacheCreation1hTokens == 0)
        #expect(bucket.totalTokens == 220)
    }

    @Test("skips buckets when tokenUsage is missing or all zero, but still emits sessions")
    func missingOrZeroUsage() throws {
        let root = try makeRoot()
        try writeSession(root: root, slug: "doubao-project", sessionId: "missing-usage",
                         settings: [
                            "model": "custom:volcengine/doubao-seed-2-0-code-preview-260215-[gw]-6",
                            "providerLock": "generic-chat-completion-api",
                         ],
                         records: [
                            [
                                "type": "message", "id": "u1", "timestamp": "2026-03-20T10:00:00.000Z",
                                "message": ["role": "user", "content": [["type": "text", "text": "hello"]]],
                            ],
                            [
                                "type": "message", "id": "a1", "timestamp": "2026-03-20T10:00:05.000Z",
                                "message": ["role": "assistant", "content": [["type": "text", "text": "hi"]]],
                            ],
                         ])
        try writeSession(root: root, slug: "union-project", sessionId: "zero-usage",
                         settings: [
                            "model": "custom:Union-Alpha-Free-0",
                            "providerLock": "anthropic",
                            "tokenUsage": [
                                "inputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0,
                                "cacheReadTokens": 0, "thinkingTokens": 0, "factoryCredits": 0,
                            ],
                         ],
                         records: [
                            [
                                "type": "message", "id": "u1", "timestamp": "2026-09-16T02:00:00.000Z",
                                "message": ["role": "user", "content": [["type": "text", "text": "hi"]]],
                            ],
                            [
                                "type": "message", "id": "a1", "timestamp": "2026-09-16T02:00:02.000Z",
                                "message": ["role": "assistant", "content": [["type": "text", "text": "hello"]]],
                            ],
                         ])
        let result = try VibeSyncDroidParser(sessionsDir: root.path).parse()
        #expect(result.entries.isEmpty)
        #expect(vibeSessions(result).count == 2)
    }
}
