import Foundation

/// P6 (2026-09-05): the engine's own one-line diagnostics — `[lang] locked …`,
/// `[rescue] …`, `[loop-p2] …`, `[prompt] biasing …`, `[warn] …` — used to be
/// parsed as `.other` and dropped. The German-contamination hunt took a day
/// because of that: the first live session already printed `[prompt] biasing 3
/// word(s)` and 39 `[rescue]` lines, and nothing kept them. This folds those
/// lines into counters that ride on the `@final` stability-log line, so the
/// next session explains itself.
struct EngineDiagnostics: Equatable {
    private(set) var rescues: [String: Int] = [:]     // reason → count (logprob / collapse / dropped)
    private(set) var loopTruncated = 0
    private(set) var loopKept = 0
    private(set) var warnings = 0
    private(set) var langLock: (token: Int, margin: Double, probes: Int)? {
        didSet { }   // tuple has no synthesized Equatable; compared through `tag`
    }
    private(set) var langProbes = 0
    private(set) var promptWords: Int? = nil
    private(set) var promptTokens: Int? = nil
    /// Last few raw lines, for the report; bounded.
    private(set) var recent: [String] = []
    static let recentLimit = 12

    static func == (a: EngineDiagnostics, b: EngineDiagnostics) -> Bool { a.tag == b.tag && a.recent == b.recent }

    mutating func ingest(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("[") else { return }
        if line.hasPrefix("[rescue]") {
            if line.contains("segment dropped") { rescues["dropped", default: 0] += 1 }
            else if line.contains("logprob") { rescues["logprob", default: 0] += 1 }
            else if line.contains("collapse") { rescues["collapse", default: 0] += 1 }
            else { rescues["other", default: 0] += 1 }
        } else if line.hasPrefix("[loop-p2]") {
            if line.contains("truncated") { loopTruncated += 1 } else { loopKept += 1 }
        } else if line.hasPrefix("[lang] locked token ") {
            let tok = Int(line.dropFirst("[lang] locked token ".count).prefix(while: \.isNumber)) ?? 0
            langLock = (tok, Self.number(after: "margin ", in: line), Int(Self.number(after: "after ", in: line)))
        } else if line.hasPrefix("[lang] probe ") {
            langProbes += 1
        } else if line.hasPrefix("[prompt] biasing ") {
            promptWords = Int(Self.number(after: "biasing ", in: line))
            promptTokens = Int(Self.number(after: "→ ", in: line))
        } else if line.hasPrefix("[warn]") {
            warnings += 1
        } else {
            return
        }
        recent.append(line)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    /// Compact form for the stability log.
    var tag: String {
        var parts: [String] = []
        if let l = langLock { parts.append(String(format: "lang=%d/%.2f/%d", l.token, l.margin, l.probes)) }
        else { parts.append("lang=unlocked/\(langProbes)") }
        if let w = promptWords { parts.append("prompt=\(w)w/\(promptTokens ?? 0)t") } else { parts.append("prompt=0") }
        let r = rescues.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        parts.append("rescue=" + (r.isEmpty ? "0" : r))
        parts.append("loopp2=\(loopTruncated)/\(loopKept)")
        if warnings > 0 { parts.append("warn=\(warnings)") }
        return "eng " + parts.joined(separator: " ")
    }

    private static func number(after key: String, in line: String) -> Double {
        guard let r = line.range(of: key) else { return 0 }
        let s = line[r.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(s) ?? 0
    }
}
