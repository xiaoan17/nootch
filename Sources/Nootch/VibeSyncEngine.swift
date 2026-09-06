import Foundation
import OSLog

// MARK: - Sync report

struct VibeSyncReport: Sendable, Equatable {
    enum Status: String, Sendable {
        case synced
        case dryRun
        case notConfigured
        case cancelled
        case unauthorized
        case failed
    }

    var status: Status
    var okSources: [String] = []
    var failedSources: [String] = []
    var liveBuckets = 0
    var liveSessions = 0
    var changedBuckets = 0
    var changedSessions = 0
    var uploadedBuckets = 0
    var uploadedSessions = 0
    var droppedBuckets = 0
    var prunedKeys = 0
    var error: String?
}

// MARK: - Sync engine

actor VibeSyncEngine {
    static let shared = VibeSyncEngine(parsers: [
        VibeClaudeCodeParser(),
        VibeSyncCodexParser(),
        VibeKimiCodeParser(),
        VibeGrokParser(),
        VibePiParser(),
    ])

    static let bucketBatchSize = 100
    static let sessionBatchSize = 500

    private(set) var parsers: [any VibeLogParser]

    private let configPath: String
    private let stateStore: VibeSyncStateStore
    private let dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    private let sleep: (@Sendable (Duration) async -> Void)?
    private let random: (@Sendable () -> Double)?
    private let logger = Logger(subsystem: "nootch", category: "VibeSync")

    init(
        parsers: [any VibeLogParser] = [],
        configPath: String = VibeUsageAdapter.defaultConfigPath,
        stateFileURL: URL? = nil,
        dataLoader: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        sleep: (@Sendable (Duration) async -> Void)? = nil,
        random: (@Sendable () -> Double)? = nil)
    {
        self.parsers = parsers
        self.configPath = configPath
        let directory = URL(fileURLWithPath: NSString(string: configPath).expandingTildeInPath).deletingLastPathComponent()
        self.stateStore = VibeSyncStateStore(fileURL: stateFileURL ?? directory.appendingPathComponent("state.json"))
        self.dataLoader = dataLoader
        self.sleep = sleep
        self.random = random
    }

    func register(_ parser: any VibeLogParser) {
        parsers.append(parser)
    }

    @discardableResult
    func sync(dryRun: Bool = false) async -> VibeSyncReport {
        var report = VibeSyncReport(status: .synced)
        do {
            report = try await run(dryRun: dryRun)
        } catch VibeSyncError.unauthorized {
            report.status = .unauthorized
            report.error = "invalid credentials"
            logger.error("vibe sync: API key rejected (401)")
        } catch {
            report.status = .failed
            report.error = error.localizedDescription
            logger.error("vibe sync failed: \(error.localizedDescription, privacy: .public)")
        }
        if report.status == .synced || report.status == .dryRun {
            logger.info("vibe sync \(report.status.rawValue, privacy: .public): \(report.uploadedBuckets) buckets / \(report.uploadedSessions) sessions uploaded, \(report.changedBuckets)+\(report.changedSessions) changed, \(report.prunedKeys) pruned")
        }
        return report
    }

    private func run(dryRun: Bool) async throws -> VibeSyncReport {
        var report = VibeSyncReport(status: dryRun ? .dryRun : .synced)

        guard var config = Self.loadConfigFile(at: configPath),
              let apiKey = (config["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            report.status = .notConfigured
            return report
        }
        let configuredURL = (config["apiUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apiURL = configuredURL.isEmpty ? VibeUsageAdapter.defaultAPIURL : configuredURL
        let client = VibeSyncAPIClient(baseURL: apiURL, apiKey: apiKey, dataLoader: dataLoader, sleep: sleep, random: random)

        // Privacy is a required input: on settings outage reuse the cached choice
        // for this same server; without a cache, cancel safely (no upload, no state change).
        let uploadProject: Bool
        let settingsFromAPI: Bool
        do {
            uploadProject = try await client.fetchUploadProjectSetting()
            settingsFromAPI = true
        } catch VibeSyncError.unauthorized {
            throw VibeSyncError.unauthorized
        } catch {
            let cachedURL = config["lastUploadProjectApiUrl"] as? String
            if cachedURL == apiURL, let cached = config["lastUploadProject"] as? Bool {
                uploadProject = cached
                settingsFromAPI = false
            } else {
                report.status = .cancelled
                return report
            }
        }

        // Run parsers concurrently; a failing or skipped parser never blocks the rest.
        let outcomes = await withTaskGroup(
            of: (Int, Result<VibeParseResult, Error>).self,
            returning: [(Int, Result<VibeParseResult, Error>)].self)
        { group in
            for (index, parser) in parsers.enumerated() {
                group.addTask { (index, Result { try parser.parse() }) }
            }
            var collected: [(Int, Result<VibeParseResult, Error>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected.sorted { $0.0 < $1.0 }
        }

        var allEntries: [VibeTokenEntry] = []
        var allEvents: [VibeSessionEvent] = []
        var okSources = Set<String>()
        for (index, outcome) in outcomes {
            let source = parsers[index].source
            switch outcome {
            case .failure(let error):
                report.failedSources.append(source)
                logger.error("vibe sync parser \(source, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            case .success(let result):
                if !result.skipped { okSources.insert(source) }
                allEntries.append(contentsOf: result.entries)
                allEvents.append(contentsOf: result.events)
            }
        }
        report.okSources = okSources.sorted()

        var state = stateStore.load()

        if allEntries.isEmpty, allEvents.isEmpty {
            // Even with nothing live, dead keys of successful parsers must be pruned.
            let pruned = state.prune(liveBucketKeys: [], liveSessionKeys: [], okSources: okSources)
            report.prunedKeys = pruned
            if !dryRun, pruned > 0 { try stateStore.save(state) }
            if !dryRun { persistConfig(&config, uploadProject: settingsFromAPI ? uploadProject : nil) }
            return report
        }

        // Hostname comes from config.json; generate + persist it if missing.
        var host = (config["hostname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty {
            host = Self.localHostname()
            config["hostname"] = host
        }

        var buckets = VibeAggregation.aggregateToBuckets(allEntries, hostname: host)
        var sessions = VibeAggregation.extractSessions(allEvents).map { session -> VibeSession in
            var session = session
            session.hostname = host
            return session
        }

        if !uploadProject {
            buckets = buckets.map { var b = $0; b.project = "unknown"; return b }
            sessions = sessions.map { var s = $0; s.project = "unknown"; return s }
            buckets = VibeAggregation.reaggregateHiddenProjectBuckets(buckets)
        }
        report.liveBuckets = buckets.count
        report.liveSessions = sessions.count

        // Incremental diff: only new/changed items go over the network.
        var changedBuckets: [VibeBucket] = []
        var changedSessions: [VibeSession] = []
        var liveBucketKeys = Set<String>()
        var liveSessionKeys = Set<String>()
        var pendingBucketState: [String: String] = [:]
        var pendingSessionState: [String: String] = [:]

        for bucket in buckets {
            let key = VibeSyncHashing.bucketKey(bucket)
            let hash = VibeSyncHashing.bucketHash(bucket)
            liveBucketKeys.insert(key)
            guard state.buckets[key] != hash else { continue }
            changedBuckets.append(bucket)
            pendingBucketState[key] = hash
        }
        for session in sessions {
            let key = VibeSyncHashing.sessionKey(session)
            let hash = VibeSyncHashing.sessionStateHash(session)
            liveSessionKeys.insert(key)
            guard state.sessions[key] != hash else { continue }
            changedSessions.append(session)
            pendingSessionState[key] = hash
        }
        report.changedBuckets = changedBuckets.count
        report.changedSessions = changedSessions.count

        // Prune dead keys immediately, independent of upload success.
        let pruned = state.prune(liveBucketKeys: liveBucketKeys, liveSessionKeys: liveSessionKeys, okSources: okSources)
        report.prunedKeys = pruned
        if !dryRun, pruned > 0 { try stateStore.save(state) }

        if dryRun { return report }

        if !changedBuckets.isEmpty || !changedSessions.isEmpty {
            let bucketBatches = (changedBuckets.count + Self.bucketBatchSize - 1) / Self.bucketBatchSize
            let sessionBatches = (changedSessions.count + Self.sessionBatchSize - 1) / Self.sessionBatchSize
            let batchCount = max(bucketBatches, sessionBatches, 1)
            let syncId = UUID().uuidString.lowercased()

            for batchIndex in 0..<batchCount {
                func slice<T>(_ items: [T], size: Int) -> ArraySlice<T> {
                    let lower = min(batchIndex * size, items.count)
                    let upper = min(lower + size, items.count)
                    return items[lower..<upper]
                }
                let batch = Array(slice(changedBuckets, size: Self.bucketBatchSize))
                let batchSessions = Array(slice(changedSessions, size: Self.sessionBatchSize))

                let meta = VibeSyncClientMeta.make(hostname: host, syncId: syncId, batchIndex: batchIndex, batchCount: batchCount)
                let response = try await client.ingest(buckets: batch, sessions: batchSessions, client: meta)

                report.uploadedBuckets += response.ingested ?? batch.count
                report.uploadedSessions += response.sessions ?? 0
                report.droppedBuckets += response.dropped?.buckets ?? 0
                // Buckets of a source the server rejected stay uncommitted so
                // the next sync retries them.
                let unknownSources = Set(response.dropped?.unknownSources ?? [])

                var stateChanged = false
                for bucket in batch where !unknownSources.contains(bucket.source) {
                    let key = VibeSyncHashing.bucketKey(bucket)
                    if let hash = pendingBucketState[key] {
                        state.buckets[key] = hash
                        stateChanged = true
                    }
                }
                for session in batchSessions {
                    let key = VibeSyncHashing.sessionKey(session)
                    if let hash = pendingSessionState[key] {
                        state.sessions[key] = hash
                        stateChanged = true
                    }
                }
                // Commit after each successful batch: a later failure re-sends
                // only the uncommitted suffix.
                if stateChanged { try stateStore.save(state) }
            }
        }

        persistConfig(&config, uploadProject: settingsFromAPI ? uploadProject : nil)
        return report
    }

    private static func localHostname() -> String {
        var name = Host.current().localizedName ?? ""
        if name.hasSuffix(".local") { name = String(name.dropLast(".local".count)) }
        return name.isEmpty ? "unknown" : name
    }

    // Reads config.json preserving every field (apiKey, extraRoots, ...).
    static func loadConfigFile(at path: String) -> [String: Any]? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    // Writes settings cache / generated hostname back without touching other keys.
    private func persistConfig(_ config: inout [String: Any], uploadProject: Bool?) {
        if let uploadProject {
            let configuredURL = (config["apiUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            config["lastUploadProject"] = uploadProject
            config["lastUploadProjectApiUrl"] = configuredURL.isEmpty ? VibeUsageAdapter.defaultAPIURL : configuredURL
        }
        let expanded = NSString(string: configPath).expandingTildeInPath
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: expanded), options: .atomic)
    }
}
