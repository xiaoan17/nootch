import CryptoKit
import Foundation
import Testing
@testable import Nootch

@Suite("VibeKimiCodeParser")
struct VibeKimiCodeParserTests {
    // MARK: - Fixture helpers

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Foundation resolves the /var → /private/var symlink inconsistently
        // (temporaryDirectory and resolvingSymlinksInPath keep /var, while
        // contentsOfDirectory returns /private/var). realpath(3) normalizes so
        // fixture-built paths match discovered paths.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &buffer) != nil else { return directory }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func currentWireURL(root: URL, bucket: String, session: String, agent: String) -> URL {
        root.appendingPathComponent("sessions/\(bucket)/\(session)/agents/\(agent)/wire.jsonl")
    }

    private func legacyWireURL(root: URL, workDirHash: String, session: String) -> URL {
        root.appendingPathComponent("sessions/\(workDirHash)/\(session)/wire.jsonl")
    }

    private func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func msDate(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }

    // MARK: - Current format

    @Test func currentFormatParsesUsageAndEvents() throws {
        let root = try makeTempDirectory()
        let emptyLegacy = try makeTempDirectory()
        let bucket = "wd_someproject_ab12cd34ef56"
        let session = "session_abc"
        let sessionDir = root.appendingPathComponent("sessions/\(bucket)/\(session)").path

        try write(
            """
            {"sessionId":"session_abc","sessionDir":"\(sessionDir)","workDir":"/Users/test/CoolProject"}

            """,
            to: root.appendingPathComponent("session_index.jsonl"))

        try write(
            """
            {"type":"turn.prompt","time":1781156604589,"origin":{"kind":"user"}}
            {"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":21237,"output":51,"inputCacheRead":1024,"inputCacheCreation":500},"usageScope":"turn","time":1781156608362}
            {"type":"some.other.event","time":1781156609000}
            {"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":112,"output":74,"inputCacheRead":22208,"inputCacheCreation":0},"usageScope":"session","time":1781156708033}
            """,
            to: currentWireURL(root: root, bucket: bucket, session: session, agent: "main"))
        try write(
            """
            {"type":"usage.record","model":"sub/model","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":2},"usageScope":"turn","time":1781156610000}
            """,
            to: currentWireURL(root: root, bucket: bucket, session: session, agent: "sub"))

        let parser = VibeKimiCodeParser(kimiCodeRoot: root, legacyKimiRoot: emptyLegacy)
        let result = try parser.parse()

        #expect(!result.skipped)
        #expect(result.entries.count == 3)

        let first = result.entries[0]
        #expect(first.source == "kimi-code")
        #expect(first.model == "kimi-code/kimi-for-coding")
        #expect(first.project == "CoolProject")
        #expect(first.timestamp == msDate(1_781_156_608_362))
        // Cache creation is billed as non-cached input; reads stay separate.
        #expect(first.inputTokens == 21237 + 500)
        #expect(first.outputTokens == 51)
        #expect(first.cachedInputTokens == 1024)
        #expect(first.reasoningOutputTokens == 0)

        // The retry/compaction-scoped record counts too.
        #expect(result.entries[1].inputTokens == 112)
        #expect(result.entries[1].cachedInputTokens == 22208)
        // Subagent wire contributes to the same project/session.
        #expect(result.entries[2].model == "sub/model")
        #expect(result.entries[2].inputTokens == 12)

        // 1 user event + 3 assistant events; main and subagent share one session.
        let events = result.events
        #expect(events.count == 4)
        #expect(events.filter { $0.role == .user }.count == 1)
        #expect(events.filter { $0.role == .assistant }.count == 3)
        #expect(Set(events.map(\.sessionId)) == [sessionDir])
        #expect(events.allSatisfy { $0.project == "CoolProject" && $0.source == "kimi-code" })
    }

    @Test func projectFallsBackToBucketSlug() throws {
        let root = try makeTempDirectory()
        let emptyLegacy = try makeTempDirectory()
        try write(
            """
            {"type":"usage.record","model":"m","usage":{"inputOther":1,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1781156608362}
            """,
            to: currentWireURL(
                root: root, bucket: "wd_fallback_proj_38c43e73f7cf", session: "s1", agent: "main"))

        let result = try VibeKimiCodeParser(kimiCodeRoot: root, legacyKimiRoot: emptyLegacy).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries[0].project == "fallback_proj")
    }

    @Test func zeroTokenAndBadTimestampRecordsAreSkipped() throws {
        let root = try makeTempDirectory()
        let emptyLegacy = try makeTempDirectory()
        try write(
            """
            {"type":"usage.record","model":"m","usage":{"inputOther":0,"output":0,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1781156608362}
            {"type":"usage.record","model":"m","usage":{"inputOther":5,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn"}
            {"type":"usage.record","model":"m","usage":{"inputOther":5,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":"not-a-number"}
            {"type":"turn.prompt","origin":{"kind":"user"}}
            {"type":"usage.record","model":"m","usage":{"inputOther":5,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1e400}
            {"type":"usage.record","model":"m","usage":{"inputOther":7,"output":2,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1781156608362}
            """,
            to: currentWireURL(root: root, bucket: "wd_x_abcdef012345", session: "s1", agent: "main"))

        let result = try VibeKimiCodeParser(kimiCodeRoot: root, legacyKimiRoot: emptyLegacy).parse()
        // Only the final record survives: zero-token, missing/non-numeric/
        // non-finite timestamps are all dropped (no "now" fallback).
        #expect(result.entries.count == 1)
        #expect(result.entries[0].inputTokens == 7)
        #expect(result.events.count == 1)
        #expect(result.events[0].role == .assistant)
    }

    @Test func corruptLinesAndMissingDirectoriesAreTolerated() throws {
        let root = try makeTempDirectory()
        let missingLegacy = try makeTempDirectory().appendingPathComponent("nope")

        // Missing sessions dir entirely → empty result, not skipped.
        let empty = try VibeKimiCodeParser(kimiCodeRoot: root, legacyKimiRoot: missingLegacy).parse()
        #expect(empty.entries.isEmpty && empty.events.isEmpty && !empty.skipped)

        try write(
            """
            not json at all
            {"type":"usage.record","model":"m","usage":{"inputOther":3,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1781156608362}
            {"type":"usage.record","model":
            ["an","array"]
            """,
            to: currentWireURL(root: root, bucket: "wd_y_abcdef012345", session: "s1", agent: "main"))

        let result = try VibeKimiCodeParser(kimiCodeRoot: root, legacyKimiRoot: missingLegacy).parse()
        #expect(result.entries.count == 1)
        #expect(result.entries[0].inputTokens == 3)
    }

    // MARK: - Legacy format

    @Test func legacyFormatParsesWithDedupAndModelTracking() throws {
        let legacy = try makeTempDirectory()
        let emptyCurrent = try makeTempDirectory()
        let workDir = "/Users/test/LegacyProject"
        let hash = md5Hex(workDir)

        try write(
            "{\"work_dirs\":[{\"path\":\"/Users/test/LegacyProject\"}]}",
            to: legacy.appendingPathComponent("kimi.json"))
        try write(
            """
            default_model = "kimi-k2-0905"
            """,
            to: legacy.appendingPathComponent("config.toml"))

        // Two files; message id "dup" appears in both and must count once.
        try write(
            """
            {"message":{"type":"TurnBegin","payload":{}},"timestamp":1781156600.5}
            {"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":20,"input_cache_read":5,"input_cache_creation":7},"message_id":"dup","model":"kimi-k2-turbo"}},"timestamp":1781156608.25}
            {"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":1,"output":1,"input_cache_read":0,"input_cache_creation":0},"message_id":"unique"}},"timestamp":1781156609.0}
            {"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":0,"output":0,"input_cache_read":0,"input_cache_creation":0},"message_id":"zeros"}},"timestamp":1781156610.0}
            """,
            to: legacyWireURL(root: legacy, workDirHash: hash, session: "s1"))
        try write(
            """
            {"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":20,"input_cache_read":5,"input_cache_creation":7},"message_id":"dup"}},"timestamp":1781156612.0}
            """,
            to: legacyWireURL(root: legacy, workDirHash: hash, session: "s2"))

        let result = try VibeKimiCodeParser(kimiCodeRoot: emptyCurrent, legacyKimiRoot: legacy).parse()

        #expect(result.entries.count == 2)
        let first = result.entries[0]
        #expect(first.project == "LegacyProject")
        #expect(first.model == "kimi-k2-turbo")
        #expect(first.timestamp == msDate(1_781_156_608_250))
        #expect(first.inputTokens == 107)
        #expect(first.outputTokens == 20)
        #expect(first.cachedInputTokens == 5)
        #expect(first.reasoningOutputTokens == 0)
        // "unique" inherits the model carried over from the previous line.
        #expect(result.entries[1].model == "kimi-k2-turbo")

        // Events: 1 user (TurnBegin) + 3 assistant StatusUpdates in s1,
        // 1 assistant in s2; sessionId is the wire file path.
        #expect(result.events.count == 5)
        #expect(result.events.filter { $0.role == .user }.count == 1)
        let s1 = legacyWireURL(root: legacy, workDirHash: hash, session: "s1").path
        #expect(result.events.filter { $0.sessionId == s1 }.count == 4)
    }

    @Test func legacyFallsBackToHashAndConfigDefaultModel() throws {
        let legacy = try makeTempDirectory()
        let emptyCurrent = try makeTempDirectory()
        try write(
            """
            [models."kimi-for-coding"]
            provider = "x"
            """,
            to: legacy.appendingPathComponent("config.toml"))
        try write(
            """
            {"type":"StatusUpdate","payload":{"token_usage":{"input_other":4,"output":2,"input_cache_read":0,"input_cache_creation":0}},"timestamp":1781156608.0}
            """,
            to: legacyWireURL(root: legacy, workDirHash: "0123456789abcdef0123456789abcdef", session: "s1"))

        let result = try VibeKimiCodeParser(kimiCodeRoot: emptyCurrent, legacyKimiRoot: legacy).parse()
        #expect(result.entries.count == 1)
        // No kimi.json → hash is the project label; no default_model → first
        // [models.*] section name is the model.
        #expect(result.entries[0].project == "0123456789abcdef0123456789abcdef")
        #expect(result.entries[0].model == "kimi-for-coding")
    }

    // MARK: - Cache behavior

    @Test func repeatedParseIsStableAndAppendIsPickedUp() throws {
        let root = try makeTempDirectory()
        let emptyLegacy = try makeTempDirectory()
        let wire = currentWireURL(root: root, bucket: "wd_z_abcdef012345", session: "s1", agent: "main")
        try write(
            """
            {"type":"usage.record","model":"m","usage":{"inputOther":1,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1781156608362}
            """,
            to: wire)

        let parser = VibeKimiCodeParser(kimiCodeRoot: root, legacyKimiRoot: emptyLegacy)
        let first = try parser.parse()
        let second = try parser.parse()
        #expect(first == second)
        #expect(first.entries.count == 1)

        // Appending changes size+mtime, so the cache invalidates.
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((
            "\n" + """
            {"type":"usage.record","model":"m","usage":{"inputOther":9,"output":9,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1781156610000}

            """).utf8))
        try handle.close()

        let third = try parser.parse()
        #expect(third.entries.count == 2)
        #expect(third.entries.map(\.inputTokens).sorted() == [1, 9])
    }

    // MARK: - Real-data sanity check (local only, prints counts/tokens only)

    @Test func realDataSanityCheck() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions").path) else { return }

        let parser = VibeKimiCodeParser()
        let coldStart = Date()
        let result = try parser.parse()
        let coldSeconds = Date().timeIntervalSince(coldStart)
        #expect(!result.entries.isEmpty)

        // Warm run must come entirely from the mtime/size cache and agree.
        let warmStart = Date()
        let warm = try parser.parse()
        let warmSeconds = Date().timeIntervalSince(warmStart)
        #expect(warm == result)

        let buckets = VibeAggregation.aggregateToBuckets(result.entries, hostname: "sanity")
        let calendar = Calendar(identifier: .gregorian)
        let startOfToday = calendar.startOfDay(for: Date())
        let recent = buckets.filter { bucket in
            guard let date = VibeSyncTime.parse(bucket.bucketStart) else { return false }
            return date >= startOfToday.addingTimeInterval(-3 * 86400)
        }
        let totals = result.entries.reduce((0.0, 0.0, 0.0)) { acc, entry in
            (acc.0 + entry.inputTokens, acc.1 + entry.outputTokens, acc.2 + entry.cachedInputTokens)
        }
        print("kimi-code sanity: \(result.entries.count) entries, \(result.events.count) events, "
            + "\(buckets.count) buckets total / \(recent.count) in last 3 days, "
            + "tokens in=\(Int(totals.0)) out=\(Int(totals.1)) cached=\(Int(totals.2)), "
            + "cold=\(String(format: "%.2f", coldSeconds))s warm=\(String(format: "%.3f", warmSeconds))s")
    }
}
