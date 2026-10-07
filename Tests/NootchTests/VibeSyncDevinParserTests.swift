import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/devin.test.js.
@Suite struct VibeSyncDevinParserTests {
    private static let schema = """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          working_directory TEXT NOT NULL,
          backend_type TEXT NOT NULL,
          model TEXT NOT NULL,
          agent_mode TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          last_activity_at INTEGER NOT NULL,
          title TEXT, main_chain_id INTEGER, shell_last_seen_index INTEGER DEFAULT 0,
          cogs_json TEXT, workspace_dirs TEXT, hidden INTEGER NOT NULL DEFAULT 0,
          metadata TEXT
        );
        CREATE TABLE message_nodes (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          node_id INTEGER NOT NULL,
          parent_node_id INTEGER,
          chat_message TEXT NOT NULL,
          created_at INTEGER NOT NULL, metadata TEXT
        );
        """

    private func insertSession(_ id: String, _ directory: String, model: String = "swe-2-high") -> String {
        """
        INSERT INTO sessions (id, working_directory, backend_type, model, agent_mode,
          created_at, last_activity_at, workspace_dirs, hidden, metadata)
          VALUES (\(sqlQuote(id)), \(sqlQuote(directory)), 'windsurf', \(sqlQuote(model)), 'accept-edits',
          1789525600, 1789526800, '[]', 0, '{"total_credit_cost":0,"total_acu_cost":1.5}');
        """
    }

    private func metrics(
        _ input: Int, _ output: Int, _ cacheRead: Int, _ cacheCreation: Int?
    ) -> [String: Any] {
        [
            "ttft_ms": 10, "total_time_ms": 100, "tpot_ms": 1, "tokens_per_sec": 50,
            "input_tokens": input, "output_tokens": output,
            "cache_read_tokens": cacheRead,
            "cache_creation_tokens": cacheCreation ?? NSNull(),
        ]
    }

