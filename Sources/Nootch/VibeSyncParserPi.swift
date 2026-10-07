import Foundation

/// Pi coding agent log parser — Swift port of vibe-usage
/// `src/parsers/pi-coding-agent.js` and the root discovery in
/// `src/pi-roots.js`. The session JSONL scan itself (upstream
/// `src/parsers/pi-session-jsonl.js`) lives in VibePiSessionJSONLParser,
/// shared with the omp / craft-agent / cola parsers.
///
/// Roots (JS getPiSessionDirs, without extra roots): VIBE_USAGE_PI_SESSION_DIRS
/// (path-list separator ":"; tests / relocated stores) replaces all discovery;
/// else $PI_CODING_AGENT_DIR/sessions (default ~/.pi/agent/sessions), plus
/// $PI_CODING_AGENT_SESSION_DIR, plus `sessionDir` from
/// <agentDir>/settings.json (absolute or ~-anchored values only). An
/// identifiable OMP store ($PI_CODING_AGENT_DIR containing "/.omp/", or with
/// config.yml / agent.db) is never parsed as pi-coding-agent.
///
/// Documented simplifications vs the JS original:
/// - extraRoots / cindy-ledger are not ported (the app configures no extra
///   roots; same precedent as the Grok parser), so the JS "extra root
///   vanished → skipped" path and its content-probing shape resolution
///   (piSessionsDir) do not apply.
struct VibePiParser: VibeLogParser {
    let source = "pi-coding-agent"
    private let engine: VibePiSessionJSONLParser

    init(sessionsDirs: [String]? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let dirs: [String]
        if let sessionsDirs {
            dirs = VibePiRoots.uniqueExistingDirs(sessionsDirs)
        } else {
            dirs = Self.discoverSessionDirs(environment: environment)
        }
        engine = VibePiSessionJSONLParser(source: source, sessionsDirs: dirs)
    }

    // MARK: - Root discovery (pi-roots.js)

    static func discoverSessionDirs(environment: [String: String]) -> [String] {
        let override = environment["VIBE_USAGE_PI_SESSION_DIRS"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            return VibePiRoots.uniqueExistingDirs(override.split(separator: ":").map(String.init))
        }

        let envAgentDir = environment["PI_CODING_AGENT_DIR"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let agentDir = envAgentDir.isEmpty
            ? NSHomeDirectory() + "/.pi/agent"
            : VibePiRoots.expandHome(envAgentDir)
        // OMP inherits PI_CODING_AGENT_DIR from Pi. Do not parse an
        // identifiable OMP store again as source=pi-coding-agent.
        let isOmpStore = !envAgentDir.isEmpty && VibePiRoots.looksLikeOmpAgentDir(agentDir)

        var dirs: [String] = []
        if !isOmpStore {
            dirs.append(agentDir + "/sessions")
            if let envSessionDir = environment["PI_CODING_AGENT_SESSION_DIR"]?
                .trimmingCharacters(in: .whitespaces), !envSessionDir.isEmpty {
                dirs.append(VibePiRoots.expandHome(envSessionDir))
            }
            if let configured = settingsSessionDir(agentDir) { dirs.append(configured) }
        }
        return VibePiRoots.uniqueExistingDirs(dirs)
    }

    /// Pi resolves a session directory from --session-dir, then
    /// PI_CODING_AGENT_SESSION_DIR, then `sessionDir` in settings.json. Only
    /// the last two are discoverable after the fact, and both name the
    /// sessions directory itself (no `sessions` segment is appended).
    private static func settingsSessionDir(_ agentDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: agentDir + "/settings.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["sessionDir"] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // Pi also accepts project-relative values. Those resolve against a cwd
        // we do not have here, so only absolute and ~-anchored paths are scanned.
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        return VibePiRoots.expandHome(trimmed)
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        try engine.parse()
    }
}
