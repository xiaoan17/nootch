import Compression
import CryptoKit
import Foundation

// MARK: - Parser contract (implemented per tool by the parser phase)

struct VibeTokenEntry: Sendable, Equatable {
    var source: String
    var model: String
    var project: String
    var timestamp: Date
    var inputTokens: Double
    var outputTokens: Double
    var cachedInputTokens: Double
    var reasoningOutputTokens: Double
}

enum VibeSessionRole: String, Sendable {
    case user
    case assistant
}

struct VibeSessionEvent: Sendable, Equatable {
    var sessionId: String
    var source: String
    var project: String
    var timestamp: Date
    var role: VibeSessionRole
}

struct VibeParseResult: Sendable, Equatable {
    var entries: [VibeTokenEntry] = []
    var events: [VibeSessionEvent] = []
    var skipped = false
}

protocol VibeLogParser: Sendable {
    var source: String { get }
    func parse() throws -> VibeParseResult
}

// MARK: - Wire shapes

struct VibeBucket: Codable, Equatable, Sendable {
    var source: String
    var model: String
    var project: String
    var hostname: String
    var bucketStart: String
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int
}

struct VibeSession: Codable, Equatable, Sendable {
    var source: String
    var project: String
    var sessionHash: String
    var hostname: String
    var firstMessageAt: String
    var lastMessageAt: String
    var durationSeconds: Int
    var activeSeconds: Int
    var messageCount: Int
    var userMessageCount: Int
    var userPromptHours: [Int]
}

struct VibeSyncClientMeta: Codable, Equatable, Sendable {
    var collectorVersion: String
    var surface: String
    var surfaceVersion: String
    var runtime: String
    var runtimeVersion: String
    var platform: String
    var hostname: String
    var syncId: String
    var batchIndex: Int
    var batchCount: Int

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.4"
    }

    static func make(hostname: String, syncId: String, batchIndex: Int, batchCount: Int) -> VibeSyncClientMeta {
        VibeSyncClientMeta(
            collectorVersion: appVersion, surface: "mac-app", surfaceVersion: appVersion,
            runtime: "swift", runtimeVersion: "6", platform: "darwin",
            hostname: hostname, syncId: syncId, batchIndex: batchIndex, batchCount: batchCount)
    }
}

// MARK: - Time helpers (UTC, ISO8601 with milliseconds like Date.toISOString())

enum VibeSyncTime {
    private static let outputStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let inputStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func roundToHalfHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 1800) * 1800)
    }

    static func isoString(_ date: Date) -> String {
        date.formatted(outputStyle)
    }

    static func parse(_ string: String) -> Date? {
        try? Date(string, strategy: inputStyle)
    }

    static func utcHour(_ date: Date) -> Int {
        utcCalendar.component(.hour, from: date)
    }
}

// MARK: - Aggregation (mirror of vibe-usage src/parsers/aggregate.js)

enum VibeAggregation {
    static let modelMaxLength = 100
    static let projectMaxLength = 200

