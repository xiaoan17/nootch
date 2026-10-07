import Foundation

// Small shared primitives for the remaining upstream ports. Keep payload bodies
// local; only accounting fields and timing ever become VibeTokenEntry/Event.
enum VibeParserSupport {
    typealias Object = [String: Any]
    static func object(_ value: Any?) -> Object { value as? Object ?? [:] }
    static func objects(_ value: Any?) -> [Object] { value as? [Object] ?? [] }
    static func string(_ value: Any?, _ fallback: String = "") -> String {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return fallback
    }
    static func count(_ value: Any?) -> Double {
        let n = (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0
        return n.isFinite && n > 0 ? n : 0
    }
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber, n.doubleValue.isFinite {
            return Date(timeIntervalSince1970: n.doubleValue / 1000)
        }
        guard let s = value as? String else { return nil }
        if let d = VibeSyncTime.parse(s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        if s.count == 10 { return f.date(from: s + "T00:00:00Z") }
        return nil
    }
    static func project(_ value: Any?) -> String {
        let s = string(value).replacingOccurrences(of: "\\", with: "/")
        return s.split(separator: "/").last.map(String.init) ?? "unknown"
    }
    static func json(_ path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    static func jsonText(_ value: Any?) -> Object {
        guard let s = value as? String, let data = s.data(using: .utf8) else { return [:] }
        return object(try? JSONSerialization.jsonObject(with: data))
    }
    static func lines(_ path: String) throws -> [Object] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.split(separator: "\n").compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? Object
        }
    }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    static func children(_ path: String) throws -> [String] {
        if !exists(path) { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted().map { path + "/" + $0 }
    }
    static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }
    static func files(_ root: String, matching: (String) -> Bool) throws -> [String] {
        var result: [String] = [], seen = Set<String>()
        func visit(_ path: String) throws {
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(canonical).inserted else { return }
            for child in try children(path) {
                if isDirectory(child) { try visit(child) }
                else if matching((child as NSString).lastPathComponent) { result.append(child) }
            }
        }
        try visit(root)
        return result
    }
    static func entry(_ source: String, _ model: String, _ project: String, _ date: Date,
                      _ input: Double, _ output: Double, _ cache: Double = 0, _ reasoning: Double = 0) -> VibeTokenEntry {
        VibeTokenEntry(source: source, model: model, project: project, timestamp: date,
                       inputTokens: input, outputTokens: output, cachedInputTokens: cache, reasoningOutputTokens: reasoning)
    }
    static let hosts = ["Code", "Cursor", "Windsurf", "VSCodium", "Code - Insiders", "Trae", "Trae CN"]
}
