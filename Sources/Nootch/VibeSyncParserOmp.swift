import Foundation

/// Oh My Pi (OMP) log parser — Swift port of vibe-usage `src/parsers/omp.js`
/// and the OMP branch of `src/pi-roots.js`. OMP writes Pi-compatible JSONL
/// sessions; the scan itself is VibePiSessionJSONLParser.
///
/// Roots (JS getOmpSessionDirs): VIBE_USAGE_OMP_SESSION_DIRS (path-list
/// separator ":") replaces all discovery; else
/// ~/<PI_CONFIG_DIR or ".omp">/agent/sessions plus each
/// profiles/<name>/agent/sessions, plus $PI_CODING_AGENT_DIR/sessions when
/// that override points at an identifiable OMP store (OMP inherits the
/// variable from Pi), plus the XDG migration layout
/// $XDG_DATA_HOME/omp/sessions and profiles/<name>/sessions (the agent/
/// segment is flattened away). Only existing directories are scanned.
struct VibeOmpParser: VibeLogParser {
    let source = "omp"
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

    // MARK: - Root discovery (pi-roots.js getOmpSessionDirs)

    static func discoverSessionDirs(environment: [String: String]) -> [String] {
        let override = environment["VIBE_USAGE_OMP_SESSION_DIRS"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            return VibePiRoots.uniqueExistingDirs(override.split(separator: ":").map(String.init))
        }

        var dirs: [String] = []
        let configName = environment["PI_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let configRoot = NSHomeDirectory() + "/" + (configName.isEmpty ? ".omp" : configName)
        dirs.append(configRoot + "/agent/sessions")
        dirs.append(contentsOf: VibePiRoots.profileSessionDirs(configRoot + "/profiles", includesAgentDir: true))

        let agentOverride = environment["PI_CODING_AGENT_DIR"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !agentOverride.isEmpty {
            let expanded = VibePiRoots.expandHome(agentOverride)
            if VibePiRoots.looksLikeOmpAgentDir(expanded) {
                dirs.append(expanded + "/sessions")
            }
        }

        // OMP's XDG migration flattens the agent/ segment:
        // ~/.omp/agent/sessions -> $XDG_DATA_HOME/omp/sessions. The migration
        // is a Linux/macOS feature; this app only runs on macOS.
        let xdgDataHome = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if !xdgDataHome.isEmpty {
            let xdgRoot = VibePiRoots.expandHome(xdgDataHome) + "/omp"
            dirs.append(xdgRoot + "/sessions")
            dirs.append(contentsOf: VibePiRoots.profileSessionDirs(xdgRoot + "/profiles", includesAgentDir: false))
        }

        return VibePiRoots.uniqueExistingDirs(dirs)
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        try engine.parse()
    }
}
