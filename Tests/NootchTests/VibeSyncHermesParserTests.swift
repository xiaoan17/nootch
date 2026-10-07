import Foundation
import Testing
@testable import Nootch

// Port of vibe-usage test/hermes.test.js plus the macOS-reachable parts of
// test/hermes-discovery.test.js (the Windows LOCALAPPDATA layout has no
// Swift counterpart).
@Suite struct VibeSyncHermesParserTests {
    /// values = [input_tokens, output_tokens, cache_read_tokens,
    /// reasoning_tokens, (cache_write_tokens)] in column order.
    private func parseFixture(
        values: [Int], cacheWrite: Bool = true, profile: String = ""
    ) throws -> VibeParseResult {
        let root = makeTempDirectory("hermes")
        let dbDir = profile.isEmpty ? root : root.appendingPathComponent("profiles/\(profile)")
        let sql = """
            CREATE TABLE sessions (
              id TEXT, model TEXT, started_at REAL, input_tokens INTEGER,
              output_tokens INTEGER, cache_read_tokens INTEGER, reasoning_tokens INTEGER
              \(cacheWrite ? ", cache_write_tokens INTEGER" : "")
            );
            CREATE TABLE messages (session_id TEXT, role TEXT, timestamp REAL, content TEXT);
            INSERT INTO sessions VALUES ('test-session', 'test-model', 1788764700, \(values.map(String.init).joined(separator: ",")));
            INSERT INTO messages VALUES ('test-session', 'user', 1788764700, 'unused prompt');
            INSERT INTO messages VALUES ('test-session', 'assistant', 1788764720, 'unused reply');
            """
        let fixture = try SQLiteFixture(at: dbDir.appendingPathComponent("state.db"), sql: sql)
        fixture.close()
        return try VibeSyncHermesParser(environment: ["HERMES_HOME": root.path], home: "/unused").parse()
    }

    @Test func preservesProviderTotalsWhileSeparatingReasoningAndCacheWrites() throws {
        let result = try parseFixture(values: [48783, 1232, 100, 422, 50])
        let buckets = vibeBuckets(result)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(bucket.project == "default")
        #expect(bucket.inputTokens == 48833)
        #expect(bucket.outputTokens == 810)
        #expect(bucket.reasoningOutputTokens == 422)
        #expect(bucket.cachedInputTokens == 100)
        #expect(bucket.totalTokens == 50065)
        let sessions = vibeSessions(result)
        #expect(sessions.count == 1)
        #expect(sessions[0].messageCount == 2)
    }

    @Test func readsLegacySchemasWithoutCacheWriteColumn() throws {
        let result = try parseFixture(values: [100, 20, 40, 5], cacheWrite: false)
        let bucket = try #require(vibeBuckets(result).first)
        #expect(bucket.inputTokens == 100)
        #expect(bucket.outputTokens == 15)
        #expect(bucket.reasoningOutputTokens == 5)
        #expect(bucket.totalTokens == 120)
    }

    @Test func includesCacheOnlyUsageInNamedProfiles() throws {
        let result = try parseFixture(values: [0, 0, 100, 0, 20], profile: "work")
        let bucket = try #require(vibeBuckets(result).first)
        #expect(bucket.project == "work")
        #expect(bucket.cachedInputTokens == 100)
        #expect(bucket.inputTokens == 20)
        #expect(bucket.totalTokens == 20)
    }

    @Test func boundsInconsistentReasoningCountersByTotalOutput() throws {
        let result = try parseFixture(values: [100, 20, 0, 99, 0])
        let bucket = try #require(vibeBuckets(result).first)
        #expect(bucket.outputTokens == 0)
        #expect(bucket.reasoningOutputTokens == 20)
        #expect(bucket.totalTokens == 120)
    }

    // MARK: - Discovery (hermes-discovery.test.js, macOS layout)

    private func writeStore(
        _ dir: URL,
        values: [Int] = [100, 20, 0, 5, 0]
    ) throws {
        let sql = """
            CREATE TABLE sessions (
              id TEXT, model TEXT, started_at REAL, input_tokens INTEGER,
              output_tokens INTEGER, cache_read_tokens INTEGER, reasoning_tokens INTEGER,
              cache_write_tokens INTEGER, source TEXT
            );
            CREATE TABLE messages (session_id TEXT, role TEXT, timestamp REAL);
            INSERT INTO sessions VALUES ('desktop-session', 'test-model', 1788764700, \(values.map(String.init).joined(separator: ",")), 'api_server');
            INSERT INTO messages VALUES ('desktop-session', 'user', 1788764700), ('desktop-session', 'assistant', 1788764720);
            """
        let fixture = try SQLiteFixture(at: dir.appendingPathComponent("state.db"), sql: sql)
        fixture.close()
    }

    @Test func parsesDefaultStoreUnderHermesHome() throws {
        let home = makeTempDirectory("hermes-discovery")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeStore(home.appendingPathComponent(".hermes"))

        let result = try VibeSyncHermesParser(environment: [:], home: home.path).parse()
        let bucket = try #require(vibeBuckets(result).first)
        #expect(bucket.project == "default")
        #expect(bucket.totalTokens == 120)
        #expect(vibeSessions(result).first?.messageCount == 2)
    }

    @Test func customHomeIsUsedByParsing() throws {
        let root = makeTempDirectory("hermes-custom")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeStore(root.appendingPathComponent("custom-home"))

        let result = try VibeSyncHermesParser(
            environment: ["HERMES_HOME": root.appendingPathComponent("custom-home").path],
            home: "/unused").parse()
        #expect(vibeBuckets(result).first?.project == "default")
    }

    @Test func namedProfilesAreParsedWithoutADefaultDatabase() throws {
        let home = makeTempDirectory("hermes-profiles")
        defer { try? FileManager.default.removeItem(at: home) }
        try writeStore(home.appendingPathComponent(".hermes/profiles/work"))

        let result = try VibeSyncHermesParser(environment: [:], home: home.path).parse()
        let bucket = try #require(vibeBuckets(result).first)
        #expect(bucket.project == "work")
        #expect(bucket.totalTokens == 120)
    }

    @Test func absentWhenNeitherDefaultNorProfileDatabasesExist() throws {
        let home = makeTempDirectory("hermes-absent")
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try VibeSyncHermesParser(environment: [:], home: home.path).parse()
        #expect(!result.skipped)
        #expect(result.entries.isEmpty)
        #expect(result.events.isEmpty)
    }

    @Test func rejectsIncompleteDiscoveryWhenProfilesDirIsUnreadable() throws {
        // Root bypasses chmod denial; only meaningful as an unprivileged user.
        try #require(getuid() != 0)
        let home = makeTempDirectory("hermes-eacces")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(".hermes/profiles").path)
            try? FileManager.default.removeItem(at: home)
        }
        try writeStore(home.appendingPathComponent(".hermes"))
        try writeStore(home.appendingPathComponent(".hermes/profiles/work"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: home.appendingPathComponent(".hermes/profiles").path)

        #expect(throws: (any Error).self) {
            try VibeSyncHermesParser(environment: [:], home: home.path).parse()
        }
    }
}
