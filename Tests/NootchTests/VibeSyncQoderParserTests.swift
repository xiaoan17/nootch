import Foundation
import Testing
@testable import Nootch

// Swift port of vibe-usage test/qoder.test.js (upstream 5380334 + the
// routing-tier namespacing fix 3f82a4e). The fixtures copy the verified real
// shapes: transcripts are Claude Code-shaped records whose `message.usage` is
// credit-billed with every token field 0; the IDE local.db holds chat_message
// rows with token_info/model_info JSON. Parsers are constructed with explicit
// projects/db paths instead of mutating process env, so tests can run in
// parallel; the env-var precedence itself is covered against the static
// resolve* functions.
@Suite("VibeSyncQoderParser")
struct VibeSyncQoderParserTests {
    private static let session = "c5def458-9572-4e68-97c8-aa9791ba9502"
    private static let cwd = "/Users/jiangbian/Documents/projects/demo-app"
    private static let slug = "-Users-jiangbian-Documents-projects-demo-app"

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func record(_ type: String, extra: [String: Any]) throws -> String {
        var base: [String: Any] = [
            "type": type,
            "sessionId": Self.session,
            "cwd": Self.cwd,
            "userType": "external",
            "entrypoint": "cli",
            "version": "1.1.42",
            "isSidechain": false,
        ]
        base.merge(extra) { _, new in new }
        return try jsonLine(base)
    }

    /// Credit-billed usage as Qoder writes it: every token field is 0.
    private func creditUsage(_ credits: Double, billable: Bool = true) -> [String: Any] {
        [
            "input_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "output_tokens": 0,
            "server_tool_use": ["web_search_requests": 0, "web_fetch_requests": 0],
            "service_tier": "standard",
            "credits": credits,
            "original_credits": credits,
            "billable": billable,
            "request_id": "ff8ffcf2-e225-4590-a184-f21866407541",
            "context_usage_ratio": 0.099925,
        ]
    }

    /// Write <projectsDir>/<slug>/<session>.jsonl plus a nested sub-agent
    /// transcript, mirroring the upstream fixture (real Qoder CLI 1.1.42 /
    /// desktop app 0.1.6 shapes; prompt text removed).
    private func writeTranscript(projectsDir: URL, withTokens: Bool = false) throws {
        let dir = projectsDir.appendingPathComponent(Self.slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var tokenUsage = creditUsage(0.17894)
        if withTokens {
            tokenUsage["input_tokens"] = 1200
            tokenUsage["cache_creation_input_tokens"] = 300
            tokenUsage["cache_read_input_tokens"] = 9500
            tokenUsage["output_tokens"] = 40
        }
        let lines = try [
            jsonLine(["type": "workspace-directories", "sessionId": Self.session, "directories": [Self.cwd]]),
            jsonLine(["type": "runtime-config", "sessionId": Self.session, "model": "efficient", "timestamp": 1_788_453_798_496]),
            record("user", extra: [
                "uuid": "u1",
                "timestamp": "2026-09-03T16:43:22.740Z",
                "humanInput": ["text": "hi", "mode": "prompt"],
                "origin": ["kind": "human"],
                "message": ["role": "user", "content": "hi"],
            ]),
            jsonLine(["type": "attachment", "sessionId": Self.session, "timestamp": "2026-09-03T16:43:22.740Z", "attachment": [:]]),
            // One assistant message written as several lines; only the last carries usage.
            record("assistant", extra: [
                "uuid": "a1",
                "timestamp": "2026-09-03T16:43:25.697Z",
                "message": ["id": "resp_1", "role": "assistant", "model": "efficient", "content": [["type": "thinking"]]],
            ]),
            record("assistant", extra: [
                "uuid": "a2",
                "timestamp": "2026-09-03T16:43:25.697Z",
                "message": [
                    "id": "resp_1", "role": "assistant", "model": "efficient",
                    "content": [["type": "text", "text": "ok"]],
                    "usage": withTokens ? tokenUsage : creditUsage(0.17894107142857144),
                ],
            ]),
            // Tool result comes back as a user-role record: not a human prompt.
            record("user", extra: [
                "uuid": "u2",
                "timestamp": "2026-09-03T16:43:26.000Z",
                "toolUseResult": ["isHardFailure": false],
                "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "done"]]],
            ]),
            record("user", extra: [
                "uuid": "u3",
                "timestamp": "2026-09-03T16:50:00.000Z",
                "humanInput": ["text": "again", "mode": "prompt"],
                "message": ["role": "user", "content": "again"],
            ]),
            record("assistant", extra: [
                "uuid": "a3",
                "timestamp": "2026-09-03T16:50:03.000Z",
                "message": [
                    "id": "resp_2", "role": "assistant", "model": "auto",
                    "content": [["type": "text", "text": "ok"]],
                    "usage": creditUsage(4.2203, billable: false),
                ],
            ]),
            jsonLine(["type": "active-leaf", "sessionId": Self.session, "leafUuid": "a3", "timestamp": 1_788_455_350_190]),
            "not json",
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("\(Self.session).jsonl"), atomically: true, encoding: .utf8)

        // Sub-agent transcript nested under <session>/subagents/.
        let subDir = dir.appendingPathComponent("\(Self.session)/subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let subLine = try record("assistant", extra: [
            "uuid": "s1",
            "timestamp": "2026-09-03T16:50:20.000Z",
            "message": [
                "id": "resp_sub", "role": "assistant", "model": "auto",
                "content": [["type": "text", "text": "sub"]],
                "usage": creditUsage(1.5),
            ],
        ])
        try (subLine + "\n")
            .write(to: subDir.appendingPathComponent("agent-x1.jsonl"), atomically: true, encoding: .utf8)
    }