    private static func truncate(_ value: String, fallback: String, maxLength: Int) -> String {
        // JS slices UTF-16 code units; match that so long names hash identically.
        let source = value.isEmpty ? fallback : value
        let units = Array(source.utf16.prefix(maxLength))
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func toTokenCount(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value.rounded(), Double(Int.max)))
    }

    static func aggregateToBuckets(_ entries: [VibeTokenEntry], hostname: String) -> [VibeBucket] {
        struct Accumulator {
            var bucket: VibeBucket
            var input = 0.0
            var output = 0.0
            var cached = 0.0
            var reasoning = 0.0
        }
        var map: [String: Accumulator] = [:]
        var order: [String] = []
        for entry in entries {
            let model = truncate(entry.model, fallback: "unknown", maxLength: modelMaxLength)
            let project = truncate(entry.project, fallback: "unknown", maxLength: projectMaxLength)
            let bucketStart = VibeSyncTime.isoString(VibeSyncTime.roundToHalfHour(entry.timestamp))
            let key = "\(entry.source)|\(model)|\(project)|\(hostname)|\(bucketStart)"
            if map[key] == nil {
                map[key] = Accumulator(bucket: VibeBucket(
                    source: entry.source, model: model, project: project, hostname: hostname,
                    bucketStart: bucketStart, inputTokens: 0, outputTokens: 0,
                    cachedInputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0))
                order.append(key)
            }
            map[key]!.input += entry.inputTokens.isFinite ? entry.inputTokens : 0
            map[key]!.output += entry.outputTokens.isFinite ? entry.outputTokens : 0
            map[key]!.cached += entry.cachedInputTokens.isFinite ? entry.cachedInputTokens : 0
            map[key]!.reasoning += entry.reasoningOutputTokens.isFinite ? entry.reasoningOutputTokens : 0
        }
        // Clamp after summation so sub-integer token counts accumulate like the JS version.
        return order.map { key in
            let acc = map[key]!
            var bucket = acc.bucket
            bucket.inputTokens = toTokenCount(acc.input)
            bucket.outputTokens = toTokenCount(acc.output)
            bucket.cachedInputTokens = toTokenCount(acc.cached)
            bucket.reasoningOutputTokens = toTokenCount(acc.reasoning)
            bucket.totalTokens = bucket.inputTokens + bucket.outputTokens + bucket.reasoningOutputTokens
            return bucket
        }
    }

    // Hiding project names can collapse several buckets onto one identity;
    // re-fold them so no project's usage wins by iteration order.
    static func reaggregateHiddenProjectBuckets(_ buckets: [VibeBucket]) -> [VibeBucket] {
        var byHostname: [String: [VibeTokenEntry]] = [:]
        var hostnameOrder: [String] = []
        for bucket in buckets {
            guard let timestamp = VibeSyncTime.parse(bucket.bucketStart) else { continue }
            if byHostname[bucket.hostname] == nil { hostnameOrder.append(bucket.hostname) }
            byHostname[bucket.hostname, default: []].append(VibeTokenEntry(
                source: bucket.source, model: bucket.model, project: bucket.project,
                timestamp: timestamp,
                inputTokens: Double(bucket.inputTokens), outputTokens: Double(bucket.outputTokens),
                cachedInputTokens: Double(bucket.cachedInputTokens),
                reasoningOutputTokens: Double(bucket.reasoningOutputTokens)))
        }
        return hostnameOrder.flatMap { aggregateToBuckets(byHostname[$0] ?? [], hostname: $0) }
    }

    // Turn = first AI response → last AI response before the next user prompt.
    // activeSeconds sums turn durations; durationSeconds is first→last wall clock.
    static func extractSessions(_ events: [VibeSessionEvent]) -> [VibeSession] {
        var groups: [String: [VibeSessionEvent]] = [:]
        var order: [String] = []
        for event in events {
            if groups[event.sessionId] == nil { order.append(event.sessionId) }
            groups[event.sessionId, default: []].append(event)
        }
        return order.compactMap { sessionId in
            finalize(sessionId: sessionId, events: groups[sessionId]!.sorted { $0.timestamp < $1.timestamp })
        }
    }

    private static func finalize(sessionId: String, events: [VibeSessionEvent]) -> VibeSession? {
        guard let first = events.first, let last = events.last else { return nil }
        var activeSeconds = 0
        var turnStart: TimeInterval?
        var turnEnd: TimeInterval?
        var waitingForFirstResponse = false
        var userMessageCount = 0
        var userPromptHours = [Int](repeating: 0, count: 24)

        func commitTurn() {
            if let start = turnStart, let end = turnEnd, end > start {
                activeSeconds += Int(((end - start) / 1000).rounded())
            }
        }

        for event in events {
            let timestampMs = event.timestamp.timeIntervalSince1970 * 1000
            switch event.role {
            case .user:
                commitTurn()
                turnStart = nil
                turnEnd = nil
                waitingForFirstResponse = true
                userMessageCount += 1
                userPromptHours[VibeSyncTime.utcHour(event.timestamp)] += 1
            case .assistant:
                if waitingForFirstResponse {
                    turnStart = timestampMs
                    turnEnd = timestampMs
                    waitingForFirstResponse = false
                } else if turnStart != nil {
                    turnEnd = timestampMs
                }
            }
        }
        commitTurn()

        return VibeSession(
            source: first.source,
            project: first.project.isEmpty ? "unknown" : first.project,
            sessionHash: VibeSyncHashing.sha256Hex16(sessionId),
            hostname: "",
            firstMessageAt: VibeSyncTime.isoString(first.timestamp),
            lastMessageAt: VibeSyncTime.isoString(last.timestamp),
            durationSeconds: Int((last.timestamp.timeIntervalSince1970 - first.timestamp.timeIntervalSince1970).rounded()),
            activeSeconds: activeSeconds,
            messageCount: events.count,
            userMessageCount: userMessageCount,
            userPromptHours: userPromptHours)
    }
}