    private func msg(
        _ session: String, _ node: Int, _ role: String, _ createdSec: Int,
        messageId: String? = nil, isUserInput: Int? = nil, iso: String? = nil,
        generationModel: String? = nil, metrics: [String: Any]? = nil
    ) -> String {
        var metadata: [String: Any] = [
            "num_tokens": NSNull(), "is_user_input": isUserInput ?? NSNull(),
            "request_id": NSNull(), "metrics": metrics ?? NSNull(),
            "finish_reason": NSNull(), "created_at": iso ?? NSNull(),
            "generation_model": generationModel ?? NSNull(),
            "telemetry": ["source": role, "operation": "inference"],
        ]
        metadata["is_user_input"] = isUserInput ?? NSNull()
        let chat: [String: Any] = [
            "message_id": messageId ?? "m-\(session)-\(node)",
            "role": role,
            "content": "body",
            "metadata": metadata,
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: chat), encoding: .utf8)!
        return """
            INSERT INTO message_nodes (session_id, node_id, parent_node_id, chat_message, created_at)
              VALUES (\(sqlQuote(session)), \(node), NULL, \(sqlQuote(json)), \(createdSec));
            """
    }

    private func fixtureDb(rows: String, schema: String = Self.schema) throws -> (URL, URL) {
        let root = makeTempDirectory("devin")
        let path = root.appendingPathComponent("sessions.db")
        let fixture = try SQLiteFixture(at: path, sql: schema + rows)
        fixture.close()
        return (root, path)
    }

    @Test func resolvesEnvAndXdgPaths() {
        #expect(VibeSyncDevinParser.resolveDbPath(
            environment: ["VIBE_USAGE_DEVIN_DB": "/tmp/devin.db"], home: "/unused") == "/tmp/devin.db")
        #expect(VibeSyncDevinParser.resolveDbPath(
            environment: ["XDG_DATA_HOME": "/tmp/xdg"], home: "/unused") == "/tmp/xdg/devin/cli/sessions.db")
        #expect(VibeSyncDevinParser.resolveDbPath(
            environment: [:], home: "/home/u") == "/home/u/.local/share/devin/cli/sessions.db")
    }

    @Test func aggregatesMetricsWithCacheCreationFoldedIntoInput() throws {
        let (root, path) = try fixtureDb(rows: """
            \(insertSession("s1", "/Users/x/Coding/proj-a"))
            \(msg("s1", 1, "user", 1_789_525_600, isUserInput: 1, iso: "2026-09-16T02:27:00.000Z"))
            \(msg("s1", 2, "assistant", 1_789_525_640, iso: "2026-09-16T02:27:20.000Z",
                 generationModel: "claude-fable-5-1-medium", metrics: metrics(4, 203, 19_126, 8_804)))
            \(msg("s1", 3, "assistant", 1_789_525_700, iso: "2026-09-16T02:28:20.000Z",
                 generationModel: "claude-fable-5-1-medium", metrics: metrics(320, 103, 17_533, nil)))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncDevinParser(dbPath: path.path).parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "devin")
        #expect(bucket.project == "proj-a")
        #expect(bucket.model == "claude-fable-5-1-medium")
        #expect(bucket.inputTokens == 4 + 8_804 + 320)
        #expect(bucket.outputTokens == 203 + 103)
        #expect(bucket.cachedInputTokens == 19_126 + 17_533)
        #expect(bucket.reasoningOutputTokens == 0)
        #expect(bucket.totalTokens == bucket.inputTokens + bucket.outputTokens + bucket.reasoningOutputTokens)
    }

    @Test func deduplicatesForestCopiedMessageNodesByMessageId() throws {
        let (root, path) = try fixtureDb(rows: """
            \(insertSession("s1", "/p/proj"))
            \(msg("s1", 1, "user", 1_789_525_600, isUserInput: 1, iso: "2026-09-16T02:26:00.000Z"))
            \(msg("s1", 2, "assistant", 1_789_525_640, messageId: "dup-1", iso: "2026-09-16T02:27:20.000Z",
                 metrics: metrics(10, 20, 30, 40)))
            \(msg("s1", 3, "assistant", 1_789_525_640, messageId: "dup-1", iso: "2026-09-16T02:27:20.000Z",
                 metrics: metrics(10, 20, 30, 40)))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncDevinParser(dbPath: path.path).parse()
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        #expect(buckets[0].inputTokens == 50)
        #expect(buckets[0].outputTokens == 20)
        #expect(buckets[0].cachedInputTokens == 30)
        // The duplicated node must not double-count session messages either.
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions[0].messageCount == 2)
        #expect(sessions[0].userMessageCount == 1)
    }

    @Test func splitsModelsPerMessageAndFallsBackToTheSessionModel() throws {
        let (root, path) = try fixtureDb(rows: """
            \(insertSession("s1", "/p/proj", model: "swe-2-high"))
            \(msg("s1", 1, "user", 1_789_525_600, isUserInput: 1, iso: "2026-09-16T02:27:00.000Z"))
            \(msg("s1", 2, "assistant", 1_789_525_640, iso: "2026-09-16T02:27:20.000Z",
                 generationModel: "claude-opus-5-medium", metrics: metrics(1, 2, 0, 0)))
            \(msg("s1", 3, "assistant", 1_789_525_700, iso: "2026-09-16T02:28:20.000Z",
                 metrics: metrics(3, 4, 0, 0)))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncDevinParser(dbPath: path.path).parse()
        let byModel = Dictionary(uniqueKeysWithValues: vibeBuckets(result).map { ($0.model, $0) })
        #expect(byModel["claude-opus-5-medium"]?.outputTokens == 2)
        #expect(byModel["swe-2-high"]?.outputTokens == 4)
    }

    @Test func countsOnlyIsUserInputPromptsAndSkipsSystemAndKeepaliveRows() throws {
        let (root, path) = try fixtureDb(rows: """
            \(insertSession("s1", "/p/proj"))
            \(msg("s1", 1, "system", 1_789_525_500, iso: "2026-09-16T02:25:00.000Z"))
            \(msg("s1", 2, "user", 1_789_525_600, isUserInput: 1, iso: "2026-09-16T02:26:40.000Z"))
            \(msg("s1", 3, "assistant", 1_789_525_640, iso: "2026-09-16T02:27:20.000Z",
                 metrics: metrics(5, 10, 0, 0)))
            \(msg("s1", 4, "tool", 1_789_525_660, iso: "2026-09-16T02:27:40.000Z"))
            \(msg("s1", 5, "user", 1_789_525_800, iso: "2026-09-16T02:30:00.000Z"))
            \(msg("s1", 6, "assistant", 1_789_525_810, iso: "2026-09-16T02:30:10.000Z",
                 metrics: metrics(2, 3, 0, 0)))
            \(insertSession("keepalive-only", "/p/idle"))
            \(msg("keepalive-only", 1, "user", 1_789_526_000))
            \(msg("keepalive-only", 2, "assistant", 1_789_526_010, iso: "2026-09-16T02:33:30.000Z",
                 metrics: metrics(7, 8, 0, 0)))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncDevinParser(dbPath: path.path).parse()
        // Keepalive-only session still contributes its real token usage. The
        // three assistant metrics land in three distinct (project × half-hour)
        // buckets: s1@02:00, s1@02:30 and keepalive-only@02:30.
        #expect(vibeBuckets(result).count == 3)
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.source == "devin")
        #expect(session.userMessageCount == 1)
        // system row excluded; user + 2 assistant + tool + keepalive-as-assistant
        #expect(session.messageCount == 5)
        #expect(session.firstMessageAt == "2026-09-16T02:26:40.000Z")
        #expect(session.lastMessageAt == "2026-09-16T02:30:10.000Z")
    }

    @Test func fallsBackToNodeCreatedAtSecondsWhenIsoIsMissing() throws {
        let (root, path) = try fixtureDb(rows: """
            \(insertSession("s1", "/p/proj"))
            \(msg("s1", 1, "user", 1_789_525_600, isUserInput: 1))
            \(msg("s1", 2, "assistant", 1_789_525_640, metrics: metrics(1, 1, 0, 0)))
            """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try VibeSyncDevinParser(dbPath: path.path).parse()
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let expected = Date(timeIntervalSince1970: 1_789_525_640)
        #expect(buckets[0].bucketStart == VibeSyncTime.isoString(VibeSyncTime.roundToHalfHour(expected)))
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions[0].firstMessageAt == VibeSyncTime.isoString(Date(timeIntervalSince1970: 1_789_525_600)))
    }

    @Test func returnsSkippedForMissingOrIncompatibleDatabases() throws {
        let missing = try VibeSyncDevinParser(dbPath: "/tmp/does-not-exist-devin.db").parse()
        #expect(!missing.skipped)
        #expect(missing.entries.isEmpty)
        #expect(missing.events.isEmpty)

        let (root, path) = try fixtureDb(rows: "", schema: "CREATE TABLE message_nodes (session_id TEXT);")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try VibeSyncDevinParser(dbPath: path.path).parse()
        #expect(result.skipped)
        #expect(result.entries.isEmpty)
    }
}
