import Foundation
import Darwin

struct VibeSyncDshParser: VibeLogParser {
    let source = "dsh"
    let sessionsDir: String
    init(sessionsDir: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        self.sessionsDir = sessionsDir ?? environment["VIBE_USAGE_DSH_SESSIONS"] ?? (environment["DSH_HOME"] ?? home + "/.dsh") + "/sessions"
    }
    struct Message {
        var seq: Int?; var id: String; var role: VibeSessionRole; var date: Date
        var model: String; var usage: [Double]
    }
    struct Session {
        var id: String; var parent: String; var project: String; var version: Int
        var seed: Int; var messages: [Message]; var weight: Int
    }
    static func decode(_ text: String, version: Int) throws -> Session {
        typealias P = VibeParserSupport
        let records = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? P.Object }
        guard let header = records.first(where: { P.string($0["type"]) == "session" }), let v = header["version"] as? Int,
              v == version, (0...4).contains(v), !P.string(header["id"]).isEmpty,
              v < 2 || header["isSeeded"] is Bool else { throw VibeSQLiteError(message: "Unsupported dsh session format") }
        var messages: [Message] = [], inherited: Int?
        for record in records {
            guard let date = P.date(record["time"]) else { continue }
            let data = P.object(record["data"]), type = P.string(record["type"])
            let seq = record["seq"] as? Int
            if v >= 2 && type == "session/end-seed" && data["inherited"] as? Bool == true {
                guard let seq, seq >= 0 else { throw VibeSQLiteError(message: "Invalid dsh seed marker") }; inherited = seq
            }
            if type == "user/message" && P.string(P.object(data["source"])["kind"]) == "user" {
                messages.append(Message(seq: seq, id: P.string(data["id"]), role: .user, date: date, model: "", usage: []))
            } else if type == "assistant/message" {
                let usage = P.object(data["usage"]), message = P.object(data["message"])
                let input = P.count(usage["inputTokens"]) + P.count(usage["cacheWriteTokens"])
                let output = P.count(usage["outputTokens"]), reasoning = min(output, P.count(usage["reasoningTokens"]))
                let counts = [input, output - reasoning, P.count(usage["cacheReadTokens"]), reasoning]
                messages.append(Message(seq: seq, id: P.string(message["id"]), role: .assistant, date: date,
                                        model: P.string(P.object(message["source"])["model"], "unknown"), usage: counts.reduce(0, +) > 0 ? counts : []))
            }
        }
        if v >= 2 && (header["isSeeded"] as? Bool) != (inherited != nil) { throw VibeSQLiteError(message: "Inconsistent dsh seed boundary") }
        return Session(id: P.string(header["id"]), parent: P.string(header["parentSession"]), project: P.project(header["cwd"]), version: v,
                       seed: v >= 2 ? inherited ?? 0 : max(0, header["seedLength"] as? Int ?? 0), messages: messages, weight: text.utf8.count)
    }
    static func replayCount(_ child: Session, _ parent: Session) -> Int {
        guard child.seed > 0 else { return 0 }
        var index = 0, previous = -1, count = 0
        for message in child.messages {
            guard let seq = message.seq, seq > previous else { return 0 }; previous = seq
            if seq >= child.seed { break }
            let mixed = child.version != parent.version
            if mixed && message.id.isEmpty { return 0 }
            while index < parent.messages.count {
                let source = parent.messages[index]
                if mixed ? source.id != message.id : (source.seq != nil && source.seq! < seq) { index += 1 } else { break }
            }
            guard index < parent.messages.count else { return 0 }
            let source = parent.messages[index]
            guard (mixed || source.seq == seq), source.role == message.role, source.model == message.model, source.usage == message.usage else { return 0 }
            index += 1; count += 1
        }
        return count
    }
    func parse() throws -> VibeParseResult {
        typealias P = VibeParserSupport
        var sessions: [String: Session] = [:], result = VibeParseResult()
        let regex = try NSRegularExpression(pattern: #"^session(?:\.v([1-9][0-9]*))?\.jsonl(\.zstd)?$"#)
        for project in try P.children(sessionsDir) where P.isDirectory(project) {
            for dir in try P.children(project) where P.isDirectory(dir) {
                do {
                    var candidates: [(Int, Bool, String)] = []
                    for file in try P.children(dir) {
                        let name = (file as NSString).lastPathComponent, ns = ((file as NSString).lastPathComponent as NSString)
                        guard let match = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { continue }
                        let version = match.range(at: 1).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: 1))) ?? Int.max
                        candidates.append((version, file.hasSuffix(".zstd"), file))
                    }
                    guard let chosen = candidates.sorted(by: { $0.0 == $1.0 ? (!$0.1 && $1.1) : $0.0 < $1.0 }).last else { continue }
                    guard chosen.0 <= 4 else { throw VibeSQLiteError(message: "Newer dsh format present") }
                    let attrs = try FileManager.default.attributesOfItem(atPath: chosen.2)
                    guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 256 * 1024 * 1024 else { throw VibeSQLiteError(message: "dsh file too large") }
                    let data = try Data(contentsOf: URL(fileURLWithPath: chosen.2))
                    let bytes = chosen.1 ? try VibeZstd.decompress(data) : data
                    let session = try Self.decode(String(decoding: bytes, as: UTF8.self), version: chosen.0)
                    if let old = sessions[session.id], old.version > session.version || (old.version == session.version && old.weight >= session.weight) { continue }
                    sessions[session.id] = session
                } catch { result.skipped = true }
            }
        }
        for id in sessions.keys.sorted() {
            let session = sessions[id]!, skip = sessions[sessions[id]!.parent].map { Self.replayCount(session, $0) } ?? 0
            var events: [VibeSessionEvent] = []
            for message in session.messages.dropFirst(skip) {
                events.append(VibeSessionEvent(sessionId: id, source: source, project: session.project, timestamp: message.date, role: message.role))
                if message.usage.count == 4 { result.entries.append(P.entry(source, message.model, session.project, message.date, message.usage[0], message.usage[1], message.usage[2], message.usage[3])) }
            }
            if events.contains(where: { $0.role == .user }) { result.events += events }
        }
        return result
    }
}

