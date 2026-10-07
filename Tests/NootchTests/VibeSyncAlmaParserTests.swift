import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/alma.test.js (macOS-reachable parts: the win32/
// linux path-resolution cases have no Swift counterpart).
@Suite struct VibeSyncAlmaParserTests {
    private static let schema = """
        CREATE TABLE usage_records (
          id TEXT PRIMARY KEY,
          message_id TEXT NOT NULL,
          thread_id TEXT NOT NULL,
          model TEXT,
          provider_id TEXT,
          input_tokens INTEGER DEFAULT 0,
          output_tokens INTEGER DEFAULT 0,
          cached_input_tokens INTEGER DEFAULT 0,
          reasoning_tokens INTEGER DEFAULT 0,
          timestamp TEXT NOT NULL,
          cache_write_input_tokens INTEGER DEFAULT 0
        );
        CREATE TABLE chat_threads (
          id TEXT PRIMARY KEY,
          workspace_id TEXT
        );
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY,
          path TEXT,
          name TEXT
        );
        CREATE TABLE messages (
          id TEXT PRIMARY KEY,
          body TEXT,
          metadata TEXT
        );
        """

    private func fixtureDb(rows: String, schema: String = Self.schema) throws -> (URL, URL) {
        let root = makeTempDirectory("alma")
        let path = root.appendingPathComponent("chat_threads.db")
        let fixture = try SQLiteFixture(at: path, sql: schema + rows)
        fixture.close()
        return (root, path)
    }

    @Test func resolvesOverrideAndElectronPaths() {
        #expect(VibeSyncAlmaParser.resolveDbPath(
            environment: ["VIBE_USAGE_ALMA_DB": "/tmp/alma.db"], home: "/unused") == "/tmp/alma.db")
        #expect(VibeSyncAlmaParser.resolveDbPath(
            environment: [:], home: "/Users/test")
            == "/Users/test/Library/Application Support/alma/chat_threads.db")
    }

    @Test func normalizeModelStripsProviderPrefixesAndHandlesInvalidValues() {
        #expect(VibeSyncAlmaParser.normalizeModel(
            "plugin:openai-codex-auth:openai-codex:gpt-5.4") == "gpt-5.4")
        #expect(VibeSyncAlmaParser.normalizeModel(
            "plugin:openai-codex-auth:openai-codex:gpt-5.6-sol") == "gpt-5.6-sol")
        #expect(VibeSyncAlmaParser.normalizeModel("motw9woq9az6u1r1cw:gpt-5.6-sol") == "gpt-5.6-sol")
        #expect(VibeSyncAlmaParser.normalizeModel("claude-sonnet") == "claude-sonnet")
        #expect(VibeSyncAlmaParser.normalizeModel("  claude-sonnet  ") == "claude-sonnet")
        #expect(VibeSyncAlmaParser.normalizeModel(nil) == "unknown")
        #expect(VibeSyncAlmaParser.normalizeModel("   ") == "unknown")
        #expect(VibeSyncAlmaParser.normalizeModel("provider:") == "unknown")
    }

    @Test func mergesProviderPrefixedFormsOfTheSameModelIntoOneBucket() throws {
        let (root, path) = try fixtureDb(rows: """
            INSERT INTO workspaces (id, path, name) VALUES
              ('ws_shared', '/Users/private/shared-project', 'Shared Project');
            INSERT INTO chat_threads (id, workspace_id) VALUES
              ('thread_1', 'ws_shared');
            INSERT INTO usage_records (
              id, message_id, thread_id, model, provider_id,
              input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
              timestamp, cache_write_input_tokens
            ) VALUES
              ('usage_1', 'message_1', 'thread_1', 'plugin:openai-codex-auth:openai-codex:gpt-5.6-sol', NULL,
               10, 3, 0, 0, '2026-08-06T09:05:00.000Z', 0),
              ('usage_2', 'message_2', 'thread_1', 'motw9woq9az6u1r1cw:gpt-5.6-sol', NULL,
               20, 7, 0, 0, '2026-08-06T09:25:00.000Z', 0);
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncAlmaParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "alma")
        #expect(bucket.model == "gpt-5.6-sol")
        #expect(bucket.project == "Shared Project")
        #expect(bucket.bucketStart == "2026-08-06T09:00:00.000Z")
        #expect(bucket.inputTokens == 30)
        #expect(bucket.outputTokens == 10)
        #expect(bucket.cachedInputTokens == 0)
        #expect(bucket.reasoningOutputTokens == 0)
        #expect(bucket.totalTokens == 40)
    }

    @Test func emitsUsageBucketsWithoutChatContentOrSessionMetadata() throws {
        let (root, path) = try fixtureDb(rows: """
            INSERT INTO workspaces (id, path, name) VALUES
              ('ws_named', '/Users/private/secret-repo', 'Public Project'),
              ('ws_path_name', '/Users/private/another-secret', '/Users/private/safe-basename');
            INSERT INTO chat_threads (id, workspace_id) VALUES
              ('thread_1', 'ws_named'),
              ('thread_2', 'ws_path_name');
            INSERT INTO messages (id, body, metadata) VALUES
              ('message_1', 'PRIVATE_ALMA_MESSAGE', 'PRIVATE_ALMA_METADATA');
            INSERT INTO usage_records (
              id, message_id, thread_id, model, provider_id,
              input_tokens, output_tokens, cached_input_tokens, reasoning_tokens,
              timestamp, cache_write_input_tokens
            ) VALUES
              ('usage_1', 'message_1', 'thread_1', 'claude-sonnet', 'private-provider',
               100, 30, 400, 10, '2026-08-06T09:05:00.000Z', 20),
              ('usage_2', 'message_2', 'thread_1', 'claude-sonnet', 'private-provider',
               50, 15, 0, 5, '2026-08-06T09:25:00.000Z', 0),
              ('usage_3', 'message_3', 'thread_2', NULL, NULL,
               7, 3, 2, 0, '2026-08-06T09:35:00.000Z', 1),
              ('usage_4', 'message_4', 'thread_2', 'model-x', NULL,
               1, 1, 0, 0, 'not-a-date', 0);
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncAlmaParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 2)

        let first = buckets[0]
        #expect(first.model == "claude-sonnet")
        #expect(first.project == "Public Project")
        #expect(first.bucketStart == "2026-08-06T09:00:00.000Z")
        #expect(first.inputTokens == 170)
        #expect(first.outputTokens == 45)
        #expect(first.cachedInputTokens == 400)
        #expect(first.reasoningOutputTokens == 15)
        #expect(first.totalTokens == 230)

        let second = buckets[1]
        #expect(second.model == "unknown")
        #expect(second.project == "safe-basename")
        #expect(second.bucketStart == "2026-08-06T09:30:00.000Z")
        #expect(second.inputTokens == 8)
        #expect(second.outputTokens == 3)
        #expect(second.cachedInputTokens == 2)
        #expect(second.reasoningOutputTokens == 0)
        #expect(second.totalTokens == 11)

        // Alma's usage ledger contains assistant responses only.
        #expect(result.events.isEmpty)
        #expect(vibeSessions(result).isEmpty)

        // Message bodies, workspace paths and provider ids never leave the DB.
        let serialized = String(data: try JSONEncoder().encode(buckets), encoding: .utf8)!
        #expect(!serialized.contains("PRIVATE_ALMA"))
        #expect(!serialized.contains("/Users/private"))
        #expect(!serialized.contains("private-provider"))
    }

    @Test func returnsEmptySuccessWhenDatabaseIsMissing() throws {
        let result = try VibeSyncAlmaParser(dbPath: "/tmp/does-not-exist-alma.db").parse()
        #expect(!result.skipped)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }

    @Test func protectsPriorStateWhenSchemaIsIncompatible() throws {
        let (root, path) = try fixtureDb(
            rows: "", schema: "CREATE TABLE unrelated (id TEXT PRIMARY KEY);")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try VibeSyncAlmaParser(dbPath: path.path).parse()
        #expect(result.skipped)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }
}
