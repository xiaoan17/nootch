import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/mimocode.test.js.
@Suite struct VibeSyncMimocodeParserTests {
    private static let schema = """
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          directory TEXT NOT NULL
        );
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        """

    private func message(_ id: String, _ session: String, _ created: Int, data: [String: Any]) -> String {
        let json = String(data: try! JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        return """
            INSERT INTO message (id, session_id, time_created, data)
            VALUES (\(sqlQuote(id)), \(sqlQuote(session)), \(created), \(sqlQuote(json)));
            """
    }

    private func fixtureDb(sql: String) throws -> (URL, URL) {
        let root = makeTempDirectory("mimocode")
        let path = root.appendingPathComponent("mimicode.db")
        let fixture = try SQLiteFixture(at: path, sql: sql)
        fixture.close()
        return (root, path)
    }

    @Test func resolvesEnvironmentPrecedence() throws {
        let home = "/tmp/mimo-home"
        #expect(try VibeSyncMimocodeParser.resolveDbPath(
            environment: ["MIMOCODE_HOME": home, "MIMOCODE_DB": "channel.db"], home: "/unused")
            == home + "/data/channel.db")
        #expect(try VibeSyncMimocodeParser.resolveDbPath(
            environment: ["MIMOCODE_HOME": home, "MIMOCODE_DB": "/tmp/custom.db"], home: "/unused")
            == "/tmp/custom.db")
        #expect(try VibeSyncMimocodeParser.resolveDbPath(
            environment: ["MIMOCODE_HOME": home], home: "/unused")
            == home + "/data/mimicode.db")
        #expect(try VibeSyncMimocodeParser.resolveDbPath(
            environment: ["XDG_DATA_HOME": "/tmp/xdg-data"], home: "/unused")
            == "/tmp/xdg-data/mimicode/mimicode.db")
        #expect(try VibeSyncMimocodeParser.resolveDbPath(
            environment: [:], home: "/home/u")
            == "/home/u/.local/share/mimicode/mimicode.db")
        #expect(throws: VibeSyncMimocodeParser.ResolutionError.self) {
            try VibeSyncMimocodeParser.resolveDbPath(
                environment: ["MIMOCODE_HOME": "relative/mimo"], home: "/unused")
        }
    }

    @Test func readsExactTokenUsageAndSessionTiming() throws {
        let userCreated = Int(VibeSyncTime.parse("2026-07-27T08:00:00.000Z")!.timeIntervalSince1970 * 1000)
        let assistantCreated = Int(VibeSyncTime.parse("2026-07-27T08:10:00.000Z")!.timeIntervalSince1970 * 1000)
        let (root, path) = try fixtureDb(sql: Self.schema + """
            INSERT INTO session (id, directory) VALUES ('ses_1', '/repo/mimo-app');
            \(message("msg_user", "ses_1", userCreated, data: [
                "role": "user",
                "time": ["created": userCreated],
                "model": ["modelID": "mimo-v2.5-pro"],
            ]))
            \(message("msg_assistant", "ses_1", assistantCreated, data: [
                "role": "assistant",
                "time": ["created": assistantCreated, "completed": assistantCreated + 5_000],
                "modelID": "mimo-v2.5-pro",
                "tokens": [
                    "input": 120,
                    "output": 30,
                    "reasoning": 10,
                    "cache": ["read": 400, "write": 20],
                ],
            ]))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncMimocodeParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "mimocode")
        #expect(bucket.model == "mimo-v2.5-pro")
        #expect(bucket.project == "mimo-app")
        #expect(bucket.bucketStart == "2026-07-27T08:00:00.000Z")
        // cache writes fold into input, like the JS version.
        #expect(bucket.inputTokens == 140)
        #expect(bucket.outputTokens == 30)
        #expect(bucket.cachedInputTokens == 400)
        #expect(bucket.reasoningOutputTokens == 10)
        #expect(bucket.totalTokens == 180)

        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.source == "mimocode")
        #expect(session.project == "mimo-app")
        #expect(session.firstMessageAt == "2026-07-27T08:00:00.000Z")
        #expect(session.lastMessageAt == "2026-07-27T08:10:00.000Z")
        #expect(session.durationSeconds == 600)
        #expect(session.messageCount == 2)
        #expect(session.userMessageCount == 1)
    }

    @Test func excludesSessionsImportedFromOtherTools() throws {
        let created = Int(VibeSyncTime.parse("2026-07-27T09:00:00.000Z")!.timeIntervalSince1970 * 1000)
        let (root, path) = try fixtureDb(sql: Self.schema + """
            CREATE TABLE external_import (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              source TEXT NOT NULL
            );
            INSERT INTO session (id, directory) VALUES ('ses_native', '/repo/native');
            INSERT INTO session (id, directory) VALUES ('ses_imported', '/repo/imported');
            INSERT INTO external_import (id, session_id, source)
            VALUES ('import_1', 'ses_imported', 'claude-code');
            \(message("msg_native", "ses_native", created, data: [
                "role": "assistant",
                "time": ["created": created],
                "modelID": "mimo-v2.5-pro",
                "tokens": ["input": 10, "output": 5],
            ]))
            \(message("msg_imported", "ses_imported", created, data: [
                "role": "assistant",
                "time": ["created": created],
                "modelID": "claude-sonnet-4",
                "tokens": ["input": 1000, "output": 500],
            ]))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncMimocodeParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].model == "mimo-v2.5-pro")
        #expect(buckets[0].totalTokens == 15)
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions[0].project == "native")
    }

    @Test func returnsEmptySuccessWhenDatabaseIsMissing() throws {
        let result = try VibeSyncMimocodeParser(dbPath: "/tmp/does-not-exist-mimicode.db").parse()
        #expect(!result.skipped)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }
}
