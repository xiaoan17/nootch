import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/mcode.test.js.
@Suite struct VibeSyncMcodeParserTests {
    private static let schema = """
        CREATE TABLE local_runtime_sessions (
         session_id TEXT PRIMARY KEY, workspace_dir TEXT, project_workspace_dir TEXT
        );
        CREATE TABLE local_runtime_token_usage (
         id INTEGER PRIMARY KEY, session_id TEXT, agent_name TEXT, framework_type TEXT,
         turn_id TEXT, model TEXT, ts INTEGER, input_tokens INTEGER, output_tokens INTEGER,
         reasoning_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
         cost_usd REAL, raw TEXT
        );
        """

    private func token(
        _ session: String, _ ts: Any, _ input: Any, _ output: Any, _ reasoning: Any,
        _ read: Any, _ write: Any, model: String = "mcode-model"
    ) -> String {
        func value(_ v: Any) -> String {
            if v is NSNull { return "NULL" }
            if let string = v as? String { return sqlQuote(string) }
            return String(describing: v)
        }
        return """
            INSERT INTO local_runtime_token_usage VALUES (NULL,\(sqlQuote(session)),'agent','pi','turn',\
            \(sqlQuote(model)),\(value(ts)),\(value(input)),\(value(output)),\(value(reasoning)),\
            \(value(read)),\(value(write)),0,NULL);
            """
    }

    @discardableResult
    private func writeDb(_ path: URL, sql: String) throws -> URL {
        let fixture = try SQLiteFixture(at: path, sql: sql)
        fixture.close()
        return path
    }

