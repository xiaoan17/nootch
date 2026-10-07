import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/opencode-roots.test.js (the parser-level assertions;
// there is no separate upstream opencode parser test file).
@Suite struct VibeSyncOpenCodeParserTests {
    /// 2026-09-12T00:00:00Z in milliseconds.
    private static let startDate = VibeSyncTime.parse("2026-09-12T00:00:00.000Z")!
    private var start: Int { Int(Self.startDate.timeIntervalSince1970 * 1000) }

    private func rows(session: String = "ses_one", model: String = "test-model") -> [[String: Any]] {
        [
            ["id": "user", "sessionID": session, "role": "user",
             "time": ["created": start], "path": ["root": "/work/project"]],
            ["id": "reply", "sessionID": session, "role": "assistant",
             "time": ["created": start + 1_000], "modelID": model,
             "tokens": ["input": 10, "output": 3, "reasoning": 1, "cache": ["read": 2]],
             "path": ["root": "/work/project"]],
        ]
    }

    // MARK: - Fixture writers

    @discardableResult
    private func sqlite(_ root: URL, messages: [[String: Any]]) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sql = "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT);"
        for message in messages {
            let data = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
            sql += "INSERT INTO message VALUES (\(sqlQuote(message["id"] as! String)),"
                + "\(sqlQuote(message["sessionID"] as! String)),\(sqlQuote(data)));"
        }
        let fixture = try SQLiteFixture(at: root.appendingPathComponent("opencode.db"), sql: sql)
        fixture.close()
        return root
    }

    /// OpenCode 2.x layout: usage lives in the session_message projection, the
    /// project directory in the session row, and there is no legacy message table.
    private func sqliteV2(
        _ root: URL, sessions: [[String: String]], messages: [[String: Any]],
        sessionTable: String = "session_v2"
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sql = "CREATE TABLE \(sessionTable) (id TEXT PRIMARY KEY, directory TEXT);"
            + "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);"
        for session in sessions {
            sql += "INSERT INTO \(sessionTable) VALUES (\(sqlQuote(session["id"]!)),\(sqlQuote(session["directory"]!)));"
        }
        for message in messages {
            let data = String(data: try JSONSerialization.data(withJSONObject: message["data"]!), encoding: .utf8)!
            sql += "INSERT INTO session_message VALUES (\(sqlQuote(message["id"] as! String)),"
                + "\(sqlQuote(message["sessionID"] as! String)),\(sqlQuote(message["type"] as! String)),"
                + "\(message["time"] as! Int),\(sqlQuote(data)));"
        }
        let fixture = try SQLiteFixture(at: root.appendingPathComponent("opencode.db"), sql: sql)
        fixture.close()
    }

    private func v2Message(
        _ id: String, _ sessionID: String, _ type: String, _ time: Int, data: [String: Any] = [:]
    ) -> [String: Any] {
        ["id": id, "sessionID": sessionID, "type": type, "time": time, "data": data]
    }

    @discardableResult
    private func json(_ root: URL, messages: [[String: Any]]) throws -> URL {
        for message in messages {
            let sessionId = message["sessionID"] as! String
            let id = message["id"] as! String
            let directory = root.appendingPathComponent("storage/message/\(sessionId)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: message)
            try data.write(to: directory.appendingPathComponent("\(id).json"))
        }
        return root
    }

    private func parse(roots: [URL], extraRoots: [URL] = []) throws -> VibeParseResult {
        try VibeSyncOpenCodeParser(
            roots: roots.map(\.path), extraRoots: extraRoots.map(\.path)).parse()
    }

    // MARK: - Tests

    @Test func combinesDefaultSqliteAndExtraSqliteStoresExactlyOnce() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqlite(primary, messages: rows())
        let extra = root.appendingPathComponent("extra")
        try sqlite(extra, messages: rows(session: "ses_two"))

        let result = try parse(roots: [primary], extraRoots: [extra])
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].inputTokens == 20)
        #expect(buckets[0].cachedInputTokens == 4)
        #expect(buckets[0].reasoningOutputTokens == 2)
        #expect(vibeSessions(result).count == 2)
    }

    @Test func mergesSqliteAndJsonStoresAndPreservesTopLevelModelPrecedence() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try json(primary, messages: rows())

        let extra = root.appendingPathComponent("extra")
        var nested = rows(session: "ses_two")
        nested[1]["model"] = ["modelID": "nested-model"]
        nested[1]["modelID"] = nil
        try sqlite(extra, messages: nested)

        let extraJson = root.appendingPathComponent("extra-json")
        var both = rows(session: "ses_three", model: "keep-existing")
        both[1]["model"] = ["modelID": "do-not-rename"]
        try json(extraJson, messages: both)

        let result = try parse(roots: [primary], extraRoots: [extra, extraJson])
        #expect(vibeBuckets(result).map(\.model).sorted()
            == ["keep-existing", "nested-model", "test-model"])
        #expect(vibeSessions(result).count == 3)
    }

    @Test func deduplicatesCopiedSymlinkedAndCrossFormatStoresByMessageIdentity() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqlite(primary, messages: rows())
        let copy = root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: primary, to: copy)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: primary)
        let legacy = root.appendingPathComponent("legacy")
        try json(legacy, messages: rows())

        let result = try parse(roots: [primary], extraRoots: [primary, copy, alias, legacy])
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].inputTokens == 10)
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions[0].userMessageCount == 1)
    }

    @Test func keepsRicherCopiesAndAdditionalMessages() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqlite(primary, messages: rows())
        let extra = root.appendingPathComponent("extra")
        var messages = rows()
        var tokens = messages[1]["tokens"] as! [String: Any]
        tokens["input"] = 15
        messages[1]["tokens"] = tokens
        var replyTwo = messages[1]
        replyTwo["id"] = "reply-two"
        replyTwo["time"] = ["created": start + 2_000]
        messages.append(replyTwo)
        try json(extra, messages: messages)

        let result = try parse(roots: [primary], extraRoots: [extra])
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].inputTokens == 30)
        #expect(vibeSessions(result).first?.messageCount == 3)
    }

    @Test func sqlitePrecedenceIsPerRootIncludingAnEmptyMigratedDatabase() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqlite(primary, messages: [])
        try json(primary, messages: rows())
        let extra = root.appendingPathComponent("extra")
        try json(extra, messages: rows(session: "ses_two"))

        let result = try parse(roots: [primary], extraRoots: [extra])
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].inputTokens == 10)
        #expect(vibeSessions(result).count == 1)
    }

    @Test func missingConfiguredRootsAndCorruptStoresSuppressPartialUploads() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqlite(primary, messages: rows())

        let missing = root.appendingPathComponent("missing")
        let brokenDb = root.appendingPathComponent("broken-db")
        try FileManager.default.createDirectory(at: brokenDb, withIntermediateDirectories: true)
        try "not sqlite".write(to: brokenDb.appendingPathComponent("opencode.db"), atomically: true, encoding: .utf8)
        let brokenJson = root.appendingPathComponent("broken-json")
        try json(brokenJson, messages: rows())
        try "{".write(
            to: brokenJson.appendingPathComponent("storage/message/ses_one/reply.json"),
            atomically: true, encoding: .utf8)

        for broken in [missing, brokenDb, brokenJson] {
            let result = try parse(roots: [primary], extraRoots: [broken])
            #expect(result.skipped)
            #expect(result.entries.isEmpty)
            #expect(result.events.isEmpty)
        }
    }

    @Test func doesNotRenameUnknownProjectBucketsFromCwdMetadata() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        var messages = rows()
        messages[1]["path"] = ["cwd": "/work/do-not-rename"]
        try sqlite(primary, messages: messages)

        let result = try parse(roots: [primary])
        #expect(vibeBuckets(result).first?.project == "unknown")
    }

    @Test func readsV2SessionMessageProjectionWithoutLegacyMessageTable() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqliteV2(
            primary,
            sessions: [["id": "ses_v2", "directory": "/work/v2-project"]],
            messages: [
                v2Message("msg_u1", "ses_v2", "user", start,
                          data: ["type": "user", "text": "private prompt text"]),
                v2Message("msg_a1", "ses_v2", "assistant", start + 1_000, data: [
                    "type": "assistant",
                    "model": ["id": "claude-opus-4-6", "providerID": "opencode"],
                    "tokens": ["input": 10, "output": 3, "reasoning": 1, "cache": ["read": 2, "write": 4]],
                ]),
                v2Message("msg_idle", "ses_v2", "idle", start + 2_000, data: ["type": "idle"]),
            ])

        let result = try parse(roots: [primary])
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "opencode")
        #expect(bucket.model == "claude-opus-4-6")
        #expect(bucket.project == "v2-project")
        #expect(bucket.bucketStart == "2026-09-12T00:00:00.000Z")
        #expect(bucket.inputTokens == 10)
        #expect(bucket.outputTokens == 3)
        #expect(bucket.cachedInputTokens == 2)
        #expect(bucket.reasoningOutputTokens == 1)
        #expect(bucket.cacheCreation5mTokens == 4)
        #expect(bucket.cacheCreation1hTokens == 0)
        #expect(bucket.totalTokens == 18)

        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions[0].userMessageCount == 1)
        #expect(sessions[0].messageCount == 2)
    }

    @Test func readsStoreWhoseSessionRowUsesThePreSplitSessionTableName() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqliteV2(
            primary,
            sessions: [["id": "ses_plain", "directory": "/work/plain-session"]],
            messages: [
                v2Message("msg_a1", "ses_plain", "assistant", start, data: [
                    "model": ["id": "kimi-k2.5", "providerID": "opencode"],
                    "tokens": ["input": 5, "output": 2, "reasoning": 0, "cache": ["read": 0, "write": 0]],
                ]),
            ],
            sessionTable: "session")

        let result = try parse(roots: [primary])
        let bucket = try #require(vibeBuckets(result).first)
        #expect(bucket.project == "plain-session")
        #expect(bucket.model == "kimi-k2.5")
        #expect(bucket.inputTokens == 5)
    }

    @Test func countsMessagePresentInBothStoreShapesOnceAndKeepsLegacyProject() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try sqlite(primary, messages: rows())

        // Add a session_v2 + session_message projection holding a copy of the
        // same assistant message under a different session directory.
        var sql = "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT);"
            + "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);"
            + "INSERT INTO session_v2 VALUES ('ses_one', '/work/migrated-project');"
        let shared = rows().filter { $0["role"] as? String == "assistant" }
        for message in shared {
            let data = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
            sql += "INSERT INTO session_message VALUES (\(sqlQuote(message["id"] as! String)),"
                + "\(sqlQuote(message["sessionID"] as! String)),'assistant',"
                + "\((message["time"] as! [String: Any])["created"] as! Int),\(sqlQuote(data)));"
        }
        let fixture = try SQLiteFixture(at: primary.appendingPathComponent("opencode.db"), sql: sql)
        fixture.close()

        let result = try parse(roots: [primary])
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].inputTokens == 10)
        #expect(buckets[0].project == "project")
    }

    @Test func namesAnUnreadableStoreShapeInsteadOfReportingAMissingTable() throws {
        let root = makeTempDirectory("opencode")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("default")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        let fixture = try SQLiteFixture(
            at: primary.appendingPathComponent("opencode.db"), sql: "CREATE TABLE unrelated (id TEXT);")
        fixture.close()

        let result = try parse(roots: [primary])
        #expect(result.skipped)
        #expect(result.entries.isEmpty)
    }
}
