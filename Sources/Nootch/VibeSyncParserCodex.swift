import CryptoKit
import Foundation
import Synchronization

// Codex rollout parser — Swift port of vibe-usage's src/parsers/codex.js and
// src/codex-roots.js (https://github.com/vibe-cafe/vibe-usage).
//
// Scans `$CODEX_HOME/sessions` and `$CODEX_HOME/archived_sessions` (default
// `~/.codex`) for rollout `.jsonl` files and emits token entries plus session
// timing events. Message content is never read into the result: only token
// counts, model ids, project names and timestamps are extracted.
//
// Deliberate simplifications vs the official parser:
// - codex-cache.js (disk cache, tail-incremental append parsing, work-budget
//   checkpointing, rolling audits) is replaced by an in-memory mtime/size
//   cache. Files whose signature is unchanged are never re-read; a live file
//   that grew since the last sync is re-parsed in full (bounded to the size
//   stat'ed at discovery, like the JS snapshot).
// - Extra roots (codexExtraHome / extraRoots) and the cindy harness ledger
//   are not supported; only the primary Codex home is scanned, so this
//   parser never returns `skipped: true` — default roots are best-effort.
// - Token fingerprints hash a sorted-keys JSON serialization of the payload.
//   They are not byte-identical to the JS `JSON.stringify` hashes, but they
//   are only ever compared against other fingerprints produced here.
struct VibeSyncCodexParser: VibeLogParser {
    let source = "codex"

    private let codexHome: String