// MARK: - Hashing (byte-compatible with vibe-usage src/state.js)

enum VibeSyncHashing {
    static func sha256Hex16(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ parts: [String]) -> String {
        sha256Hex16(parts.joined(separator: "\0"))
    }

    static func bucketKey(_ bucket: VibeBucket) -> String {
        "\(bucket.source)|\(bucket.model)|\(bucket.project)|\(bucket.hostname)|\(bucket.bucketStart)"
    }

    static func bucketHash(_ bucket: VibeBucket) -> String {
        hash([
            String(bucket.inputTokens), String(bucket.outputTokens),
            String(bucket.cachedInputTokens), String(bucket.reasoningOutputTokens),
            String(bucket.totalTokens),
        ])
    }

    static func sessionKey(_ session: VibeSession) -> String {
        "\(session.source)|\(session.sessionHash)"
    }

    static func sessionStateHash(_ session: VibeSession) -> String {
        hash([
            session.project, session.hostname, session.firstMessageAt, session.lastMessageAt,
            String(session.durationSeconds), String(session.activeSeconds),
            String(session.messageCount), String(session.userMessageCount),
            session.userPromptHours.map(String.init).joined(separator: ","),
        ])
    }
}

// MARK: - Incremental state (~/.vibe-usage/state.json, shared with the official CLI)

struct VibeSyncState: Codable, Equatable, Sendable {
    var buckets: [String: String] = [:]
    var sessions: [String: String] = [:]

    // Drop keys the parsers no longer emit, scoped to sources whose parser ran
    // to completion this sync — a failing parser must not evict its own state.
    @discardableResult
    mutating func prune(liveBucketKeys: Set<String>, liveSessionKeys: Set<String>, okSources: Set<String>) -> Int {
        func source(of key: String) -> String {
            key.firstIndex(of: "|").map { String(key[..<$0]) } ?? key
        }
        var pruned = 0
        for key in buckets.keys where okSources.contains(source(of: key)) && !liveBucketKeys.contains(key) {
            buckets[key] = nil
            pruned += 1
        }
        for key in sessions.keys where okSources.contains(source(of: key)) && !liveSessionKeys.contains(key) {
            sessions[key] = nil
            pruned += 1
        }
        return pruned
    }
}

struct VibeSyncStateStore: Sendable {
    let fileURL: URL

