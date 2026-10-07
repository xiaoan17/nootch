import Foundation

/// Droid parser — Swift port of vibe-usage `src/parsers/droid.js` (introduced
/// in upstream 7c48693, with the fix chain 1db0c8f / c55b82c / 8dd5c95) plus
/// the path resolution of `getDroidSessionsDir` / `getDroidSettingsPaths` from
/// `src/tools.js`.
///
/// Factory's Droid stores one JSONL session log per session under
/// `~/.factory/sessions/<project-slug>/<sessionId>.jsonl` (fixture override
/// VIBE_USAGE_DROID_SESSIONS) and keeps the per-session token totals in a
/// sidecar `<sessionId>.settings.json` next to it. The session log itself
/// carries no usage, so entries come from the sidecar and are timestamped at
/// the session's first message; the log contributes the session events.
///
/// Token semantics (8dd5c95): Factory's sidecar `inputTokens` is already the
/// UNCACHED prompt — its own session log records inputTokens +
/// cacheReadInputTokens = totalInputTokens, so cacheReadTokens must NOT be
/// subtracted (doing so zeroed BYOK input whenever cache > input).
/// `outputTokens` includes thinking, so thinkingTokens is split out into
/// reasoningOutputTokens. `cacheCreationTokens` has no TTL breakdown and goes
/// to the 5m cache-creation column (same rule as every parser with a single
/// cache-write counter). `factoryCredits` is account funding, never collected.
///
/// Model resolution (8dd5c95): the sidecar `model` is a local slot id
/// (`custom:gpt-6-astra-[gw]-0`), not the API model. `customModels[].id →
/// .model` in the Factory settings files maps a slot to what the provider
/// actually sees; without a catalog entry the `custom:<slug>-[<gw>]-<n>`
/// wrapper is stripped. Bare routing words would collide with Cursor's pricing
/// entry (PR #83), so tier ids are namespaced (`droid-<tier>`). Fixture
/// sessions must not read the real ~/.factory/settings.json (API keys, and it
/// would leak the machine catalog into tests): VIBE_USAGE_DROID_SETTINGS pins
/// the catalog file, and setting VIBE_USAGE_DROID_SESSIONS without it reads no
/// catalog at all.
///
/// Differences from the JS original:
/// - The JS parser has no `skipped`/warnings channel at all: an unreadable
///   session file or malformed sidecar is silently passed over. The port keeps
///   that (the source always reports a complete snapshot of what it could
///   read).
/// - JS `Number(value)` accepts booleans; here booleans are treated as missing
///   (consistent with the other ports).
struct VibeSyncDroidParser: VibeLogParser {
    let source = "droid"

    private let sessionsDir: String
    private let settingsPaths: [String]

    init(
        sessionsDir: String? = nil,
        settingsPaths: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory())
    {
        let resolvedSessions = sessionsDir
            ?? Self.envValue("VIBE_USAGE_DROID_SESSIONS", environment: environment)
            ?? home + "/.factory/sessions"
        self.sessionsDir = resolvedSessions
        if let settingsPaths {
            self.settingsPaths = settingsPaths
        } else if let override = Self.envValue("VIBE_USAGE_DROID_SETTINGS", environment: environment) {
            self.settingsPaths = [override]
        } else if Self.envValue("VIBE_USAGE_DROID_SESSIONS", environment: environment) != nil || sessionsDir != nil {
            // Fixture sessions never read the real Factory settings catalog.
            self.settingsPaths = []
        } else {
            self.settingsPaths = [
                home + "/.factory/settings.json",
                home + "/.factory/settings.local.json",
                home + "/.factory/config.json",
            ]
        }
    }

    private static func envValue(_ key: String, environment: [String: String]) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    // MARK: - Model resolution

    // Factory routing words are not model ids; namespaced so they never match
    // another vendor's price (PR #83).
    private static let routingTierIds: Set<String> = [
        "auto", "default", "default-model", "fast", "turbo", "lite",
        "ultimate", "performance", "efficient",
    ]