    init(codexHome: String? = nil) {
        if let codexHome, !codexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.codexHome = Self.normalizeHomePath(codexHome)
        } else if let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            self.codexHome = Self.normalizeHomePath(env)
        } else {
            self.codexHome = NSHomeDirectory() + "/.codex"
        }
    }

    // Model ids are bucket keys; service-tier attribution starts at a fixed
    // date so pre-release history stays byte-stable across upgrades.
    private static let serviceTierAttributionStartMs: Double = {
        let date = try! Date.ISO8601FormatStyle().parse("2026-08-31T00:00:00Z")
        return date.timeIntervalSince1970 * 1000
    }()

    // `task_started.started_at` is second-precision while the canonical
    // session timestamp has milliseconds; real child tasks start within a
    // few seconds of the child session.
    private static let ownTaskStartWindowMs = 5_000.0

    private enum ParseError: Error {
        case rolloutChangedWhileSyncing
        case unreadable(String)
    }

    // MARK: - parse()

    func parse() throws -> VibeParseResult {
        let sessionDirs = [
            (codexHome as NSString).appendingPathComponent("sessions"),
            (codexHome as NSString).appendingPathComponent("archived_sessions"),
        ]
        let fileManager = FileManager.default
        guard sessionDirs.contains(where: { fileManager.fileExists(atPath: $0) }) else {
            return VibeParseResult()
        }

        struct DiscoveredFile {
            let path: String
            let signature: FileSignature
        }
        var discovered: [DiscoveredFile] = []
        for dir in sessionDirs {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize, size > 0,
                      let mtime = values.contentModificationDate?.timeIntervalSince1970
                else { continue }
                discovered.append(DiscoveredFile(path: url.path, signature: FileSignature(size: size, mtime: mtime)))
            }
        }
        discovered.sort { $0.path < $1.path }
        if discovered.isEmpty { return VibeParseResult() }

        Self.fileCache.withLock { cache in
            let live = Set(discovered.map(\.path))
            cache.keys.filter { !live.contains($0) }.forEach { cache[$0] = nil }
        }

        // Cheap discovery pass: read only far enough for the canonical
        // (first) session_meta. Headers are cached across syncs — rollouts
        // are append-only, so a cached header stays valid while the file
        // only grew since it was read.
        struct FileState {
            let path: String
            let signature: FileSignature
            let header: RolloutHeader
        }
        var states: [FileState] = []
        for file in discovered {
            let cached = Self.fileCache.withLock { $0[file.path] }
            let header: RolloutHeader
            if let cached, file.signature.size >= cached.headerMinSize, file.signature.mtime >= cached.headerMtime {
                header = cached.header
            } else {
                guard let read = Self.readHeader(at: file.path, maxBytes: file.signature.size) else { continue }
                header = read
                Self.fileCache.withLock { cache in
                    var entry = cache[file.path] ?? CachedFile(headerMinSize: 0, headerMtime: 0, header: read)
                    entry.headerMinSize = file.signature.size
                    entry.headerMtime = file.signature.mtime
                    entry.header = read
                    cache[file.path] = entry
                }
            }
            states.append(FileState(path: file.path, signature: file.signature, header: header))
        }

        var countsById: [String: Int] = [:]
        for state in states {
            if let id = state.header.sessionId { countsById[id, default: 0] += 1 }
        }
        let duplicateIds = Set(countsById.filter { $0.value > 1 }.keys)
        var referencedParentIds = Set<String>()
        for state in states {
            let header = state.header
            if let parentId = header.forkedFromId ?? (header.isSubagent ? header.parentThreadId : nil) {
                referencedParentIds.insert(parentId)
            }
        }

        // Only replay participants, their parents, corrupt-header files and
        // duplicate physical copies need the full compact token index.
        var metas: [String: FileMeta] = [:]
        var needsIndex = Set<String>()
        for state in states {
            let header = state.header
            let required = header.sessionId == nil
                || header.isSubagent
                || header.forkedFromId != nil
                || header.parentThreadId != nil
                || (header.sessionId.map { referencedParentIds.contains($0) } ?? false)
                || (header.sessionId.map { duplicateIds.contains($0) } ?? false)
            if !required {
                metas[state.path] = FileMeta(path: state.path, header: header)
                continue
            }
            needsIndex.insert(state.path)
            let signature = state.signature
            let cached = Self.fileCache.withLock { $0[state.path] }
            if let cached, cached.signature == signature, let index = cached.index {
                metas[state.path] = index
                continue
            }
            guard let index = Self.buildIndex(at: state.path, maxBytes: signature.size) else { continue }
            Self.fileCache.withLock { cache in
                var entry = cache[state.path] ?? CachedFile(headerMinSize: signature.size, headerMtime: signature.mtime, header: state.header)
                entry.signature = signature
                entry.index = index
                entry.boundaryKey = nil
                entry.entries = []
                entry.events = []
                cache[state.path] = entry
            }
            metas[state.path] = index
        }

        // Select the most complete physical copy of each session: the same
        // rollout can briefly exist in both sessions/ and archived_sessions/
        // during an archive move, and counting both would double its usage.
        var sessionById: [String: FileMeta] = [:]
        for state in states {
            guard let meta = metas[state.path], let id = meta.sessionId else { continue }
            let count = meta.parsedRecordCount ?? 0
            if let existing = sessionById[id], (existing.parsedRecordCount ?? 0) >= count { continue }
            sessionById[id] = meta
        }

        var result = VibeParseResult()
        for state in states {
            guard let meta = metas[state.path] else { continue }
            if let id = meta.sessionId, sessionById[id]?.path != state.path { continue }

            let indexed = needsIndex.contains(state.path)
            let boundary = indexed
                ? Self.replayBoundary(meta, sessionById: sessionById)
                : ReplayBoundary(rawTokenCount: 0, recordIndex: nil)
            let key = "\(boundary.rawTokenCount):\(boundary.recordIndex.map(String.init) ?? "")"

            if let cached = Self.fileCache.withLock({ $0[state.path] }),
               cached.signature == state.signature, cached.boundaryKey == key {
                result.entries.append(contentsOf: cached.entries)
                result.events.append(contentsOf: cached.events)
                continue
            }
            let parsed = try Self.parseFile(
                at: state.path, maxBytes: state.signature.size,
                meta: meta, boundary: boundary, indexed: indexed)
            Self.fileCache.withLock { cache in
                var entry = cache[state.path] ?? CachedFile(headerMinSize: state.signature.size, headerMtime: state.signature.mtime, header: state.header)
                entry.signature = state.signature
                entry.boundaryKey = key
                entry.entries = parsed.entries
                entry.events = parsed.events
                cache[state.path] = entry
            }
            result.entries.append(contentsOf: parsed.entries)
            result.events.append(contentsOf: parsed.events)
        }
        return result
    }

    // MARK: - Roots (port of codex-roots.js)

    private static func normalizeHomePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") || trimmed.hasPrefix("~\\") {
            return NSHomeDirectory() + "/" + trimmed.dropFirst(2)
        }
        return NSString(string: trimmed).standardizingPath
    }

    // MARK: - Header pass (readSessionHeader)

    private struct RolloutHeader: Sendable, Equatable {
        var sessionId: String?
        var forkedFromId: String?
        var parentThreadId: String?
        var project = "unknown"
        var startedAtMs: Double?
        var isSubagent = false
    }

    private static func readHeader(at path: String, maxBytes: Int) -> RolloutHeader? {
        var header: RolloutHeader?
        guard forEachLine(at: path, maxBytes: maxBytes, { line in
            guard let object = parseObject(line),
                  object["type"] as? String == "session_meta",
                  let meta = object["payload"] as? [String: Any]
            else { return true }
            header = headerFromMeta(meta, recordTimestampMs: timestampMs(object["timestamp"]))
            return false
        }) else { return nil }
        return header ?? RolloutHeader()
    }

    private static func headerFromMeta(_ meta: [String: Any], recordTimestampMs: Double?) -> RolloutHeader {
        RolloutHeader(
            sessionId: nonEmpty(meta["id"]),
            forkedFromId: nonEmpty(meta["forked_from_id"]),
            parentThreadId: extractParentThreadId(meta),
            project: extractProject(meta),
            startedAtMs: timestampMs(meta["timestamp"]) ?? recordTimestampMs,
            isSubagent: isSubagentMeta(meta))
    }

    // e.g. https://github.com/org/repo.git → org/repo; else cwd's last
    // path component; else "unknown".
    private static func extractProject(_ meta: [String: Any]) -> String {
        if let git = meta["git"] as? [String: Any], let url = git["repository_url"] as? String {
            var stripped = url
            if stripped.hasSuffix(".git") { stripped = String(stripped.dropLast(4)) }
            let parts = stripped.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count >= 2, let repo = parts.last, !repo.isEmpty {
                let org = parts[parts.count - 2]
                if !org.isEmpty { return "\(org)/\(repo)" }
            }
        }
        if let cwd = meta["cwd"] as? String,
           let last = cwd.split(separator: "/", omittingEmptySubsequences: false).last,
           !last.isEmpty {
            return String(last)
        }
        return "unknown"
    }

    // Depending on the Codex version the sub-agent marker is
    // `thread_source: "subagent"`, a `source: { subagent: {...} }` object, or
    // just a `parent_thread_id` — check all three.
    private static func isSubagentMeta(_ meta: [String: Any]) -> Bool {
        if meta["thread_source"] as? String == "subagent" { return true }
        if let source = meta["source"] {
            if source as? String == "subagent" { return true }
            if let object = source as? [String: Any], object.keys.contains("subagent") { return true }
        }
        if let value = meta["parent_thread_id"], !(value is NSNull) { return true }
        return false
    }

    private static func extractParentThreadId(_ meta: [String: Any]) -> String? {
        if let id = nonEmpty(meta["parent_thread_id"]) { return id }
        let source = meta["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        return nonEmpty(spawn?["parent_thread_id"])
    }

    // MARK: - Index pass (indexSessionFile)

    private struct TaskBoundary: Sendable, Equatable {
        var recordIndex: Int
        var rawTokenCount: Int
        var startedAtMs: Double?
    }

    private struct FileMeta: Sendable {
        var path: String
        var sessionId: String?
        var forkedFromId: String?
        var parentThreadId: String?
        var project = "unknown"
        var startedAtMs: Double?
        var isSubagent = false
        var sessionMetaCount: Int?
        var parsedRecordCount: Int?
        var rawTokenCount: Int?
        var tokenTimes: [Double] = []
        var tokenFingerprints: [String] = []
        var taskBoundaries: [TaskBoundary] = []
        var firstTaskBoundary: TaskBoundary?
        var ownTaskBoundary: TaskBoundary?

        init(path: String, header: RolloutHeader) {
            self.path = path
            sessionId = header.sessionId
            forkedFromId = header.forkedFromId
            parentThreadId = header.parentThreadId
            project = header.project
            startedAtMs = header.startedAtMs
            isSubagent = header.isSubagent
        }

        init(path: String) {
            self.path = path
        }
    }

    // Only the first session_meta is canonical; later ones are replayed
    // records and must never overwrite it. tokenTimes preserves raw
    // token_count ordinals on a monotonic timeline; tokenFingerprints
    // identifies an exact copied sequence even for last-N-turns forks.
    private static func buildIndex(at path: String, maxBytes: Int) -> FileMeta? {
        var meta = FileMeta(path: path)
        var sessionMetaCount = 0
        var parsedRecordCount = 0
        var rawTokenCount = 0
        var logicalTimestamp = -Double.infinity
        var tokenTimes: [Double] = []
        var tokenFingerprints: [String] = []
        var pendingTokenTimeIndexes: [Int] = []

        guard forEachLine(at: path, maxBytes: maxBytes, { line in
            guard let object = parseObject(line) else { return true }
            parsedRecordCount += 1

            let recordTimestamp = timestampMs(object["timestamp"])
            if let recordTimestamp {
                logicalTimestamp = max(logicalTimestamp, recordTimestamp)
                // An invalid token_count timestamp is placed at the next
                // valid record time; leftovers stay +Infinity, which biases
                // the parent-at-spawn boundary toward under-skip.
                for index in pendingTokenTimeIndexes { tokenTimes[index] = logicalTimestamp }
                pendingTokenTimeIndexes.removeAll()
            }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            if type == "session_meta", let payload {
                sessionMetaCount += 1
                if sessionMetaCount == 1 {
                    let header = headerFromMeta(payload, recordTimestampMs: recordTimestamp)
                    meta.sessionId = header.sessionId
                    meta.forkedFromId = header.forkedFromId
                    meta.parentThreadId = header.parentThreadId
                    meta.project = header.project
                    meta.startedAtMs = header.startedAtMs
                    meta.isSubagent = header.isSubagent
                }
            } else if type == "event_msg", payload?["type"] as? String == "token_count", let payload {
                rawTokenCount += 1
                tokenFingerprints.append(tokenFingerprint(payload))
                if recordTimestamp == nil {
                    tokenTimes.append(.infinity)
                    pendingTokenTimeIndexes.append(tokenTimes.count - 1)
                } else {
                    tokenTimes.append(logicalTimestamp)
                }
            } else if type == "event_msg", isTaskStarted(payload) {
                let boundary = TaskBoundary(
                    recordIndex: parsedRecordCount,
                    rawTokenCount: rawTokenCount,
                    startedAtMs: epochMs(payload?["started_at"]))
                meta.taskBoundaries.append(boundary)
                if meta.firstTaskBoundary == nil { meta.firstTaskBoundary = boundary }
                if let startedAtMs = boundary.startedAtMs, let sessionStart = meta.startedAtMs,
                   abs(startedAtMs - sessionStart) <= ownTaskStartWindowMs {
                    // Keep the last match so a copied parent task that started
                    // in the same second cannot win over the child's own one.
                    meta.ownTaskBoundary = boundary
                }
            }
            return true
        }) else { return nil }

        meta.sessionMetaCount = sessionMetaCount
        meta.parsedRecordCount = parsedRecordCount
        meta.rawTokenCount = rawTokenCount
        meta.tokenTimes = tokenTimes
        meta.tokenFingerprints = tokenFingerprints
        return meta
    }

    private static func isTaskStarted(_ payload: [String: Any]?) -> Bool {
        let type = payload?["type"] as? String
        return type == "task_started" || type == "turn_started"
    }

    // Copied rollout items are re-serialized with a fresh outer timestamp,
    // but their token_count payload is unchanged. A compact payload hash
    // identifies replayed records without retaining raw usage objects.
    private static func tokenFingerprint(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return "" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Replay boundary (replayBoundary)

    private struct ReplayBoundary: Sendable, Equatable {
        var rawTokenCount: Int
        var recordIndex: Int?
    }

    private static func replayBoundary(_ meta: FileMeta, sessionById: [String: FileMeta]) -> ReplayBoundary {
        let parentId = meta.forkedFromId ?? (meta.isSubagent ? meta.parentThreadId : nil)
        let parent = parentId.flatMap { sessionById[$0] }
        let parentSnapshot: [String]
        if let parent, let startedAtMs = meta.startedAtMs {
            parentSnapshot = Array(parent.tokenFingerprints.prefix(upperBound(parent.tokenTimes, startedAtMs)))
        } else {
            parentSnapshot = []
        }
        let replayTokenCount = longestReplayPrefix(child: meta.tokenFingerprints, parent: parentSnapshot)
        let partialReplayTokenCount = meta.isSubagent
            ? longestPartialReplayPrefix(child: meta.tokenFingerprints, parent: parentSnapshot)
            : 0

        if meta.isSubagent {
            // Direct evidence inside the child wins. Exact token matching
            // also handles last-N-turns forks: when it identifies the copied
            // token suffix, the last task_started at that same raw ordinal is
            // the child's own task boundary.
            var matchedTaskBoundary: TaskBoundary?
            if replayTokenCount > 0, let startedAtMs = meta.startedAtMs {
                let floorMs = (startedAtMs / 1000).rounded(.down) * 1000
                matchedTaskBoundary = meta.taskBoundaries.last {
                    $0.rawTokenCount == replayTokenCount && $0.startedAtMs != nil && $0.startedAtMs! >= floorMs
                }
            }
            let direct = matchedTaskBoundary
                ?? meta.ownTaskBoundary
                ?? (meta.sessionMetaCount == 1 && meta.forkedFromId == nil ? meta.firstTaskBoundary : nil)
            if let direct {
                return ReplayBoundary(
                    rawTokenCount: max(replayTokenCount, partialReplayTokenCount, direct.rawTokenCount),
                    recordIndex: direct.recordIndex)
            }
            // The child may be synced while Codex is still copying the parent
            // block; defer those leading records until a stable suffix or
            // task boundary appears.
            return ReplayBoundary(rawTokenCount: max(replayTokenCount, partialReplayTokenCount), recordIndex: nil)
        }

        if meta.forkedFromId != nil {
            return ReplayBoundary(rawTokenCount: replayTokenCount, recordIndex: nil)
        }
        return ReplayBoundary(rawTokenCount: 0, recordIndex: nil)
    }

    // MARK: - Usage pass (parseSessionFile)

    private static func parseFile(
        at path: String, maxBytes: Int, meta: FileMeta, boundary: ReplayBoundary, indexed: Bool
    ) throws -> (entries: [VibeTokenEntry], events: [VibeSessionEvent]) {
        var entries: [VibeTokenEntry] = []
        var events: [VibeSessionEvent] = []
        var rawTokenSeen = 0
        var parsedRecordIndex = 0
        var firstSessionMetaSeen = false
        // Group timing events by the real Codex session id, not the file
        // path: the same session can briefly exist in both directories.
        let sessionKey = meta.sessionId ?? path
        var turnContextModel: String?
        var serviceTier: String?
        var prevTotal: [String: Double]?
        var prevCumulativeTotal: Double?

        guard forEachLine(at: path, maxBytes: maxBytes, { line in
            guard let object = parseObject(line) else { return true }
            parsedRecordIndex += 1

            // A direct child task boundary covers every copied record. The
            // raw-token ordinal covers forks whose exact payload sequence was
            // matched in the index pass.
            let beforeOwnTask = boundary.recordIndex.map { parsedRecordIndex < $0 } ?? false
            let inReplayBlock = beforeOwnTask || rawTokenSeen < boundary.rawTokenCount

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let isSessionMeta = type == "session_meta"
            let isCanonicalSessionMeta = isSessionMeta && !firstSessionMetaSeen
            let isOwnSessionMeta = isSessionMeta && nonEmpty(payload?["id"]) != nil
                && nonEmpty(payload?["id"]) == meta.sessionId
            if isSessionMeta { firstSessionMetaSeen = true }

            if let timestampMs = timestampMs(object["timestamp"]) {
                // Repeated same-id metadata belongs to this logical session;
                // a different-id meta is copied parent history and must not
                // inflate timing stats.
                let keepSessionMeta = isCanonicalSessionMeta || (isOwnSessionMeta && !inReplayBlock)
                if keepSessionMeta || (!isSessionMeta && !inReplayBlock) {
                    let isUserTurn = type == "turn_context" || isSessionMeta
                    events.append(VibeSessionEvent(
                        sessionId: sessionKey, source: "codex", project: meta.project,
                        timestamp: Date(timeIntervalSince1970: timestampMs / 1000),
                        role: isUserTurn ? .user : .assistant))
                }
            }

            if type == "turn_context" {
                if let model = nonEmpty(payload?["model"]) { turnContextModel = model }
                if let payload, payload.keys.contains("service_tier") {
                    serviceTier = normalizeServiceTier(payload["service_tier"])
                }
                return true
            }

            guard type == "event_msg", let payload else { return true }
            let payloadType = payload["type"] as? String

            if payloadType == "thread_settings_applied" {
                let settings = payload["thread_settings"] as? [String: Any]
                if let model = nonEmpty(settings?["model"]) { turnContextModel = model }
                if let settings, settings.keys.contains("service_tier") {
                    serviceTier = normalizeServiceTier(settings["service_tier"])
                }
                return true
            }

            guard payloadType == "token_count" else { return true }

            // Raw ordinals advance before validating usage/timestamp so the
            // two passes cannot drift on a malformed copied token_count.
            let isReplayedHistory = inReplayBlock
            rawTokenSeen += 1

            guard let info = payload["info"] as? [String: Any] else { return true }
            let totalUsage = info["total_token_usage"] as? [String: Any]

            // Codex sometimes writes the same token_count twice back-to-back.
            // A real API call always advances the cumulative counter, so an
            // unchanged positive total marks a duplicate emission — or a
            // zero-usage bookkeeping event — and must count as zero.
            let cumulativeTotal = number(totalUsage?["total_tokens"])
            let isDuplicateEmission = cumulativeTotal.map { $0 > 0 && $0 == prevCumulativeTotal } ?? false
            if let cumulativeTotal { prevCumulativeTotal = cumulativeTotal }

            // Prefer incremental per-request usage; compute delta from
            // cumulative totals as fallback. Always advance the cumulative
            // baseline, even when the record belongs to a replay.
            var usage = info["last_token_usage"] as? [String: Any]
            if usage == nil, let current = totalUsage {
                if let prev = prevTotal {
                    let delta: [String: Any] = [
                        "input_tokens": (number(current["input_tokens"]) ?? 0) - (prev["input_tokens"] ?? 0),
                        "output_tokens": (number(current["output_tokens"]) ?? 0) - (prev["output_tokens"] ?? 0),
                        "cached_input_tokens": (number(current["cached_input_tokens"]) ?? 0) - (prev["cached_input_tokens"] ?? 0),
                        "reasoning_output_tokens": (number(current["reasoning_output_tokens"]) ?? 0) - (prev["reasoning_output_tokens"] ?? 0),
                    ]
                    // Counters can reset after compaction; treat the first
                    // post-reset total as a fresh baseline rather than
                    // letting a negative delta cancel legitimate usage.
                    usage = delta.values.contains(where: { ($0 as? Double ?? 0) < 0 }) ? current : delta
                } else {
                    usage = current
                }
            }
            // total_token_usage is session-wide, not per model; a global
            // baseline avoids recounting the cumulative total after a model
            // switch.
            if let current = totalUsage {
                prevTotal = [
                    "input_tokens": number(current["input_tokens"]) ?? 0,
                    "output_tokens": number(current["output_tokens"]) ?? 0,
                    "cached_input_tokens": number(current["cached_input_tokens"]) ?? 0,
                    "reasoning_output_tokens": number(current["reasoning_output_tokens"]) ?? 0,
                ]
            }
            guard let usage else { return true }
            if isReplayedHistory || isDuplicateEmission { return true }

            guard let eventTimestampMs = timestampMs(object["timestamp"]) else { return true }

            let rawModel = nonEmpty(info["model"]) ?? nonEmpty(payload["model"]) ?? turnContextModel ?? "unknown"
            let model = decorateModel(rawModel, serviceTier: serviceTier, timestampMs: eventTimestampMs)

            // OpenAI API: input_tokens INCLUDES cached, output_tokens
            // INCLUDES reasoning. Normalize to non-overlapping fields.
            let cached = number(usage["cached_input_tokens"])
            let cachedInput = (cached != nil && cached != 0 ? cached : nil) ?? number(usage["cache_read_input_tokens"]) ?? 0
            let reasoningOutput = number(usage["reasoning_output_tokens"]) ?? 0
            entries.append(VibeTokenEntry(
                source: "codex",
                model: model,
                project: meta.project,
                timestamp: Date(timeIntervalSince1970: eventTimestampMs / 1000),
                inputTokens: (number(usage["input_tokens"]) ?? 0) - cachedInput,
                outputTokens: (number(usage["output_tokens"]) ?? 0) - reasoningOutput,
                cachedInputTokens: cachedInput,
                reasoningOutputTokens: reasoningOutput))
            return true
        }) else { throw ParseError.unreadable(path) }

        // Indexed files must match both passes exactly; a mismatch means the
        // rollout changed mid-sync and the next sync retries it.
        if indexed, let expectedRecords = meta.parsedRecordCount, let expectedTokens = meta.rawTokenCount,
           parsedRecordIndex != expectedRecords || rawTokenSeen != expectedTokens {
            throw ParseError.rolloutChangedWhileSyncing
        }
        return (entries, events)
    }

    private static func normalizeServiceTier(_ value: Any?) -> String? {
        guard let tier = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return nil }
        switch tier {
        case "fast", "priority", "flex", "batch": return tier
        default: return nil
        }
    }

    private static func decorateModel(_ model: String, serviceTier: String?, timestampMs: Double) -> String {
        guard model != "unknown", let serviceTier, timestampMs >= serviceTierAttributionStartMs
        else { return model }
        return "\(model)-\(serviceTier)"
    }

    // MARK: - Sequence matching (KMP, ported verbatim in spirit)

    // Longest prefix of `child` that is also a suffix of `parent`. Codex can
    // fork full history or the last N turns, but the copied block always
    // reaches the source snapshot's end.
    private static func longestReplayPrefix(child: [String], parent: [String]) -> Int {
        guard !child.isEmpty, !parent.isEmpty else { return 0 }
        let prefix = kmpTable(child)
        var matched = 0
        for (index, fingerprint) in parent.enumerated() {
            while matched > 0 && fingerprint != child[matched] { matched = prefix[matched - 1] }
            if fingerprint == child[matched] { matched += 1 }
            if matched == child.count && index < parent.count - 1 { matched = prefix[matched - 1] }
        }
        return matched
    }

    // Longest prefix of `child` found contiguously anywhere in `parent`: a
    // live sub-agent rollout can be observed mid-copy, before the copy
    // reaches the parent snapshot's end.
    private static func longestPartialReplayPrefix(child: [String], parent: [String]) -> Int {
        guard !child.isEmpty, !parent.isEmpty else { return 0 }
        let prefix = kmpTable(child)
        var matched = 0
        var longest = 0
        for fingerprint in parent {
            while matched > 0 && fingerprint != child[matched] { matched = prefix[matched - 1] }
            if fingerprint == child[matched] { matched += 1 }
            longest = max(longest, matched)
            if matched == child.count { matched = prefix[matched - 1] }
        }
        return longest
    }

    private static func kmpTable(_ pattern: [String]) -> [Int] {
        var prefix = [Int](repeating: 0, count: pattern.count)
        var matched = 0
        for index in 1..<pattern.count {
            while matched > 0 && pattern[index] != pattern[matched] { matched = prefix[matched - 1] }
            if pattern[index] == pattern[matched] { matched += 1 }
            prefix[index] = matched
        }
        return prefix
    }

    private static func upperBound(_ sorted: [Double], _ target: Double) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = low + (high - low) / 2
            if sorted[mid] <= target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - mtime/size result cache

    private struct FileSignature: Equatable, Sendable {
        let size: Int
        let mtime: TimeInterval
    }

    private struct CachedFile: Sendable {
        // The header is valid while the append-only file only grew since the
        // read; index/entries/events are valid only at an exact signature.
        var headerMinSize: Int
        var headerMtime: TimeInterval
        var header: RolloutHeader
        var signature: FileSignature?
        var index: FileMeta?
        var boundaryKey: String?
        var entries: [VibeTokenEntry] = []
        var events: [VibeSessionEvent] = []
    }

    private static let fileCache = Mutex<[String: CachedFile]>([:])

    // MARK: - Streaming + value helpers

    // Read one 64KB chunk at a time, bounded to `maxBytes` (the size stat'ed
    // at discovery), retaining only an unfinished row between reads. A
    // snapshot cut mid-line yields a partial final row that fails JSON
    // parsing and is skipped — identical across passes given equal maxBytes.
    private static func forEachLine(at path: String, maxBytes: Int, _ consume: (Data) -> Bool) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? file.close() }
        var pending = Data()
        pending.reserveCapacity(256 * 1024)
        var start = pending.startIndex
        var remaining = maxBytes
        while remaining > 0 {
            let chunk: Data
            do { chunk = try file.read(upToCount: min(64 * 1024, remaining)) ?? Data() } catch { return false }
            if chunk.isEmpty { break }
            remaining -= chunk.count
            pending.append(chunk)
            var end = start
            var index = start
            while index < pending.endIndex {
                if pending[index] == 10 {
                    if !consume(Data(pending[end..<index])) { return true }
                    end = pending.index(after: index)
                }
                index = pending.index(after: index)
            }
            start = end
            if pending.distance(from: pending.startIndex, to: start) > 1_048_576 {
                pending.removeFirst(pending.distance(from: pending.startIndex, to: start))
                start = pending.startIndex
            }
        }
        if start < pending.endIndex { _ = consume(Data(pending[start...])) }
        return true
    }

    private static func parseObject(_ line: Data) -> [String: Any]? {
        autoreleasepool {
            try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoSeconds = Date.ISO8601FormatStyle()

    private static func parseISODate(_ string: String) -> Date? {
        (try? isoFractional.parse(string)) ?? (try? isoSeconds.parse(string))
    }

    private static func timestampMs(_ value: Any?) -> Double? {
        if let string = value as? String, !string.isEmpty {
            return parseISODate(string).map { $0.timeIntervalSince1970 * 1000 }
        }
        return number(value)
    }

    private static func epochMs(_ value: Any?) -> Double? {
        var result: Double?
        if let string = value as? String, !string.trimmingCharacters(in: .whitespaces).isEmpty {
            result = Double(string)
        } else {
            result = number(value)
        }
        guard let result, result.isFinite else { return nil }
        return result < 1e12 ? result * 1000 : result
    }
}
