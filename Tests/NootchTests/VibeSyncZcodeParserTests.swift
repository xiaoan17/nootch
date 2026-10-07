import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/zcode.test.js.
@Suite struct VibeSyncZcodeParserTests {
    // The real schema (ZCode 0.11) in the two tables the parser reads.
    private static let schema = """
        CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL);
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
          time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        """

    /// One assistant message. `modelKey` is the spelling under test: builds
    /// up to ZCode 0.10 wrote `modelID` (+ `providerID`), later builds wrote
    /// `modelId` (+ `providerId`).
    private func assistantRow(
        _ id: String, _ sessionId: String, _ ts: Int, modelKey: String, model: String
    ) -> String {
        let data: [String: Any] = [
            "role": "assistant",
            modelKey: model,
            "providerId": "builtin:zai-start-plan",
            "path": ["root": "/work/demo", "cwd": "/work/demo"],
            "tokens": [
                "total": 1100, "input": 1000, "output": 100, "reasoning": 10,
                "cache": ["read": 400, "write": 0],
            ],
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        return """
            INSERT INTO message VALUES (\(sqlQuote(id)), \(sqlQuote(sessionId)), \(ts), \(ts), \(sqlQuote(json)));
            """
    }

    private func fixtureDb(rows: String) throws -> (URL, URL) {
        let root = makeTempDirectory("zcode")
        let path = root.appendingPathComponent("db.sqlite")
        let fixture = try SQLiteFixture(at: path, sql: Self.schema + rows)
        fixture.close()
        return (root, path)
    }

    @Test func resolvesOverrideAndDefaultPath() {
        #expect(VibeSyncZcodeParser.resolveDbPath(
            environment: ["VIBE_USAGE_ZCODE_DB": "/tmp/zcode.sqlite"], home: "/unused")
            == "/tmp/zcode.sqlite")
        #expect(VibeSyncZcodeParser.resolveDbPath(
            environment: [:], home: "/home/u") == "/home/u/.zcode/cli/db/db.sqlite")
    }

    @Test func readsCurrentAndLegacyModelKeySpellings() throws {
        let (root, path) = try fixtureDb(rows: """
            INSERT INTO session VALUES ('s1','/work/demo');
            \(assistantRow("m1", "s1", 1_781_605_706_649, modelKey: "modelID", model: "GLM-5.2"))
            \(assistantRow("m2", "s1", 1_781_605_741_898, modelKey: "modelId", model: "GLM-5.3"))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncZcodeParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.map(\.model).sorted() == ["GLM-5.2", "GLM-5.3"])
        for bucket in buckets {
            #expect(bucket.project == "demo")
            #expect(bucket.inputTokens == 600)
            #expect(bucket.cachedInputTokens == 400)
            #expect(bucket.outputTokens == 90)
            #expect(bucket.reasoningOutputTokens == 10)
            // Bucket totalTokens is input + output + reasoning; the server
            // re-adds cached input when it computes the displayed 总 Token.
            #expect(bucket.totalTokens == 700)
        }
    }

    @Test func reportsUnknownForAssistantMessageWithoutAnyModelKey() throws {
        let (root, path) = try fixtureDb(rows: """
            INSERT INTO session VALUES ('s1','/work/demo');
            INSERT INTO message VALUES ('m1','s1',1781605706649,1781605706649,'{"role":"assistant","tokens":{"input":10,"output":5}}');
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncZcodeParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        #expect(vibeBuckets(result).map(\.model) == ["unknown"])
    }

    @Test func fallsBackToSessionDirectoryWhenMessageHasNoPath() throws {
        let (root, path) = try fixtureDb(rows: """
            INSERT INTO session VALUES ('s1','/work/from-session');
            INSERT INTO message VALUES ('m1','s1',1781605706649,1781605706649,'{"role":"assistant","modelID":"GLM-5.2","tokens":{"input":10,"output":5}}');
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncZcodeParser(dbPath: path.path).parse()
        let bucket = try #require(vibeBuckets(result).first)
        #expect(bucket.project == "from-session")
    }

    @Test func returnsEmptySuccessWhenDatabaseIsMissing() throws {
        let result = try VibeSyncZcodeParser(dbPath: "/tmp/does-not-exist-zcode.sqlite").parse()
        #expect(!result.skipped)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }
}
