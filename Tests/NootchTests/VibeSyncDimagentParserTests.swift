import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/dimagent.test.js.
@Suite struct VibeSyncDimagentParserTests {
    private static let schema = """
        CREATE TABLE sessions (
          sessionId TEXT PRIMARY KEY,
          cwd TEXT NOT NULL
        );
        CREATE TABLE usage_ledger (
          ledgerId TEXT PRIMARY KEY,
          sessionId TEXT NOT NULL,
          runId TEXT,
          providerId TEXT NOT NULL,
          modelId TEXT NOT NULL,
          usage TEXT NOT NULL,
          cost REAL,
          createdAt TEXT NOT NULL
        );
        CREATE TABLE messages (
          messageId TEXT PRIMARY KEY,
          sessionId TEXT NOT NULL,
          role TEXT NOT NULL,
          createdAt TEXT NOT NULL
        );
        """

    private func fixtureDb(sql: String) throws -> (URL, URL) {
        let root = makeTempDirectory("dimagent")
        let path = root.appendingPathComponent("dimcode.sqlite")
        let fixture = try SQLiteFixture(at: path, sql: sql)
        fixture.close()
        return (root, path)
    }

    @Test func resolvesEnvOverrides() {
        #expect(VibeSyncDimagentParser.resolveDbPath(
            environment: ["VIBE_USAGE_DIMAGENT_DB": "/tmp/dim.sqlite"], home: "/unused")
            == "/tmp/dim.sqlite")
        #expect(VibeSyncDimagentParser.resolveDbPath(
            environment: ["DIMCODE_HOME": "/tmp/dimcode"], home: "/unused")
            == "/tmp/dimcode/dimcode.sqlite")
        #expect(VibeSyncDimagentParser.resolveDbPath(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg-config"], home: "/unused")
            == "/tmp/xdg-config/.dimcode/v2/dimcode.sqlite")
        #expect(VibeSyncDimagentParser.resolveDbPath(
            environment: [:], home: "/home/u")
            == "/home/u/.dimcode/v2/dimcode.sqlite")
    }

    @Test func readsUsageAndExcludesForkedCopies() throws {
        let (root, path) = try fixtureDb(sql: Self.schema + """
            INSERT INTO sessions VALUES
              ('main', '/work/example-app'),
              ('fork', '/work/example-app'),
              ('fork-2', '/work/example-app');

            INSERT INTO usage_ledger VALUES
              ('usage_run-1', 'main', 'run-1', 'dim', 'gpt-main',
               '{"promptTokens":100,"completionTokens":20,"totalTokens":120,"cacheReadTokens":40}',
               NULL, '2026-07-01T00:10:00.000Z'),
              ('ledger_11111111-1111-4111-8111-111111111111', 'fork', 'run-1', 'dim', 'gpt-main',
               '{"promptTokens":100,"completionTokens":20,"totalTokens":120,"cacheReadTokens":40}',
               NULL, '2026-07-01T00:10:00.000Z'),
              ('plugin_ledger_original', 'main', NULL, 'dim', 'plugin-model',
               '{"promptTokens":30,"completionTokens":5,"totalTokens":35}',
               NULL, '2026-07-01T00:20:00.000Z'),
              ('ledger_22222222-2222-4222-8222-222222222222', 'fork', NULL, 'dim', 'plugin-model',
               '{"promptTokens":30,"completionTokens":5,"totalTokens":35}',
               NULL, '2026-07-01T00:20:00.000Z'),
              ('ledger_33333333-3333-4333-8333-333333333333', 'fork', NULL, 'dim', 'orphan-model',
               '{"promptTokens":50,"completionTokens":10,"totalTokens":60,"cacheReadTokens":20}',
               NULL, '2026-07-01T00:25:00.000Z'),
              ('ledger_44444444-4444-4444-8444-444444444444', 'fork-2', NULL, 'dim', 'orphan-model',
               '{"promptTokens":50,"completionTokens":10,"totalTokens":60,"cacheReadTokens":20}',
               NULL, '2026-07-01T00:25:00.000Z'),
              ('ledger_1700000000000_1', 'main', NULL, 'dim', 'cache-write-model',
               '{"promptTokens":80,"completionTokens":8,"totalTokens":88,"cacheReadTokens":20,"cacheWriteTokens":30}',
               NULL, '2026-07-01T00:26:00.000Z'),
              ('bad-json', 'main', NULL, 'dim', 'bad-model',
               '{', NULL, '2026-07-01T00:27:00.000Z');

            INSERT INTO messages VALUES
              ('main-user-1', 'main', 'user', '2026-07-01T00:00:00.000Z'),
              ('main-assistant-1', 'main', 'assistant', '2026-07-01T00:00:05.000Z'),
              ('main-assistant-2', 'main', 'assistant', '2026-07-01T00:00:10.000Z'),
              ('main-user-2', 'main', 'user', '2026-07-01T00:05:00.000Z'),
              ('main-assistant-3', 'main', 'assistant', '2026-07-01T00:05:03.000Z'),
              ('msg_fork_1_user', 'fork', 'user', '2026-07-01T00:00:00.000Z'),
              ('msg_fork_1_assistant', 'fork', 'assistant', '2026-07-01T00:00:10.000Z'),
              ('fork-user', 'fork', 'user', '2026-07-01T00:06:00.000Z'),
              ('fork-assistant', 'fork', 'assistant', '2026-07-01T00:06:04.000Z');
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncDimagentParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        let byModel = Dictionary(uniqueKeysWithValues: buckets.map { ($0.model, $0) })

        // Forked copy of run-1 dropped; promptTokens include the cache read.
        let main = try #require(byModel["gpt-main"])
        #expect(main.inputTokens == 60)
        #expect(main.outputTokens == 20)
        #expect(main.cachedInputTokens == 40)

        // Forked copy of the plugin ledger row dropped.
        #expect(byModel["plugin-model"]?.inputTokens == 30)
        // Orphan clones (no surviving original) are kept exactly once.
        #expect(byModel["orphan-model"]?.inputTokens == 30)
        // cacheWriteTokens are not part of the ledger math upstream.
        #expect(byModel["cache-write-model"]?.inputTokens == 60)
        #expect(buckets.count == 4)

        let sessions = vibeSessions(result)
        #expect(sessions.count == 2)
        let mainSession = try #require(sessions.first { $0.userMessageCount == 2 })
        let forkSession = try #require(sessions.first { $0.userMessageCount == 1 })
        #expect(mainSession.project == "example-app")
        #expect(mainSession.messageCount == 5)
        #expect(mainSession.activeSeconds == 5)
        #expect(forkSession.messageCount == 2)
    }

    @Test func returnsEmptySuccessWhenDatabaseIsMissing() throws {
        let result = try VibeSyncDimagentParser(dbPath: "/tmp/does-not-exist-dimagent.sqlite").parse()
        #expect(!result.skipped)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }
}
