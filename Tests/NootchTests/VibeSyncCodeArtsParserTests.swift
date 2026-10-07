import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/codearts-agent.test.js.
@Suite struct VibeSyncCodeArtsParserTests {
    private static let schema = """
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          parent_id TEXT,
          directory TEXT NOT NULL
        );
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        """

    /// 2026-09-17T01:00:00.000Z in milliseconds.
    private var start: Int { Int(Self.startDate.timeIntervalSince1970 * 1000) }
    private static let startDate = VibeSyncTime.parse("2026-09-17T01:00:00.000Z")!

    private func session(_ id: String, _ parentId: String?, _ directory: String) -> String {
        "INSERT INTO session VALUES (\(sqlQuote(id)), \(parentId.map(sqlQuote) ?? "NULL"), \(sqlQuote(directory)));"
    }

    private func message(
        _ id: String, _ sessionId: String, _ time: Int, _ role: String, extra: [String: Any] = [:]
    ) -> String {
        var data: [String: Any] = ["role": role, "time": ["created": time]]
        data.merge(extra) { _, new in new }
        let json = String(data: try! JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        return "INSERT INTO message VALUES (\(sqlQuote(id)), \(sqlQuote(sessionId)), \(time), \(time), \(sqlQuote(json)));"
    }

    @discardableResult
    private func createDb(_ root: URL, rows: String = "") throws -> URL {
        let path = root.appendingPathComponent("opencode.db")
        let fixture = try SQLiteFixture(at: path, sql: Self.schema + rows)
        fixture.close()
        return path
    }

    @Test func resolvesDefaultAndOverrideRoots() {
        #expect(VibeSyncCodeArtsParser.resolveRoots(environment: [:], home: "/home/test")
            == ["/home/test/.codeartsdoer/codearts-data"])
        #expect(VibeSyncCodeArtsParser.resolveRoots(
            environment: ["VIBE_USAGE_CODEARTS_AGENT_DIRS": "/tmp/codearts-a:/tmp/codearts-b"],
            home: "/unused") == ["/tmp/codearts-a", "/tmp/codearts-b"])
    }

    @Test func resolvesSupportedStoreLayouts() throws {
        let root = makeTempDirectory("codearts-layout")
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("codearts-data")
        let db = try createDb(dataRoot)
        // A root may point at the parent dir, the data dir, or opencode.db itself.
        #expect(VibeSyncCodeArtsParser.findDatabases(
            roots: [root.path, dataRoot.path, db.path]) == [db.path])
    }

    @Test func countsChildCallsButFoldsChildTimingIntoOneHumanSession() throws {
        let root = makeTempDirectory("codearts")
        defer { try? FileManager.default.removeItem(at: root) }
        try createDb(root, rows: """
            \(session("root", nil, "C:\\work\\root-project"))
            \(session("child", "root", "C:\\work\\root-project"))
            \(message("u1", "root", start, "user"))
            \(message("a1", "root", start + 1_000, "assistant", extra: [
                "modelID": "GLM-5.2",
                "path": ["root": "C:\\work\\root-project"],
                "tokens": ["input": 10, "output": 3, "reasoning": 2, "cache": ["read": 6, "write": 2]],
            ]))
            \(message("child-prompt", "child", start + 2_000, "user"))
            \(message("child-reply", "child", start + 3_000, "assistant", extra: [
                "model": ["modelID": "GLM-5.2"],
                "tokens": ["input": 5, "output": 4, "reasoning": 3, "cache": ["read": 1, "write": 0]],
            ]))
            """)

        let result = try VibeSyncCodeArtsParser(roots: [root.path]).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "codearts-agent")
        #expect(bucket.model == "GLM-5.2")
        #expect(bucket.project == "root-project")
        #expect(bucket.bucketStart == "2026-09-17T01:00:00.000Z")
        #expect(bucket.inputTokens == 15)
        #expect(bucket.outputTokens == 7)
        #expect(bucket.cachedInputTokens == 7)
        #expect(bucket.reasoningOutputTokens == 5)
        #expect(bucket.cacheCreation5mTokens == 2)
        #expect(bucket.cacheCreation1hTokens == 0)
        #expect(bucket.totalTokens == 29)

        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.project == "root-project")
        #expect(session.messageCount == 4)
        #expect(session.userMessageCount == 1)
        #expect(session.activeSeconds == 2)
        #expect(session.firstMessageAt == "2026-09-17T01:00:00.000Z")
        #expect(session.lastMessageAt == "2026-09-17T01:00:03.000Z")
    }

    @Test func terminatesCyclicAncestryAndTreatsOrphansAsRoots() throws {
        let root = makeTempDirectory("codearts")
        defer { try? FileManager.default.removeItem(at: root) }
        try createDb(root, rows: """
            \(session("orphan", "missing-parent", "/work/orphan"))
            \(session("cycle-a", "cycle-b", "/work/cycle-a"))
            \(session("cycle-b", "cycle-a", "/work/cycle-b"))
            \(message("orphan-user", "orphan", start, "user"))
            \(message("orphan-reply", "orphan", start + 1_000, "assistant", extra: [
                "modelID": "model", "tokens": ["input": 3],
            ]))
            \(message("cycle-user", "cycle-a", start + 2_000, "user"))
            \(message("cycle-reply", "cycle-b", start + 3_000, "assistant", extra: [
                "modelID": "model", "tokens": ["output": 2],
            ]))
            """)

        let result = try VibeSyncCodeArtsParser(roots: [root.path]).parse()
        let buckets = vibeBuckets(result)
        #expect(buckets.reduce(0) { $0 + $1.inputTokens } == 3)
        #expect(buckets.reduce(0) { $0 + $1.outputTokens } == 2)
        let sessions = vibeSessions(result)
        #expect(sessions.map(\.project).sorted() == ["cycle-a", "orphan"])
        #expect(sessions.map(\.messageCount).sorted() == [1, 2])
    }

    @Test func acceptsModelAndTimestampVariantsAndCacheOnlyUsage() throws {
        let root = makeTempDirectory("codearts")
        defer { try? FileManager.default.removeItem(at: root) }
        try createDb(root, rows: """
            \(session("s1", nil, "/work/project"))
            \(message("u1", "s1", start, "user"))
            INSERT INTO message VALUES ('a1', 's1', \((start + 1_000) / 1_000), \(start + 1_000),
              '{"role":"assistant","modelId":"glm-5.3-flash","tokens":{"cache":{"write":9}}}');
            \(message("a2", "s1", start + 2_000, "assistant", extra: [
                "model": ["modelId": "deepseek-v4-flash-0731"],
                "tokens": ["reasoning": 4],
            ]))
            \(message("zero", "s1", start + 3_000, "assistant", extra: [
                "modelID": "ignored-zero", "tokens": ["input": 0, "output": 0],
            ]))
            """)

        let result = try VibeSyncCodeArtsParser(roots: [root.path]).parse()
        let byModel = Dictionary(uniqueKeysWithValues: vibeBuckets(result).map { ($0.model, $0) })
        // Untyped cache write lands in the cheaper 5m bucket; the seconds
        // column timestamp (no $.time.created) is sniffed back to ms.
        #expect(byModel["glm-5.3-flash"]?.cacheCreation5mTokens == 9)
        #expect(byModel["glm-5.3-flash"]?.bucketStart == "2026-09-17T01:00:00.000Z")
        #expect(byModel["deepseek-v4-flash-0731"]?.reasoningOutputTokens == 4)
        #expect(byModel["ignored-zero"] == nil)
    }

    @Test func deduplicatesCopiedRicherAndSymlinkedDatabases() throws {
        let root = makeTempDirectory("codearts")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let baseRows = """
            \(session("s1", nil, "/work/project"))
            \(message("u1", "s1", start, "user"))
            """
        try createDb(first, rows: baseRows + message("a1", "s1", start + 1_000, "assistant", extra: [
            "modelID": "model", "tokens": ["input": 1, "output": 1],
        ]))
        try createDb(second, rows: baseRows + message("a1", "s1", start + 1_000, "assistant", extra: [
            "modelID": "model", "tokens": ["input": 9, "output": 2],
        ]))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)

        #expect(VibeSyncCodeArtsParser.findDatabases(roots: [second.path, alias.path]).count == 1)

        let result = try VibeSyncCodeArtsParser(roots: [first.path, second.path, alias.path]).parse()
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].inputTokens == 9)
        #expect(buckets[0].outputTokens == 2)
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions[0].messageCount == 2)
        #expect(sessions[0].userMessageCount == 1)
    }

    @Test func readsAnActiveWalDatabaseWithoutMutatingTheSource() throws {
        let root = makeTempDirectory("codearts-wal")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("opencode.db")
        let writer = try SQLiteFixture(at: path, sql: Self.schema + """
            \(session("s1", nil, "/work/project"))
            \(message("u1", "s1", start, "user"))
            \(message("a1", "s1", start + 1_000, "assistant", extra: [
                "modelID": "model", "tokens": ["input": 7, "output": 3],
            ]))
            """, wal: true)
        defer { writer.close() }
        #expect(FileManager.default.fileExists(atPath: path.path + "-wal"))

        let result = try VibeSyncCodeArtsParser(roots: [root.path]).parse()
        #expect(vibeBuckets(result).first?.inputTokens == 7)
        // The source -wal was never checkpointed or removed by the read.
        #expect(FileManager.default.fileExists(atPath: path.path + "-wal"))
    }

    @Test func preservesSourceStateOnCorruptOrIncompatibleDiscoveredStores() throws {
        let root = makeTempDirectory("codearts")
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid")
        try createDb(valid, rows: session("s1", nil, "/work/project") + message("u1", "s1", start, "user"))

        let corrupt = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try "not sqlite".write(to: corrupt.appendingPathComponent("opencode.db"), atomically: true, encoding: .utf8)

        let incompatible = root.appendingPathComponent("incompatible")
        let fixture = try SQLiteFixture(
            at: incompatible.appendingPathComponent("opencode.db"), sql: "CREATE TABLE message (id TEXT);")
        fixture.close()

        for broken in [corrupt, incompatible] {
            let result = try VibeSyncCodeArtsParser(roots: [valid.path, broken.path]).parse()
            #expect(result.skipped)
            #expect(result.entries.isEmpty)
            #expect(result.events.isEmpty)
        }
    }

    @Test func neverSurfacesPromptOrToolContentInParsedOutput() throws {
        let root = makeTempDirectory("codearts-privacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = "CANARY_PROMPT_TEXT_DO_NOT_LEAK"
        try createDb(root, rows: """
            \(session("s1", nil, "/work/project"))
            \(message("u1", "s1", start, "user", extra: ["content": canary]))
            \(message("a1", "s1", start + 1_000, "assistant", extra: [
                "modelID": "model",
                "tokens": ["input": 4, "output": 2],
                "content": canary,
                "parts": [["type": "text", "text": canary]],
            ]))
            """)

        let result = try VibeSyncCodeArtsParser(roots: [root.path]).parse()
        let serialized = result.entries.map { "\($0.model)\($0.project)" }.joined()
            + result.events.map(\.project).joined()
        #expect(!serialized.contains(canary))
    }
}