    // custom:<slug>-[<gateway>]-<n>
    private static let customSlotRegex = try! NSRegularExpression(
        pattern: #"^custom:(.+)-\[([^\]]+)\]-(\d+)$"#)

    static func resolveModel(_ raw: Any?, catalog: [String: String]) -> String {
        let id = (raw as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !id.isEmpty else { return "unknown" }
        let resolved: String
        if let mapped = catalog[id]?.trimmingCharacters(in: .whitespaces), !mapped.isEmpty {
            resolved = mapped
        } else if let match = customSlotRegex.firstMatch(
            in: id, range: NSRange(id.startIndex..., in: id)),
            let slug = Range(match.range(at: 1), in: id)
        {
            resolved = String(id[slug])
        } else {
            resolved = id
        }
        let lower = resolved.lowercased()
        return routingTierIds.contains(lower) ? "droid-\(lower)" : resolved
    }

    /// customModels[].id → API model, across every settings file (JS
    /// loadDroidCustomModelCatalog; later files overwrite earlier ids).
    private func loadCustomModelCatalog() -> [String: String] {
        var catalog: [String: String] = [:]
        for path in settingsPaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for key in ["customModels", "custom_models"] {
                guard let list = settings[key] as? [Any] else { continue }
                for case let entry as [String: Any] in list {
                    let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                    let model = (entry["model"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !id.isEmpty && !model.isEmpty { catalog[id] = model }
                }
            }
        }
        return catalog
    }

    // MARK: - Session discovery

    /// Recursive *.jsonl collection; `*.settings.json` sidecars are excluded.
    /// Unreadable branches are silently skipped, like the JS catch-all.
    private static func findSessionFiles(_ directory: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var files: [String] = []
        for entry in entries {
            let path = directory + "/" + entry
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                files.append(contentsOf: findSessionFiles(path))
            } else if entry.hasSuffix(".jsonl") && !entry.hasSuffix(".settings.json") {
                files.append(path)
            }
        }
        return files
    }

    /// Project from the slug folder: last dash-component (JS
    /// extractProjectFromSlug; "private-tmp" → "tmp").
    private static func projectFromSlug(_ slug: String) -> String {
        slug.split(separator: "-", omittingEmptySubsequences: true).last.map(String.init) ?? "unknown"
    }

    // MARK: - Value coercion

    /// JS toSafeNumber: Number(value), kept when finite (negatives included),
    /// else 0. Booleans read as missing, like the other ports.
    private static func toSafeNumber(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return 0 }
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil } ?? 0
        default:
            return 0
        }
    }

    /// JS truthiness.
    private static func isTruthy(_ value: Any) -> Bool {
        switch value {
        case is NSNull:
            return false
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : number.doubleValue != 0
        case let string as String:
            return !string.isEmpty
        default:
            return true
        }
    }

    /// JS `new Date(obj.timestamp)`: numbers are epoch milliseconds, strings
    /// parse as ISO-8601.
    private static func messageDate(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        case let string as String:
            return VibeSyncTime.parse(string)
        default:
            return nil
        }
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        var result = VibeParseResult()
        let catalog = loadCustomModelCatalog()

        for filePath in Self.findSessionFiles(sessionsDir) {
            let sessionId = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            let slug = URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent
            let project = Self.projectFromSlug(slug)
            var firstMessageTimestamp: Date?

            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                      object["type"] as? String == "message"
                else { continue }
                // JS `if (!obj.timestamp) continue;` — missing/0/"" never count.
                guard let rawTimestamp = object["timestamp"], Self.isTruthy(rawTimestamp),
                      let timestamp = Self.messageDate(rawTimestamp)
                else { continue }

                if firstMessageTimestamp == nil { firstMessageTimestamp = timestamp }
                let role: VibeSessionRole =
                    (object["message"] as? [String: Any])?["role"] as? String == "user" ? .user : .assistant
                result.events.append(VibeSessionEvent(
                    sessionId: sessionId, source: source, project: project,
                    timestamp: timestamp, role: role))
            }

            let settingsPath = (filePath as NSString).deletingLastPathComponent + "/\(sessionId).settings.json"
            guard FileManager.default.fileExists(atPath: settingsPath),
                  let firstMessageTimestamp,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokenUsage = settings["tokenUsage"] as? [String: Any]
            else { continue }

            // Factory already stores uncached prompt in inputTokens; subtracting
            // cacheReadTokens here would zero BYOK input whenever cache > input.
            let cacheReadTokens = Self.toSafeNumber(tokenUsage["cacheReadTokens"])
            let thinkingTokens = Self.toSafeNumber(tokenUsage["thinkingTokens"])
            let cacheCreation5mTokens = Self.toSafeNumber(tokenUsage["cacheCreationTokens"])
            let inputTokens = Self.toSafeNumber(tokenUsage["inputTokens"])
            let outputTokens = max(0, Self.toSafeNumber(tokenUsage["outputTokens"]) - thinkingTokens)
            if inputTokens + outputTokens + cacheReadTokens + thinkingTokens + cacheCreation5mTokens == 0 {
                continue
            }

            result.entries.append(VibeTokenEntry(
                source: source,
                model: Self.resolveModel(settings["model"], catalog: catalog),
                project: project,
                timestamp: firstMessageTimestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cacheReadTokens,
                reasoningOutputTokens: thinkingTokens,
                cacheCreation5mTokens: cacheCreation5mTokens))
        }
        return result
    }
}