    // Missing/corrupt state reads as empty, which triggers a one-time full upload.
    func load() -> VibeSyncState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(VibeSyncState.self, from: data)
        else { return VibeSyncState() }
        return state
    }

    // Atomic replace: JSONEncoder writes a temp file and renames over the target.
    func save(_ state: VibeSyncState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try JSONEncoder().encode(state)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - gzip (raw DEFLATE via Compression + manual header/CRC32/ISIZE)

enum VibeGzip {
    static func encode(_ data: Data) -> Data {
        var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        output.append(deflate(data))
        var crc = crc32(data)
        var size = UInt32(truncatingIfNeeded: data.count)
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    private static func deflate(_ data: Data) -> Data {
        if data.isEmpty { return Data([0x03, 0x00]) }
        var capacity = max(256, data.count + data.count / 2 + 64)
        while true {
            var destination = Data(count: capacity)
            let written: Int = destination.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_encode_buffer(
                        dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                        src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0, written < capacity {
                destination.count = written
                return destination
            }
            capacity *= 2
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - HTTP API (mirror of vibe-usage src/api.js)

enum VibeSyncError: Error, Equatable {
    case unauthorized
    case settingsUnavailable
    case invalidBaseURL
    case http(Int)
    case transport(String)
}

struct VibeIngestResponse: Decodable, Equatable, Sendable {
    let ingested: Int?
    let sessions: Int?
    let dropped: Dropped?
    let protected: Protected?

    struct Dropped: Decodable, Equatable, Sendable {
        let buckets: Int?
        let unknownModels: Int?
        let implausible: Int?
        let unknownSources: [String]?
    }

    struct Protected: Decodable, Equatable, Sendable {
        let buckets: Int?
    }
}

struct VibeSyncAPIClient: Sendable {
    static let maxRetries = 3

    let baseURL: String
    let apiKey: String
    let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let sleep: @Sendable (Duration) async -> Void
    let random: @Sendable () -> Double

    init(
        baseURL: String,
        apiKey: String,
        dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        sleep: (@Sendable (Duration) async -> Void)? = nil,
        random: (@Sendable () -> Double)? = nil)
    {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.dataLoader = dataLoader ?? { try await URLSession.shared.data(for: $0) }
        self.sleep = sleep ?? { try? await Task.sleep(for: $0) }
        self.random = random ?? { Double.random(in: 0..<1) }
    }

    // Equal jitter: ceiling/2 + random * ceiling/2, ceiling = 1s * 2^attempt.
    private func retryDelay(attempt: Int) -> Duration {
        let ceiling = 1000.0 * pow(2.0, Double(attempt))
        return .milliseconds(Int((ceiling / 2 + random() * ceiling / 2).rounded()))
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw VibeSyncError.invalidBaseURL
        }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse else { throw VibeSyncError.transport("invalid response") }
            return (data, http)
        } catch let error as VibeSyncError {
            throw error
        } catch {
            throw VibeSyncError.transport(error.localizedDescription)
        }
    }

    // GET /api/usage/settings → uploadProject. 401 throws unauthorized; other
    // permanent 4xx are an outage (settingsUnavailable), not retried — 429 is.
    func fetchUploadProjectSetting() async throws -> Bool {
        struct Settings: Decodable { let uploadProject: Bool? }
        var lastError: Error = VibeSyncError.settingsUnavailable
        for attempt in 0..<Self.maxRetries {
            do {
                var request = URLRequest(url: try endpoint("/api/usage/settings"))
                request.timeoutInterval = 10
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (data, http) = try await perform(request)
                if http.statusCode == 401 { throw VibeSyncError.unauthorized }
                if !(200...299).contains(http.statusCode) {
                    if (400...499).contains(http.statusCode), http.statusCode != 429 {
                        throw VibeSyncError.settingsUnavailable
                    }
                    throw VibeSyncError.http(http.statusCode)
                }
                guard let value = try? JSONDecoder().decode(Settings.self, from: data).uploadProject else {
                    throw VibeSyncError.transport("invalid settings response")
                }
                return value
            } catch VibeSyncError.unauthorized {
                throw VibeSyncError.unauthorized
            } catch VibeSyncError.settingsUnavailable {
                throw VibeSyncError.settingsUnavailable
            } catch VibeSyncError.invalidBaseURL {
                throw VibeSyncError.invalidBaseURL
            } catch {
                lastError = error
                if attempt < Self.maxRetries - 1 { await sleep(retryDelay(attempt: attempt)) }
            }
        }
        throw lastError
    }

    // POST /api/usage/ingest with a gzipped JSON body. 4xx (except 429) never retry.
    @discardableResult
    func ingest(buckets: [VibeBucket], sessions: [VibeSession], client: VibeSyncClientMeta) async throws -> VibeIngestResponse {
        struct Payload: Encodable {
            let buckets: [VibeBucket]
            let sessions: [VibeSession]?
            let client: VibeSyncClientMeta
        }
        let payload = Payload(buckets: buckets, sessions: sessions.isEmpty ? nil : sessions, client: client)
        let raw = try JSONEncoder().encode(payload)
        let body = VibeGzip.encode(raw)

        var lastError: Error = VibeSyncError.transport("unreachable")
        for attempt in 0..<Self.maxRetries {
            do {
                var request = URLRequest(url: try endpoint("/api/usage/ingest"))
                request.httpMethod = "POST"
                request.timeoutInterval = 60
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                request.httpBody = body
                let (data, http) = try await perform(request)
                if http.statusCode == 401 { throw VibeSyncError.unauthorized }
                guard (200...299).contains(http.statusCode) else { throw VibeSyncError.http(http.statusCode) }
                return try JSONDecoder().decode(VibeIngestResponse.self, from: data)
            } catch VibeSyncError.unauthorized {
                throw VibeSyncError.unauthorized
            } catch VibeSyncError.invalidBaseURL {
                throw VibeSyncError.invalidBaseURL
            } catch let error as VibeSyncError {
                lastError = error
                if case .http(let status) = error, (400...499).contains(status), status != 429 {
                    throw error
                }
                if attempt < Self.maxRetries - 1 { await sleep(retryDelay(attempt: attempt)) }
            } catch let error as DecodingError {
                lastError = VibeSyncError.transport("invalid ingest response: \(error)")
                if attempt < Self.maxRetries - 1 { await sleep(retryDelay(attempt: attempt)) }
            }
        }
        throw lastError
    }
}