    // MARK: - Transcripts

    @Test("credit-billed transcripts yield sessions but no token buckets")
    func creditTranscriptsYieldSessionsOnly() throws {
        let root = makeTempDirectory("qoder-transcripts")
        let projectsDir = root.appendingPathComponent("projects")
        try writeTranscript(projectsDir: projectsDir)
        let parser = VibeSyncQoderParser(
            edition: .international,
            projectsDir: projectsDir.path,
            dbPath: root.appendingPathComponent("missing.db").path)
        let result = try parser.parse()
        #expect(!result.skipped)
        // All token fields are 0 in Qoder transcripts and credits are not collected.
        #expect(result.entries.isEmpty)

        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.source == "qoder")
        #expect(session.project == "demo-app")
        // Two human prompts; the tool_result user record is not one.
        #expect(session.userMessageCount == 2)
        // 2 user + 3 assistant lines in the main file + 1 sub-agent assistant line.
        #expect(session.messageCount == 6)
    }

    @Test("transcript token fields are counted when a build reports them, once per message id")
    func transcriptTokensCountedOncePerMessage() throws {
        let root = makeTempDirectory("qoder-tokens")
        let projectsDir = root.appendingPathComponent("projects")
        try writeTranscript(projectsDir: projectsDir, withTokens: true)
        let parser = VibeSyncQoderParser(
            edition: .international,
            projectsDir: projectsDir.path,
            dbPath: root.appendingPathComponent("missing.db").path)
        let buckets = vibeBuckets(try parser.parse())
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "qoder")
        // Routing tiers are namespaced so they never collide with a priced model id.
        #expect(bucket.model == "qoder-efficient")
        #expect(bucket.project == "demo-app")
        #expect(bucket.inputTokens == 1200 + 300)
        #expect(bucket.cachedInputTokens == 9500)
        #expect(bucket.outputTokens == 40)
    }

    @Test("qoder-cn: same transcript shape under its own source")
    func qoderCnSource() throws {
        let root = makeTempDirectory("qoder-cn")
        let projectsDir = root.appendingPathComponent("projects")
        try writeTranscript(projectsDir: projectsDir)
        let parser = VibeSyncQoderParser(
            edition: .cn,
            projectsDir: projectsDir.path,
            dbPath: root.appendingPathComponent("missing.db").path)
        let result = try parser.parse()
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions.allSatisfy { $0.source == "qoder-cn" })
        #expect(result.events.allSatisfy { $0.source == "qoder-cn" })
    }

    // MARK: - IDE local.db

    /// Rows copied from a real Qoder IDE 1.28.0 local.db (2026-09-04), content
    /// columns present in the schema but never selected by the parser.
    private func writeIdeDb(_ dbURL: URL, withSessionTable: Bool = true) throws {
        var sql = """
            CREATE TABLE chat_message (
              id varchar(64) primary key, session_id VARCHAR(64), request_id VARCHAR(64), role VARCHAR(64),
              content text, summary text, summary_modified INTEGER, summary_trigger INTEGER DEFAULT 0,
              tool_result text, token_info text, model_info text, extra text DEFAULT '', gmt_create INTEGER);
            """
        if withSessionTable {
            sql += """
                CREATE TABLE chat_session (
                  session_id varchar(64) primary key, user_id VARCHAR(64), user_name varchar(64), session_title varchar(256),
                  project_id varchar(64), project_uri varchar(512), project_name varchar(64), gmt_create INTEGER,
                  gmt_modified INTEGER, preferred_model_info TEXT DEFAULT '');
                INSERT INTO chat_session (session_id, user_id, session_title, project_id, project_uri, project_name)
                  VALUES ('s1', 'u', 't', 'p', 'file:///Users/jiangbian/Documents/projects/ide%20demo', 'ide demo');
                """
        }
        let fixture = try SQLiteFixture(at: dbURL, sql: sql)
        func insert(_ id: String, _ role: String, _ content: String, _ tokenInfo: String,
                    _ modelInfo: String, _ extra: String, _ created: Int) throws {
            try fixture.exec("""
                INSERT INTO chat_message (id, session_id, request_id, role, content, token_info, model_info, extra, gmt_create)
                VALUES (\(sqlQuote(id)), 's1', 'r1', \(sqlQuote(role)), \(sqlQuote(content)), \(sqlQuote(tokenInfo)), \(sqlQuote(modelInfo)), \(sqlQuote(extra)), \(created));
                """)
        }
        try insert("m1", "user", "PROMPT TEXT MUST NOT BE READ", "", "", #"{"agent_version":"7"}"#, 1_788_454_775_438)
        try insert("m2", "assistant", "REPLY TEXT",
                   #"{"prompt_tokens":16340,"completion_tokens":83,"cached_tokens":0,"max_input_tokens":200000}"#,
                   #"{"model_key":"auto"}"#, #"{"agent_version":"7"}"#, 1_788_454_777_997)
        try insert("m3", "tool", "", "", "", #"{"agent_version":"7"}"#, 1_788_454_778_044)
        try insert("m4", "assistant", "REPLY TEXT",
                   #"{"prompt_tokens":18756,"completion_tokens":112,"cached_tokens":16334,"max_input_tokens":200000}"#,
                   #"{"model_key":"auto"}"#, #"{"agent_version":"7"}"#, 1_788_454_780_945)
        // Placeholder assistant row without token info: timing only.
        try insert("m5", "assistant", "", "", #"{"model_key":"auto"}"#, "", 1_788_454_790_000)
        fixture.close()
    }

    @Test("IDE local.db yields real tokens with cached input split out")
    func ideTokensWithCacheSplit() throws {
        let root = makeTempDirectory("qoder-ide")
        let dbURL = root.appendingPathComponent("local.db")
        try writeIdeDb(dbURL)
        let parser = VibeSyncQoderParser(
            edition: .international,
            projectsDir: root.appendingPathComponent("no-projects").path,
            dbPath: dbURL.path)
        let result = try parser.parse()
        #expect(!result.skipped)
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.source == "qoder")
        // `auto` bare would match the Cursor `auto` pricing entry; namespaced instead.
        #expect(bucket.model == "qoder-auto")
        #expect(bucket.project == "ide demo")
        #expect(bucket.inputTokens == (16340 - 0) + (18756 - 16334))
        #expect(bucket.cachedInputTokens == 0 + 16334)
        #expect(bucket.outputTokens == 83 + 112)
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions.first?.userMessageCount == 1)

        // Never retain or upload the stored message text.
        let serialized = String(decoding: try JSONEncoder().encode(buckets), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self)
        #expect(!serialized.contains("PROMPT TEXT MUST NOT BE READ"))
        #expect(!serialized.contains("REPLY TEXT"))
    }

    @Test("IDE local.db without chat_session table still parses")
    func ideWithoutSessionTable() throws {
        let root = makeTempDirectory("qoder-ide-old")
        let dbURL = root.appendingPathComponent("local.db")
        try writeIdeDb(dbURL, withSessionTable: false)
        let parser = VibeSyncQoderParser(
            edition: .international,
            projectsDir: root.appendingPathComponent("no-projects").path,
            dbPath: dbURL.path)
        let buckets = vibeBuckets(try parser.parse())
        #expect(buckets.count == 1)
        #expect(buckets.first?.project == "unknown")
        #expect(buckets.first?.outputTokens == 195)
    }

    @Test("an unreadable IDE db returns skipped instead of throwing")
    func unreadableIdeDbSkips() throws {
        let root = makeTempDirectory("qoder-ide-bad")
        let dbURL = root.appendingPathComponent("local.db")
        try "this is not a sqlite database".write(to: dbURL, atomically: true, encoding: .utf8)
        let parser = VibeSyncQoderParser(
            edition: .international,
            projectsDir: root.appendingPathComponent("no-projects").path,
            dbPath: dbURL.path)
        let result = try parser.parse()
        #expect(result.skipped)
        #expect(result.entries.isEmpty)
        #expect(vibeBuckets(result).isEmpty)
    }

    // MARK: - Root resolution (qoder-roots.js)

    @Test("root resolution: fixture overrides, tool env vars, and macOS defaults")
    func rootResolution() {
        #expect(VibeSyncQoderParser.resolveProjectsDir(
            edition: .international, environment: ["VIBE_USAGE_QODER_PROJECTS": "/x"]) == "/x")
        #expect(VibeSyncQoderParser.resolveProjectsDir(
            edition: .international, environment: ["QODER_CONFIG_DIR": "/cfg/"]) == "/cfg/projects")
        #expect(VibeSyncQoderParser.resolveProjectsDir(
            edition: .cn, environment: ["QODERCN_CONFIG_DIR": "~/cfg-cn"], home: "/home/me") == "/home/me/cfg-cn/projects")
        #expect(VibeSyncQoderParser.resolveProjectsDir(
            edition: .international, environment: [:], home: "/home/me") == "/home/me/.qoder/projects")
        #expect(VibeSyncQoderParser.resolveProjectsDir(
            edition: .cn, environment: [:], home: "/home/me") == "/home/me/.qoder-cn/projects")

        #expect(VibeSyncQoderParser.resolveDbPath(
            edition: .international, environment: ["VIBE_USAGE_QODER_DB": "/d.db"]) == "/d.db")
        #expect(VibeSyncQoderParser.resolveDbPath(
            edition: .international, environment: ["QODER_HOME": "/ide-home"]) == "/ide-home/cache/db/local.db")
        #expect(VibeSyncQoderParser.resolveDbPath(
            edition: .international, environment: [:], home: "/home/me")
            == "/home/me/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db")
        #expect(VibeSyncQoderParser.resolveDbPath(
            edition: .cn, environment: [:], home: "/home/me")
            == "/home/me/Library/Application Support/QoderCN/SharedClientCache/cache/db/local.db")
        // The fixture override beats the tool's own relocation env.
        #expect(VibeSyncQoderParser.resolveProjectsDir(
            edition: .international,
            environment: ["VIBE_USAGE_QODER_PROJECTS": "/t", "QODER_CONFIG_DIR": "/cfg"]) == "/t")
    }
}
