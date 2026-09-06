import Compression
import Foundation
import Testing
@testable import Nootch

// MARK: - Test helpers

private struct StubParserError: Error { let message: String }

private struct StubParser: VibeLogParser {
    let source: String
    var result: VibeParseResult = VibeParseResult()
    var error: StubParserError?

    func parse() throws -> VibeParseResult {
        if let error { throw error }
        return result
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private func httpResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeConfig(_ contents: String, in directory: URL) throws -> String {
    let url = directory.appendingPathComponent("config.json")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

private func inflateGzip(_ data: Data) throws -> Data {
    #expect(data.count > 18)
    let payload = data[10..<(data.count - 8)]
    var capacity = max(256, payload.count * 10)
    while true {
        var destination = Data(count: capacity)
        let written: Int = destination.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), payload.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        // The payloads fed here are valid by construction, so written == 0 is
        // the legitimate empty-output case, not an error.
        if written >= 0, written < capacity {
            destination.count = written
            return destination
        }
        capacity *= 2
        #expect(capacity < 64 * 1024 * 1024)
    }
}

private func utcDate(_ string: String) -> Date {
    try! Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

private func utcDateTime(_ string: String) -> Date {
    try! Date(string, strategy: Date.ISO8601FormatStyle())
}

private func entry(
    source: String = "claude-code", model: String = "claude-opus-4-7", project: String = "proj",
    timestamp: Date, input: Double = 1, output: Double = 2, cached: Double = 3, reasoning: Double = 0
) -> VibeTokenEntry {
    VibeTokenEntry(
        source: source, model: model, project: project, timestamp: timestamp,
        inputTokens: input, outputTokens: output, cachedInputTokens: cached, reasoningOutputTokens: reasoning)
}

private func event(
    _ sessionId: String, source: String = "codex", project: String = "proj",
    _ timestamp: Date, role: VibeSessionRole
) -> VibeSessionEvent {
    VibeSessionEvent(sessionId: sessionId, source: source, project: project, timestamp: timestamp, role: role)
}

private let settingsTrueJSON = #"{"uploadProject":true}"#
private let settingsFalseJSON = #"{"uploadProject":false}"#

private func ingestJSON(buckets: Int, sessions: Int, unknownSources: [String] = []) -> String {
    let sources = unknownSources.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"ingested":\#(buckets),"sessions":\#(sessions),"dropped":{"buckets":0,"unknownModels":0,"implausible":0,"unknownSources":[\#(sources)]},"protected":{"buckets":0}}"#
}

// MARK: - Aggregation

@Test func roundToHalfHourFloorsInUTC() {
    #expect(VibeSyncTime.roundToHalfHour(utcDate("2026-09-06T08:14:59.999Z")) == utcDate("2026-09-06T08:00:00.000Z"))
    #expect(VibeSyncTime.roundToHalfHour(utcDate("2026-09-06T08:30:00.000Z")) == utcDate("2026-09-06T08:30:00.000Z"))
    #expect(VibeSyncTime.roundToHalfHour(utcDate("2026-09-06T08:44:00.000Z")) == utcDate("2026-09-06T08:30:00.000Z"))
    #expect(VibeSyncTime.roundToHalfHour(utcDate("2026-09-06T23:59:00.000Z")) == utcDate("2026-09-06T23:30:00.000Z"))
}

@Test func bucketAggregationSumsThenClamps() {
    // Per-entry clamping would give 0; official sums first: 0.4 + 0.4 = 0.8 → 1.
    let buckets = VibeAggregation.aggregateToBuckets([
        entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"), input: 0.4, output: 0, cached: 0),
        entry(timestamp: utcDateTime("2026-09-06T08:20:00Z"), input: 0.4, output: 0, cached: 0),
    ], hostname: "Mac")
    #expect(buckets.count == 1)
    #expect(buckets[0].inputTokens == 1)
    #expect(buckets[0].bucketStart == "2026-09-06T08:00:00.000Z")
}

@Test func bucketAggregationClampsNaNAndNegativeToZero() {
    // Official semantics: entries sum first, then the SUM is clamped — a
    // negative entry can cancel positive ones (-5 + 20 = 15).
    let buckets = VibeAggregation.aggregateToBuckets([
        entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"), input: .nan, output: -5, cached: .infinity, reasoning: 0),
        entry(timestamp: utcDateTime("2026-09-06T08:06:00Z"), input: 10, output: 20, cached: 0, reasoning: 0),
    ], hostname: "Mac")
    #expect(buckets[0].inputTokens == 10)
    #expect(buckets[0].outputTokens == 15)
    #expect(buckets[0].cachedInputTokens == 0)
}

@Test func bucketTotalExcludesCachedTokens() {
    let buckets = VibeAggregation.aggregateToBuckets([
        entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"), input: 100, output: 20, cached: 999, reasoning: 5),
    ], hostname: "Mac")
    #expect(buckets[0].totalTokens == 125)
    #expect(buckets[0].cachedInputTokens == 999)
}

@Test func bucketAggregationSplitsByHalfHourAndTruncatesFields() {
    let longModel = String(repeating: "m", count: 150)
    let longProject = String(repeating: "p", count: 250)
    let buckets = VibeAggregation.aggregateToBuckets([
        entry(model: longModel, project: longProject, timestamp: utcDateTime("2026-09-06T08:05:00Z")),
        entry(model: longModel, project: longProject, timestamp: utcDateTime("2026-09-06T08:45:00Z")),
    ], hostname: "Mac")
    #expect(buckets.count == 2)
    #expect(buckets[0].model.count == 100)
    #expect(buckets[0].project.count == 200)
    #expect(buckets[0].bucketStart == "2026-09-06T08:00:00.000Z")
    #expect(buckets[1].bucketStart == "2026-09-06T08:30:00.000Z")
}

@Test func bucketAggregationDefaultsEmptyModelAndProjectToUnknown() {
    let buckets = VibeAggregation.aggregateToBuckets([
        entry(model: "", project: "", timestamp: utcDateTime("2026-09-06T08:05:00Z")),
    ], hostname: "Mac")
    #expect(buckets[0].model == "unknown")
    #expect(buckets[0].project == "unknown")
}

// MARK: - Session extraction

@Test func extractSessionsComputesTurnsAndCounts() {
    let t0 = utcDate("2026-09-06T08:00:00.000Z")
    let sessions = VibeAggregation.extractSessions([
        event("s1", t0, role: .user),
        event("s1", t0.addingTimeInterval(5), role: .assistant),
        event("s1", t0.addingTimeInterval(10), role: .assistant),
        event("s1", t0.addingTimeInterval(20), role: .user),
        event("s1", t0.addingTimeInterval(25), role: .assistant),
    ])
    #expect(sessions.count == 1)
    let session = sessions[0]
    // Turn 1: 5s→10s counts; turn 2 has a single assistant reply, no duration.
    #expect(session.activeSeconds == 5)
    #expect(session.durationSeconds == 25)
    #expect(session.messageCount == 5)
    #expect(session.userMessageCount == 2)
    #expect(session.userPromptHours[8] == 2)
    #expect(session.userPromptHours.reduce(0, +) == 2)
    #expect(session.firstMessageAt == "2026-09-06T08:00:00.000Z")
    #expect(session.lastMessageAt == "2026-09-06T08:00:25.000Z")
    #expect(session.project == "proj")
}

@Test func extractSessionsSortsOutOfOrderEvents() {
    let t0 = utcDate("2026-09-06T09:00:00.000Z")
    let sessions = VibeAggregation.extractSessions([
        event("s1", t0.addingTimeInterval(10), role: .assistant),
        event("s1", t0, role: .user),
        event("s1", t0.addingTimeInterval(5), role: .assistant),
    ])
    let session = try! #require(sessions.first)
    #expect(session.durationSeconds == 10)
    #expect(session.activeSeconds == 5)
    #expect(session.userPromptHours[9] == 1)
}

@Test func extractSessionsUsesUTCHourForPromptHistogram() {
    // 23:30 UTC on Sep 6 is a different local hour in most timezones.
    let sessions = VibeAggregation.extractSessions([
        event("s1", utcDate("2026-09-06T23:30:00.000Z"), role: .user),
        event("s1", utcDate("2026-09-06T23:31:00.000Z"), role: .assistant),
    ])
    #expect(sessions[0].userPromptHours[23] == 1)
}

@Test func extractSessionsGroupsBySessionId() {
    let t0 = utcDate("2026-09-06T08:00:00.000Z")
    let sessions = VibeAggregation.extractSessions([
        event("a", t0, role: .user),
        event("b", t0, role: .user),
        event("a", t0.addingTimeInterval(3), role: .assistant),
        event("b", t0.addingTimeInterval(7), role: .assistant),
    ])
    #expect(sessions.count == 2)
    #expect(Set(sessions.map(\.durationSeconds)) == [3, 7])
}

// MARK: - Hashing compatibility with vibe-usage src/state.js

@Test func bucketHashMatchesOfficialAlgorithm() {
    // sha256("1\02\03\00\06") = 6f805790b23bf211… (computed with the official algorithm)
    let bucket = VibeBucket(
        source: "x", model: "m", project: "p", hostname: "Mac", bucketStart: "2026-09-06T08:00:00.000Z",
        inputTokens: 1, outputTokens: 2, cachedInputTokens: 3, reasoningOutputTokens: 0, totalTokens: 6)
    #expect(VibeSyncHashing.bucketHash(bucket) == "6f805790b23bf211")
}

@Test func sessionHashIsSha256PrefixOfSessionId() {
    // sha256("session-abc-123") = 88ce9025f8a9c60e…
    let sessions = VibeAggregation.extractSessions([
        event("session-abc-123", utcDate("2026-09-06T08:00:00.000Z"), role: .user),
    ])
    #expect(sessions[0].sessionHash == "88ce9025f8a9c60e")
    #expect(VibeSyncHashing.sha256Hex16("proj-代码") == "433d5f6b17f7c237")
}

@Test func sessionStateHashMatchesOfficialAlgorithm() {
    var hours = [Int](repeating: 0, count: 24)
    hours[8] = 2
    hours[22] = 1
    let session = VibeSession(
        source: "codex", project: "proj", sessionHash: "x", hostname: "Mac",
        firstMessageAt: "2026-09-06T08:00:00.000Z", lastMessageAt: "2026-09-06T08:34:26.000Z",
        durationSeconds: 2066, activeSeconds: 2066, messageCount: 314, userMessageCount: 3,
        userPromptHours: hours)
    // sha256("proj\0Mac\0…\00,0,0,0,0,0,0,0,2,0,…,1,0") = ab94f84125a8a159…
    #expect(VibeSyncHashing.sessionStateHash(session) == "ab94f84125a8a159")
    #expect(VibeSyncHashing.sessionKey(session) == "codex|x")
}

@Test func bucketKeyMirrorsServerDedupKey() {
    let bucket = VibeBucket(
        source: "claude-code", model: "m", project: "p", hostname: "Mac", bucketStart: "2026-09-06T08:00:00.000Z",
        inputTokens: 0, outputTokens: 0, cachedInputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0)
    #expect(VibeSyncHashing.bucketKey(bucket) == "claude-code|m|p|Mac|2026-09-06T08:00:00.000Z")
}

// MARK: - State store

@Test func stateStoreTreatsMissingAndCorruptAsEmpty() throws {
    let directory = try makeTempDirectory()
    let store = VibeSyncStateStore(fileURL: directory.appendingPathComponent("state.json"))
    #expect(store.load() == VibeSyncState())
    try Data("not json".utf8).write(to: directory.appendingPathComponent("state.json"))
    #expect(store.load() == VibeSyncState())
}

@Test func stateStoreRoundTripsAndWritesAtomically() throws {
    let directory = try makeTempDirectory()
    let store = VibeSyncStateStore(fileURL: directory.appendingPathComponent("nested/state.json"))
    var state = VibeSyncState()
    state.buckets["a|b|c|d|e"] = "0123456789abcdef"
    state.sessions["codex|hash"] = "fedcba9876543210"
    try store.save(state)
    #expect(store.load() == state)
}

@Test func statePruneIsScopedToSuccessfulSources() {
    var state = VibeSyncState()
    state.buckets["claude-code|m|p|H|t"] = "h1"
    state.buckets["codex|m|p|H|t"] = "h2"
    state.sessions["claude-code|s1"] = "h3"
    state.sessions["codex|s2"] = "h4"
    // codex parser failed this run → its keys survive even though not live.
    let pruned = state.prune(liveBucketKeys: [], liveSessionKeys: [], okSources: ["claude-code"])
    #expect(pruned == 2)
    #expect(state.buckets == ["codex|m|p|H|t": "h2"])
    #expect(state.sessions == ["codex|s2": "h4"])
}

@Test func statePruneKeepsLiveKeys() {
    var state = VibeSyncState()
    state.buckets["claude-code|m|p|H|t"] = "h1"
    let pruned = state.prune(liveBucketKeys: ["claude-code|m|p|H|t"], liveSessionKeys: [], okSources: ["claude-code"])
    #expect(pruned == 0)
    #expect(state.buckets.count == 1)
}

// MARK: - gzip

@Test func gzipRoundTripsAndHasValidFraming() throws {
    let raw = Data((#"{"buckets":[{"source":"claude-code"}]}"#.utf8))
    let encoded = VibeGzip.encode(raw)
    #expect(encoded[0] == 0x1F)
    #expect(encoded[1] == 0x8B)
    #expect(encoded[2] == 0x08)
    var crc: UInt32 = 0
    var size: UInt32 = 0
    withUnsafeMutableBytes(of: &crc) { $0.copyBytes(from: encoded[(encoded.count - 8)..<(encoded.count - 4)]) }
    withUnsafeMutableBytes(of: &size) { $0.copyBytes(from: encoded[(encoded.count - 4)...]) }
    #expect(crc == VibeGzip.crc32(raw))
    #expect(size == UInt32(raw.count))
    #expect(try inflateGzip(encoded) == raw)
}

@Test func gzipHandlesEmptyAndLargePayloads() throws {
    #expect(try inflateGzip(VibeGzip.encode(Data())) == Data())
    let large = Data((0..<200_000).map { UInt8($0 % 251) })
    #expect(try inflateGzip(VibeGzip.encode(large)) == large)
}

// MARK: - API client

@Test func ingestBuildsGzippedJSONRequest() async throws {
    let recorder = RequestRecorder()
    let client = VibeSyncAPIClient(baseURL: "https://vibecafe.ai", apiKey: "vbu_test123") { request in
        recorder.record(request)
        return (Data(#"{"ingested":1,"sessions":1}"#.utf8), httpResponse(request.url!, status: 200))
    }
    let bucket = VibeBucket(
        source: "claude-code", model: "m", project: "p", hostname: "Mac", bucketStart: "2026-09-06T08:00:00.000Z",
        inputTokens: 1, outputTokens: 2, cachedInputTokens: 3, reasoningOutputTokens: 0, totalTokens: 3)
    let session = VibeSession(
        source: "codex", project: "p", sessionHash: "h", hostname: "Mac",
        firstMessageAt: "2026-09-06T08:00:00.000Z", lastMessageAt: "2026-09-06T08:01:00.000Z",
        durationSeconds: 60, activeSeconds: 60, messageCount: 2, userMessageCount: 1,
        userPromptHours: [Int](repeating: 0, count: 24))
    let meta = VibeSyncClientMeta.make(hostname: "Mac", syncId: "sync-1", batchIndex: 0, batchCount: 1)
    let response = try await client.ingest(buckets: [bucket], sessions: [session], client: meta)
    #expect(response.ingested == 1)

    let request = try #require(recorder.requests.first)
    #expect(request.url?.absoluteString == "https://vibecafe.ai/api/usage/ingest")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer vbu_test123")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
    #expect(request.timeoutInterval == 60)

    let body = try inflateGzip(try #require(request.httpBody))
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let buckets = try #require(json["buckets"] as? [[String: Any]])
    #expect(buckets.count == 1)
    #expect(buckets[0]["totalTokens"] as? Int == 3)
    let sessions = try #require(json["sessions"] as? [[String: Any]])
    #expect(sessions.count == 1)
    let clientMeta = try #require(json["client"] as? [String: Any])
    #expect(clientMeta["surface"] as? String == "mac-app")
    #expect(clientMeta["runtime"] as? String == "swift")
    #expect(clientMeta["runtimeVersion"] as? String == "6")
    #expect(clientMeta["platform"] as? String == "darwin")
    #expect(clientMeta["hostname"] as? String == "Mac")
    #expect(clientMeta["syncId"] as? String == "sync-1")
    #expect(clientMeta["batchIndex"] as? Int == 0)
    #expect(clientMeta["batchCount"] as? Int == 1)
    #expect(clientMeta["collectorVersion"] as? String == VibeSyncClientMeta.appVersion)
}

@Test func ingestOmitsEmptySessionsKey() async throws {
    let recorder = RequestRecorder()
    let client = VibeSyncAPIClient(baseURL: "https://vibecafe.ai", apiKey: "k") { request in
        recorder.record(request)
        return (Data(#"{"ingested":0}"#.utf8), httpResponse(request.url!, status: 200))
    }
    try await client.ingest(buckets: [], sessions: [], client: VibeSyncClientMeta.make(hostname: "Mac", syncId: "s", batchIndex: 0, batchCount: 1))
    let body = try inflateGzip(try #require(recorder.requests.first?.httpBody))
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["sessions"] == nil)
    #expect((json["buckets"] as? [[String: Any]])?.isEmpty == true)
}

@Test func ingestRetriesWithBackoffButNotOn4xx() async throws {
    let attempts = RequestRecorder()
    let sleepDurations = MutexBox<[Duration]>([])
    let failuresLeft = MutexBox(2)
    let client = VibeSyncAPIClient(
        baseURL: "https://vibecafe.ai", apiKey: "k",
        dataLoader: { request in
            attempts.record(request)
            let shouldFail = failuresLeft.withValue { value -> Bool in
                if value > 0 {
                    value -= 1
                    return true
                }
                return false
            }
            if shouldFail { throw URLError(.timedOut) }
            return (Data(#"{"ingested":1}"#.utf8), httpResponse(request.url!, status: 200))
        },
        sleep: { duration in sleepDurations.withValue { $0.append(duration) } },
        random: { 0.5 })
    try await client.ingest(buckets: [], sessions: [], client: VibeSyncClientMeta.make(hostname: "Mac", syncId: "s", batchIndex: 0, batchCount: 1))
    #expect(attempts.requests.count == 3)
    // ceiling/2 + random*ceiling/2 with random = 0.5 → 750ms, 1500ms
    #expect(sleepDurations.withValue { $0 } == [.milliseconds(750), .milliseconds(1500)])
}

@Test func ingestDoesNotRetry4xxExcept429() async throws {
    let attempts = RequestRecorder()
    let client = VibeSyncAPIClient(baseURL: "https://vibecafe.ai", apiKey: "k") { request in
        attempts.record(request)
        return (Data(), httpResponse(request.url!, status: 400))
    }
    do {
        _ = try await client.ingest(buckets: [], sessions: [], client: VibeSyncClientMeta.make(hostname: "Mac", syncId: "s", batchIndex: 0, batchCount: 1))
        Issue.record("expected http 400 to throw")
    } catch {
        #expect(error as? VibeSyncError == .http(400))
    }
    #expect(attempts.requests.count == 1)
}

@Test func ingest401ThrowsUnauthorizedWithoutRetry() async throws {
    let attempts = RequestRecorder()
    let client = VibeSyncAPIClient(baseURL: "https://vibecafe.ai", apiKey: "k") { request in
        attempts.record(request)
        return (Data(), httpResponse(request.url!, status: 401))
    }
    do {
        _ = try await client.ingest(buckets: [], sessions: [], client: VibeSyncClientMeta.make(hostname: "Mac", syncId: "s", batchIndex: 0, batchCount: 1))
        Issue.record("expected 401 to throw")
    } catch {
        #expect(error as? VibeSyncError == .unauthorized)
    }
    #expect(attempts.requests.count == 1)
}

@Test func settingsRequestUsesBearerAndShortTimeout() async throws {
    let recorder = RequestRecorder()
    let client = VibeSyncAPIClient(baseURL: "http://localhost:4000", apiKey: "vbu_key") { request in
        recorder.record(request)
        return (Data(settingsTrueJSON.utf8), httpResponse(request.url!, status: 200))
    }
    #expect(try await client.fetchUploadProjectSetting() == true)
    let request = try #require(recorder.requests.first)
    #expect(request.url?.absoluteString == "http://localhost:4000/api/usage/settings")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer vbu_key")
    #expect(request.timeoutInterval == 10)
}

@Test func settingsPermanent4xxIsUnavailableWithoutRetry() async throws {
    let attempts = RequestRecorder()
    let client = VibeSyncAPIClient(baseURL: "https://vibecafe.ai", apiKey: "k") { request in
        attempts.record(request)
        return (Data(), httpResponse(request.url!, status: 403))
    }
    do {
        _ = try await client.fetchUploadProjectSetting()
        Issue.record("expected settingsUnavailable")
    } catch {
        #expect(error as? VibeSyncError == .settingsUnavailable)
    }
    #expect(attempts.requests.count == 1)
}

// MARK: - Engine

private final class MutexBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private struct FakeServer: @unchecked Sendable {
    let recorder = RequestRecorder()
    let settingsStatus: MutexBox<Int>
    let settingsBody: String
    let ingestStatus: MutexBox<Int>
    let ingestUnknownSources: [String]

    init(settingsStatus: Int = 200, settingsBody: String = settingsTrueJSON, ingestStatus: Int = 200, ingestUnknownSources: [String] = []) {
        self.settingsStatus = MutexBox(settingsStatus)
        self.settingsBody = settingsBody
        self.ingestStatus = MutexBox(ingestStatus)
        self.ingestUnknownSources = ingestUnknownSources
    }

    var dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            recorder.record(request)
            if request.url?.path == "/api/usage/settings" {
                let status = settingsStatus.withValue { $0 }
                return (Data(settingsBody.utf8), httpResponse(request.url!, status: status))
            }
            let status = ingestStatus.withValue { $0 }
            let (bucketCount, sessionCount) = payloadCounts(request)
            return (Data(ingestJSON(buckets: bucketCount, sessions: sessionCount, unknownSources: ingestUnknownSources).utf8),
                    httpResponse(request.url!, status: status))
        }
    }

    func payloadCounts(_ request: URLRequest) -> (buckets: Int, sessions: Int) {
        guard let body = try? decodedBody(request) else { return (0, 0) }
        return (
            (body["buckets"] as? [[String: Any]])?.count ?? 0,
            (body["sessions"] as? [[String: Any]])?.count ?? 0)
    }

    func decodedBody(_ request: URLRequest) throws -> [String: Any] {
        let raw = try inflateGzip(request.httpBody ?? Data())
        return try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
    }

    var posts: [URLRequest] {
        recorder.requests.filter { $0.httpMethod == "POST" }
    }

    var gets: [URLRequest] {
        recorder.requests.filter { $0.httpMethod != "POST" }
    }
}

private func makeEngine(
    parsers: [any VibeLogParser],
    server: FakeServer,
    configContents: String = #"{"apiKey":"vbu_test123","hostname":"Mac","extraRoots":{"claude-code":["/tmp/x"]}}"#,
    stateStore: inout VibeSyncStateStore?
) async throws -> (VibeSyncEngine, URL) {
    let directory = try makeTempDirectory()
    let configPath = try writeConfig(configContents, in: directory)
    let engine = VibeSyncEngine(
        parsers: parsers,
        configPath: configPath,
        dataLoader: server.dataLoader,
        sleep: { _ in },
        random: { 0.5 })
    stateStore = VibeSyncStateStore(fileURL: directory.appendingPathComponent("state.json"))
    return (engine, directory)
}

@Test func engineSyncUploadsDiffAndCommitsState() async throws {
    let server = FakeServer()
    var stateStore: VibeSyncStateStore?
    let t0 = utcDate("2026-09-06T08:05:00.000Z")
    let parser = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [
            entry(timestamp: t0, input: 10, output: 5, cached: 0),
            entry(timestamp: t0.addingTimeInterval(600), input: 1, output: 1, cached: 0),
            entry(timestamp: t0.addingTimeInterval(1800), input: 2, output: 2, cached: 0),
        ],
        events: [
            event("sess-1", source: "claude-code", t0, role: .user),
            event("sess-1", source: "claude-code", t0.addingTimeInterval(4), role: .assistant),
        ]))
    let (engine, directory) = try await makeEngine(parsers: [parser], server: server, stateStore: &stateStore)

    let report = await engine.sync()
    #expect(report.status == .synced)
    #expect(report.liveBuckets == 2)
    #expect(report.liveSessions == 1)
    #expect(report.uploadedBuckets == 2)
    #expect(report.uploadedSessions == 1)
    #expect(server.posts.count == 1)

    let state = try #require(stateStore?.load())
    #expect(state.buckets.count == 2)
    #expect(state.sessions.count == 1)

    // Config writeback preserves other fields and caches the privacy setting.
    let config = try #require(VibeSyncEngine.loadConfigFile(at: directory.appendingPathComponent("config.json").path))
    #expect(config["apiKey"] as? String == "vbu_test123")
    #expect(config["extraRoots"] as? [String: Any] != nil)
    #expect(config["lastUploadProject"] as? Bool == true)
    #expect(config["lastUploadProjectApiUrl"] as? String == "https://vibecafe.ai")

    // Second sync with unchanged data sends nothing.
    let second = await engine.sync()
    #expect(second.status == .synced)
    #expect(second.changedBuckets == 0)
    #expect(second.changedSessions == 0)
    #expect(server.posts.count == 1)
}

@Test func engineBatchesBucketsByHundred() async throws {
    let server = FakeServer()
    var stateStore: VibeSyncStateStore?
    let base = utcDate("2026-09-06T00:00:00.000Z")
    let entries = (0..<250).map { index in
        entry(model: "model-\(index)", timestamp: base.addingTimeInterval(Double(index) * 60))
    }
    let (engine, _) = try await makeEngine(parsers: [StubParser(source: "claude-code", result: VibeParseResult(entries: entries))], server: server, stateStore: &stateStore)

    let report = await engine.sync()
    #expect(report.status == .synced)
    #expect(server.posts.count == 3)

    var syncIds = Set<String>()
    var totalBuckets = 0
    for (index, post) in server.posts.enumerated() {
        let body = try server.decodedBody(post)
        let client = try #require(body["client"] as? [String: Any])
        #expect(client["batchIndex"] as? Int == index)
        #expect(client["batchCount"] as? Int == 3)
        syncIds.insert(try #require(client["syncId"] as? String))
        totalBuckets += (body["buckets"] as? [[String: Any]])?.count ?? 0
    }
    #expect(syncIds.count == 1)
    #expect(totalBuckets == 250)
    #expect((stateStore?.load().buckets.count ?? 0) == 250)
}

@Test func engineDryRunComputesDiffWithoutUploading() async throws {
    let server = FakeServer()
    var stateStore: VibeSyncStateStore?
    let parser = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"), input: 10, output: 5, cached: 0)]))
    let (engine, directory) = try await makeEngine(parsers: [parser], server: server, stateStore: &stateStore)

    let report = await engine.sync(dryRun: true)
    #expect(report.status == .dryRun)
    #expect(report.changedBuckets == 1)
    #expect(report.uploadedBuckets == 0)
    #expect(server.posts.isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path) == false)
    #expect(stateStore?.load() == VibeSyncState())
}

@Test func engineCancelsSafelyWhenSettingsUnavailableWithoutCache() async throws {
    let server = FakeServer(settingsStatus: 500)
    var stateStore: VibeSyncStateStore?
    let parser = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"))]))
    let (engine, directory) = try await makeEngine(parsers: [parser], server: server, stateStore: &stateStore)

    let report = await engine.sync()
    #expect(report.status == .cancelled)
    #expect(server.posts.isEmpty)
    #expect(server.gets.count == 3) // retried 3 times, then cancelled
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path) == false)
    let config = try #require(VibeSyncEngine.loadConfigFile(at: directory.appendingPathComponent("config.json").path))
    #expect(config["lastUploadProject"] == nil)
}

@Test func engineFallsBackToCachedUploadProjectSetting() async throws {
    let server = FakeServer(settingsStatus: 500)
    var stateStore: VibeSyncStateStore?
    let parser = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [
            entry(project: "alpha", timestamp: utcDateTime("2026-09-06T08:05:00Z"), input: 10, output: 0, cached: 0),
            entry(project: "beta", timestamp: utcDateTime("2026-09-06T08:10:00Z"), input: 5, output: 0, cached: 0),
        ]))
    let (engine, _) = try await makeEngine(
        parsers: [parser], server: server,
        configContents: #"{"apiKey":"vbu_test123","hostname":"Mac","lastUploadProject":false,"lastUploadProjectApiUrl":"https://vibecafe.ai"}"#,
        stateStore: &stateStore)

    let report = await engine.sync()
    #expect(report.status == .synced)
    let body = try server.decodedBody(try #require(server.posts.first))
    let buckets = try #require(body["buckets"] as? [[String: Any]])
    // Hiding projects collapses the two project buckets into one summed bucket.
    #expect(buckets.count == 1)
    #expect(buckets[0]["project"] as? String == "unknown")
    #expect(buckets[0]["inputTokens"] as? Int == 15)
}

@Test func engineIgnoresCacheFromADifferentServer() async throws {
    let server = FakeServer(settingsStatus: 500)
    var stateStore: VibeSyncStateStore?
    let parser = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"))]))
    let (engine, _) = try await makeEngine(
        parsers: [parser], server: server,
        configContents: #"{"apiKey":"vbu_test123","hostname":"Mac","lastUploadProject":true,"lastUploadProjectApiUrl":"https://other.example.com"}"#,
        stateStore: &stateStore)
    let report = await engine.sync()
    #expect(report.status == .cancelled)
    #expect(server.posts.isEmpty)
}

@Test func engineReportsUnauthorizedOn401() async throws {
    let server = FakeServer(settingsStatus: 401)
    var stateStore: VibeSyncStateStore?
    let parser = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"))]))
    let (engine, _) = try await makeEngine(parsers: [parser], server: server, stateStore: &stateStore)
    let report = await engine.sync()
    #expect(report.status == .unauthorized)
    #expect(server.posts.isEmpty)
}

@Test func engineReportsNotConfiguredWithoutAPIKey() async throws {
    let server = FakeServer()
    var stateStore: VibeSyncStateStore?
    let (engine, _) = try await makeEngine(parsers: [], server: server, configContents: #"{}"#, stateStore: &stateStore)
    let report = await engine.sync()
    #expect(report.status == .notConfigured)
    #expect(server.recorder.requests.isEmpty)
}

@Test func engineParserFailureDoesNotBlockOthersNorPruneItsState() async throws {
    let server = FakeServer()
    var stateStore: VibeSyncStateStore?
    let good = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"))]))
    let bad = StubParser(source: "codex", error: StubParserError(message: "boom"))
    let (engine, directory) = try await makeEngine(parsers: [good, bad], server: server, stateStore: &stateStore)

    // Seed state with a stale codex key and a dead claude-code key.
    var seed = VibeSyncState()
    seed.sessions["codex|old-session"] = "aaaabbbbccccdddd"
    seed.buckets["claude-code|gone|proj|Mac|2026-09-01T00:00:00.000Z"] = "1111222233334444"
    try stateStore?.save(seed)

    let report = await engine.sync()
    #expect(report.status == .synced)
    #expect(report.okSources == ["claude-code"])
    #expect(report.failedSources == ["codex"])
    #expect(report.prunedKeys == 1)
    let state = stateStore?.load()
    #expect(state?.sessions["codex|old-session"] == "aaaabbbbccccdddd")
    #expect(state?.buckets["claude-code|gone|proj|Mac|2026-09-01T00:00:00.000Z"] == nil)
    _ = directory
}

@Test func engineDoesNotCommitBucketsWithUnknownSources() async throws {
    let server = FakeServer(ingestUnknownSources: ["claude-code"])
    var stateStore: VibeSyncStateStore?
    let parser = StubParser(source: "claude-code", result: VibeParseResult(
        entries: [entry(timestamp: utcDateTime("2026-09-06T08:05:00Z"))],
        events: [event("s1", source: "claude-code", utcDateTime("2026-09-06T08:05:00Z"), role: .user)]))
    let (engine, _) = try await makeEngine(parsers: [parser], server: server, stateStore: &stateStore)

    let report = await engine.sync()
    #expect(report.status == .synced)
    let state = stateStore?.load()
    // The rejected bucket stays uncommitted; the session still commits.
    #expect(state?.buckets.isEmpty == true)
    #expect(state?.sessions.count == 1)
}

@Test func engineFailedBatchLeavesUncommittedSuffixForNextSync() async throws {
    let recorder = RequestRecorder()
    let ingestCalls = MutexBox(0)
    let base = utcDate("2026-09-06T00:00:00.000Z")
    let entries = (0..<150).map { index in
        entry(model: "model-\(index)", timestamp: base.addingTimeInterval(Double(index) * 60))
    }
    let directory = try makeTempDirectory()
    let configPath = try writeConfig(#"{"apiKey":"vbu_test123","hostname":"Mac"}"#, in: directory)
    let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        recorder.record(request)
        if request.url?.path == "/api/usage/settings" {
            return (Data(settingsTrueJSON.utf8), httpResponse(request.url!, status: 200))
        }
        let call = ingestCalls.withValue { value -> Int in
            value += 1
            return value
        }
        // Batch 2 of the first run (attempts 2–4) fails; everything else succeeds.
        if (2...4).contains(call) { throw URLError(.networkConnectionLost) }
        let body = try inflateGzip(request.httpBody ?? Data())
        let count = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["buckets"] as? [[String: Any]] ?? []
        return (Data(ingestJSON(buckets: count.count, sessions: 0).utf8), httpResponse(request.url!, status: 200))
    }
    let engine = VibeSyncEngine(
        parsers: [StubParser(source: "claude-code", result: VibeParseResult(entries: entries))],
        configPath: configPath, dataLoader: dataLoader, sleep: { _ in }, random: { 0.5 })
    let stateStore = VibeSyncStateStore(fileURL: directory.appendingPathComponent("state.json"))

    // First run: batch 1 commits (100 buckets), batch 2 fails twice then the
    // client exhausts retries → sync fails with 100 keys committed.
    let first = await engine.sync()
    #expect(first.status == .failed)
    #expect(stateStore.load().buckets.count == 100)

    // Second run: only the remaining 50 buckets go out.
    let second = await engine.sync()
    #expect(second.status == .synced)
    #expect(second.uploadedBuckets == 50)
    #expect(stateStore.load().buckets.count == 150)
}

@Test func engineSkippedParserIsNotAnOkSource() async throws {
    let server = FakeServer()
    var stateStore: VibeSyncStateStore?
    let skipped = StubParser(source: "cursor", result: VibeParseResult(skipped: true))
    let (engine, _) = try await makeEngine(parsers: [skipped], server: server, stateStore: &stateStore)
    let report = await engine.sync()
    #expect(report.status == .synced)
    #expect(report.okSources.isEmpty)
    #expect(server.posts.isEmpty)
}