// Bundled libzstd gives standalone apps the same multi-frame support as upstream,
// without requiring Node, Homebrew, a subprocess or private macOS APIs.
enum VibeZstd {
    static func frames(_ data: Data) throws -> [Data] {
        let b = [UInt8](data); var pos = 0, result: [Data] = []
        func uint(_ offset: Int, _ bytes: Int) -> Int { (0..<bytes).reduce(0) { $0 | Int(b[offset + $1]) << ($1 * 8) } }
        while pos + 4 <= b.count {
            let magic = uint(pos, 4)
            if (0x184d2a50...0x184d2a5f).contains(magic) {
                guard pos + 8 <= b.count else { break }; let end = pos + 8 + uint(pos + 4, 4)
                guard end <= b.count else { break }; pos = end; continue
            }
            guard magic == 0xfd2fb528 else { throw VibeSQLiteError(message: "Invalid zstd frame") }
            let start = pos; pos += 4
            guard pos < b.count else { break }
            let d = Int(b[pos]); pos += 1
            guard d & 0x18 == 0 else { throw VibeSQLiteError(message: "Reserved zstd header") }
            let single = d & 0x20 != 0, sizeFlag = d >> 6, dictFlag = d & 3
            pos += (single ? 0 : 1) + (dictFlag == 3 ? 4 : dictFlag) + (sizeFlag == 0 ? (single ? 1 : 0) : 1 << sizeFlag)
            guard pos <= b.count else { break }
            while true {
                guard pos + 3 <= b.count else { return result }
                let block = uint(pos, 3); pos += 3; let type = (block >> 1) & 3
                guard type != 3 else { throw VibeSQLiteError(message: "Reserved zstd block") }
                pos += type == 1 ? 1 : block >> 3
                guard pos <= b.count else { return result }
                if block & 1 != 0 { break }
            }
            if d & 4 != 0 { pos += 4 }
            guard pos <= b.count else { break }
            result.append(Data(b[start..<pos]))
        }
        return result
    }
    static func decompress(_ data: Data) throws -> Data {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libzstd.1.dylib").path,
                          "/opt/homebrew/lib/libzstd.1.dylib", "/usr/local/lib/libzstd.1.dylib"]
        guard let handle = candidates.lazy.compactMap({ dlopen($0, RTLD_NOW | RTLD_LOCAL) }).first else { throw VibeSQLiteError(message: "zstd library unavailable") }
        defer { dlclose(handle) }
        typealias Bound = @convention(c) (UnsafeRawPointer?, Int) -> UInt64
        typealias Decode = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
        typealias IsError = @convention(c) (Int) -> UInt32
        guard let a = dlsym(handle, "ZSTD_decompressBound"), let b = dlsym(handle, "ZSTD_decompress"), let c = dlsym(handle, "ZSTD_isError") else { throw VibeSQLiteError(message: "Invalid zstd library") }
        let bound = unsafeBitCast(a, to: Bound.self), decode = unsafeBitCast(b, to: Decode.self), isError = unsafeBitCast(c, to: IsError.self)
        let frames = try frames(data)
        guard !frames.isEmpty else { throw VibeSQLiteError(message: "No complete zstd frame") }
        var result = Data()
        for frame in frames {
            let capacity = frame.withUnsafeBytes { bound($0.baseAddress, frame.count) }
            guard capacity <= UInt64(512 * 1024 * 1024 - result.count) else { throw VibeSQLiteError(message: "zstd output exceeds limit") }
            var output = Data(count: max(1, Int(capacity)))
            let size = output.count
            let actual = output.withUnsafeMutableBytes { out in frame.withUnsafeBytes { decode(out.baseAddress, size, $0.baseAddress, frame.count) } }
            guard isError(actual) == 0, actual <= output.count else { throw VibeSQLiteError(message: "zstd decompression failed") }
            result.append(output.prefix(actual))
        }
        return result
    }
}