    @Test func resolvesEnvOverrides() throws {
        #expect(try VibeSyncMcodeParser.resolveDbPath(
            environment: ["VIBE_USAGE_MCODE_DB": "/tmp/mcode.db"], home: "/unused") == "/tmp/mcode.db")
        let home = "/tmp/minimax"
        #expect(try VibeSyncMcodeParser.resolveDbPath(
            environment: ["MCODE_HOME": home], home: "/unused") == home + "/v2/sqlite/runtime-state.sqlite")
        // The mcode CLI itself relocates the whole data root with these two variables.
        #expect(try VibeSyncMcodeParser.resolveDbPath(
            environment: ["MINIMAX_DATA_DIR": home], home: "/unused") == home + "/v2/sqlite/runtime-state.sqlite")
        #expect(try VibeSyncMcodeParser.resolveDbPath(
            environment: ["MAVIS_DATA_DIR": home], home: "/unused") == home + "/v2/sqlite/runtime-state.sqlite")
        // Fixture override beats the CLI's own variables, which keep their order.
        #expect(try VibeSyncMcodeParser.resolveDbPath(
            environment: ["MCODE_HOME": "/tmp/mcode-home", "MINIMAX_DATA_DIR": home],
            home: "/unused") == "/tmp/mcode-home/v2/sqlite/runtime-state.sqlite")
        #expect(throws: VibeSyncMcodeParser.ResolutionError.self) {
            try VibeSyncMcodeParser.resolveDbPath(
                environment: ["MINIMAX_DATA_DIR": "relative/minimax"], home: "/unused")
        }
        #expect(throws: VibeSyncMcodeParser.ResolutionError.self) {
            try VibeSyncMcodeParser.resolveDbPaths(
                environment: ["MAVIS_DATA_DIR": "relative/mavis"], home: "/unused")
        }
    }

    @Test func scansProfilePreNpmAndPreRenameStoresOnceEach() throws {
        let home = makeTempDirectory("mcode-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let rel = "v2/sqlite/runtime-state.sqlite"
        let primary = home.appendingPathComponent(".minimax/\(rel)")
        let legacy = home.appendingPathComponent(".minimax-code/\(rel)")
        let profile = home.appendingPathComponent(".minimax-work/\(rel)")
        let row = token("s1", 1_787_935_277_463, 10, 2, 0, 0, 0)

        try writeDb(primary, sql: Self.schema
            + "INSERT INTO local_runtime_sessions VALUES ('s1','/work/primary',NULL);" + row)
        // A pre-npm source-build store keeps its own history…
        try writeDb(legacy, sql: Self.schema
            + "INSERT INTO local_runtime_sessions VALUES ('s1','/work/primary',NULL);"
            + "INSERT INTO local_runtime_sessions VALUES ('s9','/work/old',NULL);"
            + row + token("s9", 1_787_931_677_463, 3, 1, 0, 0, 0))
        try writeDb(profile, sql: Self.schema
            + "INSERT INTO local_runtime_sessions VALUES ('s2','/work/profile',NULL);"
            + token("s2", 1_787_935_277_463, 5, 0, 0, 2, 0))
        // …while the CLI's compat migration leaves ~/.mavis pointing at ~/.minimax.
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".mavis"),
            withDestinationURL: home.appendingPathComponent(".minimax"))

        #expect(try VibeSyncMcodeParser.resolveDbPaths(environment: [:], home: home.path)
            == [primary.path, legacy.path, profile.path])

        let result = try VibeSyncMcodeParser(environment: [:], home: home.path).parse()
        #expect(!result.skipped)
        let rows = vibeBuckets(result)
            .map { [$0.project, String($0.inputTokens), String($0.cachedInputTokens), String($0.outputTokens)] }
            .sorted { $0.lexicographicallyPrecedes($1) }
        #expect(rows == [
            ["old", "3", "0", "1"],
            ["primary", "10", "0", "2"],
            ["profile", "5", "2", "0"],
        ])
    }

    @Test func aggregatesMillisecondsBasenameCacheAndSeparateReasoning() throws {
        let root = makeTempDirectory("mcode")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try writeDb(root.appendingPathComponent("runtime-state.sqlite"), sql: Self.schema + """
            INSERT INTO local_runtime_sessions VALUES ('s1','/tmp/s1/workspace','/fixtures/project-a');
            INSERT INTO local_runtime_sessions VALUES ('s2',NULL,NULL);
            \(token("s1", 1_787_935_277_463, 10, 9, 3, 4, 5))
            \(token("s1", 1_787_935_285_209, 2, 4, 0, 1, 0))
            \(token("s2", 1_787_935_285_209, NSNull(), NSNull(), NSNull(), NSNull(), NSNull()))
            """)

        let result = try VibeSyncMcodeParser(dbPaths: [path.path]).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.project == "project-a")
        #expect(bucket.inputTokens == 17)
        #expect(bucket.cachedInputTokens == 5)
        #expect(bucket.outputTokens == 13)
        #expect(bucket.reasoningOutputTokens == 3)
        #expect(bucket.totalTokens == 33)
        #expect(result.events.isEmpty)
    }

    @Test func clampsMalformedNegativeAndReasoningValuesAndHandlesSeconds() throws {
        let root = makeTempDirectory("mcode")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try writeDb(root.appendingPathComponent("runtime-state.sqlite"), sql: Self.schema + """
            INSERT INTO local_runtime_sessions VALUES ('s1','/tmp/project-b/',NULL);
            \(token("s1", 1_787_935_200, -3, 2, 9, "bad", 1))
            """)

        let result = try VibeSyncMcodeParser(dbPaths: [path.path]).parse()
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].project == "project-b")
        #expect(buckets[0].inputTokens == 1)
        #expect(buckets[0].cachedInputTokens == 0)
        #expect(buckets[0].outputTokens == 2)
        #expect(buckets[0].reasoningOutputTokens == 9)
    }

    @Test func returnsSkippedForMissingOrIncompatibleDatabases() throws {
        let missing = try VibeSyncMcodeParser(dbPaths: ["/tmp/does-not-exist-mcode.sqlite"]).parse()
        #expect(!missing.skipped)
        #expect(missing.entries.isEmpty)

        let root = makeTempDirectory("mcode")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try writeDb(
            root.appendingPathComponent("runtime-state.sqlite"),
            sql: "CREATE TABLE local_runtime_token_usage (session_id TEXT);")
        let result = try VibeSyncMcodeParser(dbPaths: [path.path]).parse()
        #expect(result.skipped)
        #expect(result.entries.isEmpty)
    }

    @Test func keepsTheLiveStoreWhenAnExtraStoreIsIncompatible() throws {
        let home = makeTempDirectory("mcode-extra")
        defer { try? FileManager.default.removeItem(at: home) }
        let rel = "v2/sqlite/runtime-state.sqlite"
        try writeDb(home.appendingPathComponent(".minimax/\(rel)"), sql: Self.schema
            + "INSERT INTO local_runtime_sessions VALUES ('s1','/work/live',NULL);"
            + token("s1", 1_787_935_277_463, 4, 2, 0, 0, 0))
        // A leftover profile store this build cannot read must surface as a
        // warning (logged), not blank the store the CLI is actually writing to.
        try writeDb(
            home.appendingPathComponent(".minimax-broken/\(rel)"),
            sql: "CREATE TABLE local_runtime_token_usage (session_id TEXT);")

        let result = try VibeSyncMcodeParser(environment: [:], home: home.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].project == "live")
        #expect(buckets[0].inputTokens == 4)
    }
}
