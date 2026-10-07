import Foundation

/// cola log parser — Swift port of vibe-usage `src/parsers/cola.js` and
/// `src/cola-roots.js`. Cola 1.4.4 writes Pi-compatible transcripts under
/// sessions/<scope>/; the scan itself is VibePiSessionJSONLParser with
/// copied-session dedup enabled.
///
/// Root (JS getColaSessionsDir): $COLA_DATA_DIR (default ~/.cola)
/// + "/sessions". Scope slugs may identify channels or people, not projects,
/// so the project comes from the session header's cwd or stays "unknown".
/// Cola copies a transcript with a new session header but unchanged records;
/// copied-session dedup counts each record once and attributes it to the
/// earliest copy. A skipped (partially unreadable) run reports no entries or
/// events at all: a missing part of the store must not overwrite a complete
/// uploaded bucket with a partial sum.
struct VibeColaParser: VibeLogParser {
    let source = "cola"
    private let engine: VibePiSessionJSONLParser

    init(sessionsDir: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let dir = sessionsDir ?? Self.sessionsDir(environment: environment)
        engine = VibePiSessionJSONLParser(
            source: source,
            sessionsDirs: [dir],
            projectFromPath: { _, _ in "unknown" },
            deduplicateCopiedSessions: true,
            clearsResultsWhenSkipped: true)
    }

    // MARK: - Root discovery (cola-roots.js)

    /// JS getColaSessionsDir: `??` semantics — only an unset COLA_DATA_DIR
    /// falls back to ~/.cola; an explicitly empty value yields "/sessions".
    static func sessionsDir(environment: [String: String]) -> String {
        let root = environment["COLA_DATA_DIR"] ?? (NSHomeDirectory() + "/.cola")
        return root + "/sessions"
    }

    // MARK: - VibeLogParser

    func parse() throws -> VibeParseResult {
        try engine.parse()
    }
}
