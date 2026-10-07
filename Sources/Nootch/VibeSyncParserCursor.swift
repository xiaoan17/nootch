import Foundation

struct VibeSyncCursorParser: VibeLogParser {
    let source = "cursor"
    let dbPath: String
    let timeout: TimeInterval
    var loader: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?
    init(dbPath: String? = nil, timeout: TimeInterval? = nil,
         loader: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        let candidates = (environment["CURSOR_CONFIG_DIR"] ?? "").split(separator: ",").map { value in
            let path = String(value).trimmingCharacters(in: .whitespaces)
            return path.hasSuffix(".vscdb") ? path : path + "/User/globalStorage/state.vscdb"
        }
        self.dbPath = dbPath ?? environment["CURSOR_STATE_DB_PATH"] ?? candidates.first(where: VibeParserSupport.exists) ?? home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        let ms = Double(environment["VIBE_USAGE_CURSOR_FETCH_TIMEOUT_MS"] ?? "") ?? 120_000
        self.timeout = timeout ?? (ms > 0 && ms <= 2_147_483_647 && ms.rounded() == ms ? ms / 1000 : 120)
        self.loader = loader
    }
    func parse() async throws -> VibeParseResult {
        guard VibeParserSupport.exists(dbPath) else { return VibeParseResult() }
        let rows = try VibeSQLite.querySnapshotOnLock(databasePath: dbPath, sql: "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", tempPrefix: "nootch-cursor")
        guard let token = rows.first?["value"].jsString?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return VibeParseResult() }
        var cookies: [String] = []
        let parts = token.split(separator: ".")
        if parts.count > 1 {
            var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
            if let data = Data(base64Encoded: b64), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sub = payload["sub"] as? String, !sub.isEmpty {
                cookies.append(sub + "%3A%3A" + token)
                if sub.contains("|"), let user = sub.split(separator: "|").last { cookies.append(String(user) + "%3A%3A" + token) }
            }
        }
        cookies.append(token)
        for attempt in 0...cookies.count {
            var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens")!, timeoutInterval: timeout)
            request.setValue("text/csv,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            if attempt < cookies.count { request.setValue("WorkosCursorSessionToken=" + cookies[attempt], forHTTPHeaderField: "Cookie") }
            else { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            do {
                let data: Data, status: Int
                if let loader { let response = try await loader(request); data = response.0; status = response.1.statusCode }
                else {
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
                    let session = URLSession(configuration: config, delegate: VibeNoRedirectDelegate(), delegateQueue: nil)
                    defer { session.invalidateAndCancel() }
                    let response = try await session.data(for: request)
                    data = response.0; status = (response.1 as? HTTPURLResponse)?.statusCode ?? 0
                }
                if (200..<300).contains(status) { return Self.parseCSV(String(decoding: data, as: UTF8.self)) }
                if status != 401 && status != 403 { return VibeParseResult(skipped: true) }
            } catch { return VibeParseResult(skipped: true) }
        }
        // Deliberately never put a token, response body or request in diagnostics.
        throw VibeSQLiteError(message: "Cursor session rejected; sign in again in Cursor Settings → Account")
    }
    static func parseCSV(_ text: String) -> VibeParseResult {
        typealias P = VibeParserSupport
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        // Swift Character joins CRLF into one grapheme; CSV separators are
        // Unicode scalars, otherwise Windows exports collapse into one row.
        let chars = text.unicodeScalars.map(String.init); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field += c; i += 1 }
                else { quoted.toggle() }
            } else if c == "," && !quoted { row.append(field); field = "" }
            else if c == "\n" && !quoted { row.append(field); rows.append(row); row = []; field = "" }
            else if c != "\r" || quoted { field += c }
            i += 1
        }
        if quoted { return VibeParseResult(skipped: true) }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard let first = rows.first else { return VibeParseResult() }
        let header = first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "") }
        let tokenNames = ["Input (w/ Cache Write)", "Input (w/o Cache Write)", "Cache Read", "Output Tokens"]
        guard header.contains("Date"), header.contains("Model"), tokenNames.contains(where: header.contains) else { return VibeParseResult(skipped: true) }
        var result = VibeParseResult()
        for row in rows.dropFirst() {
            func value(_ key: String) -> String { guard let n = header.firstIndex(of: key), row.indices.contains(n) else { return "" }; return row[n].trimmingCharacters(in: .whitespaces) }
            guard let date = P.date(value("Date")), !value("Model").isEmpty else { continue }
            let counts = tokenNames.map { P.count(value($0).replacingOccurrences(of: ",", with: "")).rounded() }
            guard counts.reduce(0, +) > 0 else { continue }
            var entry = P.entry("cursor", value("Model"), "unknown", date, counts[0] + counts[1], counts[3], counts[2])
            entry.hostname = "cursor-cloud"
            result.entries.append(entry)
        }
        return result
    }
}

// Authenticated exports and localhost RPC never forward credentials on redirects.
final class VibeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
