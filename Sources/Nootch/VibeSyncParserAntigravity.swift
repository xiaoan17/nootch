import Foundation

// Bounded protobuf reader: malformed lengths/varints throw instead of producing
// plausible zero usage. Only the upstream's allow-listed accounting fields survive.
struct VibeProto {
    enum Value { case number(UInt64), bytes(Data) }
    var fields: [Int: [Value]] = [:]
    init(_ data: Data) throws {
        let bytes = [UInt8](data); var pos = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard pos < bytes.count else { throw VibeSQLiteError(message: "Truncated protobuf varint") }
                let byte = bytes[pos]; pos += 1
                guard shift < 63 || byte <= 1 else { throw VibeSQLiteError(message: "Protobuf integer overflow") }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw VibeSQLiteError(message: "Invalid protobuf varint")
        }
        while pos < bytes.count {
            let tag = try varint(), number = Int(tag >> 3)
            guard number > 0 else { throw VibeSQLiteError(message: "Invalid protobuf field") }
            let value: Value
            switch tag & 7 {
            case 0: value = .number(try varint())
            case 1, 2, 5:
                let length = tag & 7 == 2 ? try varint() : (tag & 7 == 1 ? 8 : 4)
                guard length <= UInt64(bytes.count - pos) else { throw VibeSQLiteError(message: "Truncated protobuf field") }
                value = .bytes(Data(bytes[pos..<(pos + Int(length))])); pos += Int(length)
            default: throw VibeSQLiteError(message: "Unsupported protobuf wire type")
            }
            fields[number, default: []].append(value)
        }
    }
    func number(_ field: Int) -> Double { for value in fields[field] ?? [] { if case .number(let n) = value { return Double(n) } }; return 0 }
    func bytes(_ field: Int) -> Data? { for value in fields[field] ?? [] { if case .bytes(let d) = value { return d } }; return nil }
    func string(_ field: Int) -> String { bytes(field).map { String(decoding: $0, as: UTF8.self) } ?? "" }
    func message(_ field: Int) throws -> VibeProto? { try bytes(field).map(VibeProto.init) }
    static func hex(_ string: String) throws -> VibeProto {
        guard string.count % 2 == 0 else { throw VibeSQLiteError(message: "Invalid protobuf hex") }
        var bytes = Data(); var i = string.startIndex
        while i < string.endIndex { let end = string.index(i, offsetBy: 2); guard let b = UInt8(string[i..<end], radix: 16) else { throw VibeSQLiteError(message: "Invalid protobuf hex") }; bytes.append(b); i = end }
        return try VibeProto(bytes)
    }
}

