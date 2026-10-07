import Foundation

/// craft-agent log parser — Swift port of vibe-usage `src/parsers/craft-agent.js`
/// and `src/craft-roots.js`. craft-agent keeps Pi-compatible JSONL transcripts
/// under <workspaces>/<workspace>/sessions/<branch>/.pi-sessions/; the scan
/// itself is VibePiSessionJSONLParser.
///
/// Root (JS getCraftWorkspacesDir): $CRAFT_AGENT_DIR (or $CRAFTAGENT_DIR,
/// default ~/.craft-agent) + "/workspaces". Only files with a `.pi-sessions`
/// path component are sessions; the project is the path segment after the
/// last `sessions` component (the branch name), unless a session header's
/// cwd overrides it.
struct VibeCraftAgentParser: VibeLogParser {
    let source = "craft-agent"
    private let engine: VibePiSessionJSONLParser

    init(workspacesDir: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let dir = workspacesDir ?? Self.workspacesDir(environment: environment)
        engine = VibePiSessionJSONLParser(
            source: source,
            sessionsDirs: [dir],
            includeFile: { path in
                path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains(".pi-sessions")
            },
            projectFromPath: { path, _ in Self.projectFromCraftPath(path) })
    }

    // MARK: - Root discovery (craft-roots.js)

    /// JS getCraftWorkspacesDir. Note the upstream does not expand "~" here.
    static func workspacesDir(environment: [String: String]) -> String {
        let craft = environment["CRAFT_AGENT_DIR"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let craftAlt = environment["CRAFTAGENT_DIR"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let root = !craft.isEmpty ? craft : !craftAlt.isEmpty ? craftAlt : NSHomeDirectory() + "/.craft-agent"
        return root + "/workspaces"
    }

    /// JS projectFromCraftPath: the segment after the last `sessions` path
    /// component; "unknown" when there is none (JS falls back to parts[0],
    /// which is empty for absolute paths).
    static func projectFromCraftPath(_ filePath: String) -> String {
        let parts = filePath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        let value: Substring
        if let sessionsIndex = parts.lastIndex(of: "sessions") {
            let next = parts.index(after: sessionsIndex)
            value = next < parts.endIndex ? parts[next] : ""
        } else {
            value = parts.first ?? ""
        }
        return value.isEmpty ? "unknown" : String(value)
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        try engine.parse()
    }
}