struct VibeSyncAntigravityParser: VibeLogParser {
    let source = "antigravity"
    let directories: [String]
    var rpc: (@Sendable (String) async throws -> Data)?
    init(directories: [String]? = nil, rpc: (@Sendable (String) async throws -> Data)? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        self.directories = directories ?? environment["VIBE_USAGE_ANTIGRAVITY_DIRS"]?.split(separator: ":").map(String.init) ?? ["antigravity", "antigravity-cli", "antigravity-ide"].map { home + "/.gemini/" + $0 + "/conversations" }
        self.rpc = rpc
    }
    typealias P = VibeParserSupport
    static func model(_ raw: String) -> String {
        let map = ["claude-opus-4-6-thinking": "claude-opus-4-6", "claude-sonnet-4-6-thinking": "claude-sonnet-4-6", "gemini-3.1-pro-high": "gemini-3.1-pro", "gemini-3.1-pro-low": "gemini-3.1-pro", "gemini-3-pro-high": "gemini-3-pro", "gemini-3-pro-low": "gemini-3-pro", "MODEL_PLACEHOLDER_M37": "gemini-3.1-pro", "MODEL_PLACEHOLDER_M36": "gemini-3.1-pro", "MODEL_PLACEHOLDER_M47": "gemini-3-flash", "MODEL_PLACEHOLDER_M35": "claude-sonnet-4-6", "MODEL_PLACEHOLDER_M26": "claude-opus-4-6", "MODEL_OPENAI_GPT_OSS_120B_MEDIUM": "gpt-oss-120b"]
        return map[raw] ?? (raw.isEmpty ? "unknown" : raw)
    }
    static func timestamp(_ proto: VibeProto?) -> Date? { guard let proto, proto.number(1) > 0 else { return nil }; return Date(timeIntervalSince1970: proto.number(1)) }
    func parse() async throws -> VibeParseResult {
        var result = VibeParseResult(), databases: [String: String] = [:], legacy = Set<String>(), responseIDs = Set<String>()
        for dir in directories {
            for file in try P.children(dir) {
                let name = (file as NSString).lastPathComponent
                if name.hasSuffix(".pb") { legacy.insert(String(name.dropLast(3))) }
                if name.hasSuffix(".db") && name != "db.sqlite" {
                    let id = String(name.dropLast(3))
                    let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.intValue ?? 0
                    if let old = databases[id], ((try? FileManager.default.attributesOfItem(atPath: old)[.size] as? NSNumber)?.intValue ?? 0) >= size { continue }
                    databases[id] = file
                }
            }
        }
        for id in databases.keys.sorted() {
            let path = databases[id]!
            do {
                func query(_ sql: String) throws -> [VibeSQLiteRow] { try VibeSQLite.querySnapshotOnLock(databasePath: path, sql: sql, tempPrefix: "nootch-antigravity") }
                var project = "unknown"
                if let row = try? query("SELECT hex(data) AS h FROM trajectory_metadata_blob LIMIT 1").first,
                   let hex = row["h"].jsString, let proto = try? VibeProto.hex(hex), let ws = try? proto.message(1) { project = P.project(ws.string(1)) }
                let steps = try query("SELECT idx, hex(metadata) AS h FROM steps WHERE metadata IS NOT NULL ORDER BY idx")
                var times: [String: Date] = [:]
                for row in steps {
                    let proto = try VibeProto.hex(row["h"].jsString ?? "")
                    guard let date = Self.timestamp(try proto.message(1)) else { continue }
                    times[row["idx"].jsString ?? ""] = date
                    let role: VibeSessionRole? = proto.number(3) == 4 ? .user : (proto.number(3) == 2 ? .assistant : nil)
                    if let role { result.events.append(VibeSessionEvent(sessionId: id, source: source, project: project, timestamp: date, role: role)) }
                }
                for row in try query("SELECT idx, hex(data) AS h FROM gen_metadata ORDER BY idx") {
                    let proto = try VibeProto.hex(row["h"].jsString ?? "")
                    guard let chat = try proto.message(1), let usage = try chat.message(4) else { continue }
                    let counts = [2, 3, 5, 9].map { usage.number($0) }
                    guard counts.reduce(0, +) > 0 else { continue }
                    let date = Self.timestamp(try chat.message(9)?.message(4)) ?? times[row["idx"].jsString ?? ""]
                    guard let date else { result.skipped = true; continue }
                    let response = usage.string(11)
                    if !response.isEmpty && !responseIDs.insert(response).inserted { continue }
                    let display = chat.string(21)
                    result.entries.append(P.entry(source, display.isEmpty ? Self.model(chat.string(19)) : display, project, date, counts[0], counts[1], counts[2], counts[3]))
                }
                legacy.remove(id)
            } catch { result.skipped = true; legacy.remove(id) }
        }
        if legacy.isEmpty { return result }
        let servers = rpc == nil ? await Self.servers() : []
        for id in legacy.sorted() {
            var payload: Data?
            if let rpc { payload = try? await rpc(id) }
            else {
                for server in servers {
                    if let data = try? await Self.request(port: server.0, token: server.1, method: "GetCascadeTrajectory", body: ["cascadeId": id]),
                       let json = try? JSONSerialization.jsonObject(with: data) as? P.Object, json["trajectory"] != nil { payload = data; break }
                }
            }
            guard let payload, let root = try? JSONSerialization.jsonObject(with: payload) as? P.Object,
                  let trajectory = root["trajectory"] as? P.Object else { result.skipped = true; continue }
            let ws = P.objects(P.object(trajectory["metadata"])["workspaces"]).first ?? [:]
            let project = P.string(P.object(ws["repository"])["computedName"], P.project(ws["workspaceFolderAbsoluteUri"]))
            for metadata in P.objects(trajectory["generatorMetadata"]) {
                let chat = P.object(metadata["chatModel"])
                guard let date = P.date(P.object(chat["chatStartMetadata"])["createdAt"]) else { continue }
                let model = P.string(chat["modelDisplayName"], Self.model(P.string(chat["responseModel"], P.string(chat["model"]))))
                for retry in P.objects(chat["retryInfos"]) {
                    let usage = P.object(retry["usage"]), response = P.string(P.object(retry["usage"])["responseId"])
                    if !response.isEmpty && !responseIDs.insert(response).inserted { continue }
                    result.entries.append(P.entry(source, model, project, date, P.count(usage["inputTokens"]), P.count(usage["outputTokens"]), P.count(usage["cacheReadTokens"]), P.count(usage["thinkingOutputTokens"])))
                }
            }
            for step in P.objects(trajectory["steps"]) {
                let meta = P.object(step["metadata"]), stepSource = P.string(P.object(step["metadata"])["source"])
                let role: VibeSessionRole? = ["CORTEX_STEP_SOURCE_USER_EXPLICIT", "CORTEX_STEP_SOURCE_USER_IMPLICIT"].contains(stepSource) ? .user : (stepSource == "CORTEX_STEP_SOURCE_MODEL" ? .assistant : nil)
                if let role, let date = P.date(meta["createdAt"]) { result.events.append(VibeSessionEvent(sessionId: id, source: source, project: project, timestamp: date, role: role)) }
            }
        }
        return result
    }
    static func request(port: Int, token: String, method: String, body: [String: String], timeout: Double = 10) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)")!, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: VibeNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VibeSQLiteError(message: "Antigravity local RPC unavailable") }
        return data
    }
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        // Drain concurrently with a time limit, so an unexpected process list
        // cannot deadlock a full pipe or stall the sync indefinitely.
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); deadline.cancel()
        return String(decoding: data, as: UTF8.self)
    }
    static func servers() async -> [(Int, String)] {
        guard let processes = try? command("/bin/ps", ["-axo", "pid=,command="]) else { return [] }
        let csrf = try? NSRegularExpression(pattern: #"--csrf_token\s+([0-9a-f-]+)"#)
        let portsRegex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#)
        var result: [(Int, String)] = []
        for line in processes.split(separator: "\n") where line.lowercased().contains("antigravity") && line.contains("language_server") {
            let string = String(line), ns = String(line) as NSString
            guard let match = csrf?.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)), let pid = line.split(whereSeparator: \.isWhitespace).first, Int(pid) != nil else { continue }
            let token = ns.substring(with: match.range(at: 1))
            guard let ports = try? command("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-nP", "-a", "-p", String(pid)]) else { continue }
            let text = ports as NSString
            for match in portsRegex?.matches(in: ports, range: NSRange(location: 0, length: text.length)) ?? [] {
                guard let port = Int(text.substring(with: match.range(at: 1))), (1...65535).contains(port) else { continue }
                if (try? await request(port: port, token: token, method: "GetWorkspaceInfos", body: [:], timeout: 3)) != nil { result.append((port, token)); break }
            }
        }
        return result
    }
}
