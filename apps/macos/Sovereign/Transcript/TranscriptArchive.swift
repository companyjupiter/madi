// TranscriptArchive.swift — re-open an archived transcript .md back into the
// view (workspace explorer → click a past meeting). This is the exact inverse
// of Exporters.markdown: it parses the bullet lines
//
//     - **[mm:ss] Who** body words *low-confidence* ⟨+Name 겹침⟩
//
// and rebuilds [Line] + the speaker-name map. Header, the on-device summary
// block, and the italics legend are skipped (only bullet lines parse). The
// *italic* low-confidence marks are round-tripped back to sub-threshold conf so
// the detailed view still flags them.
//
// Fidelity note: per-word timing/confidence isn't recoverable from Markdown, so
// each word inherits the line's start time and italic→low / plain→1.0 conf.
// That's enough for a static re-read; it is not a live capture.

import Foundation

enum TranscriptArchive {

    struct Parsed { let lines: [Line]; let names: [Int: String] }

    /// Parse a transcript .md produced by Exporters.markdown. Returns nil if the
    /// file can't be read or contains no recognizable transcript lines.
    static func parse(_ url: URL) -> Parsed? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text: text)
    }

    /// `- **[mm:ss] who** body` — who is captured non-greedily so the first `**`
    /// closes the bold; the rest is the body (+ overlap markers).
    private static let bullet = try! NSRegularExpression(
        pattern: #"^- \*\*\[(\d{1,2}):(\d{2})\] (.+?)\*\* ?(.*)$"#)
    private static let overlapMark = try! NSRegularExpression(pattern: #"\s*⟨\+[^⟩]*⟩"#)
    private static let speakerN = try! NSRegularExpression(pattern: #"^Speaker (\d+)$"#)
    private static let translation = try! NSRegularExpression(
        pattern: #"^  - \[번역:([^\]]+)\] ?(.*)$"#)

    static func parse(text: String) -> Parsed? {
        let rows = text.components(separatedBy: .newlines)

        // Pass 1 — reserve explicit "Speaker N" ids so named speakers get
        // non-colliding ids allocated above the highest reserved number.
        var maxReserved = -1
        var whoOrder: [String] = []        // first-encounter order of who tokens
        var seenWho = Set<String>()
        struct Raw { let start: Double; let who: String; let body: String; var translations: [String: String] }
        var raws: [Raw] = []

        for row in rows {
            let r = NSRange(row.startIndex..<row.endIndex, in: row)
            if let tm = translation.firstMatch(in: row, range: r), !raws.isEmpty,
               let lr = Range(tm.range(at: 1), in: row), let tr = Range(tm.range(at: 2), in: row) {
                raws[raws.count - 1].translations[String(row[lr])] = String(row[tr])
                continue
            }
            guard let m = bullet.firstMatch(in: row, range: r) else { continue }
            func grp(_ i: Int) -> String {
                guard let rr = Range(m.range(at: i), in: row) else { return "" }
                return String(row[rr])
            }
            let mm = Double(grp(1)) ?? 0, ss = Double(grp(2)) ?? 0
            let who = grp(3).trimmingCharacters(in: .whitespaces)
            let body = grp(4)
            raws.append(Raw(start: mm * 60 + ss, who: who, body: body, translations: [:]))
            if seenWho.insert(who).inserted { whoOrder.append(who) }
            if let sm = speakerN.firstMatch(in: who, range: NSRange(who.startIndex..<who.endIndex, in: who)),
               let nr = Range(sm.range(at: 1), in: who), let n = Int(who[nr]) {
                maxReserved = max(maxReserved, n)
            }
        }
        guard !raws.isEmpty else { return nil }

        // who → speaker id. "Speaker N" → N; named → allocate above maxReserved.
        var idForWho: [String: Int] = [:]
        var names: [Int: String] = [:]
        var nextNamed = maxReserved + 1
        for who in whoOrder {
            let r = NSRange(who.startIndex..<who.endIndex, in: who)
            if who == SpeakerID.unknownLabel {
                // Round-trip the Unknown bucket back to its reserved id — do NOT
                // allocate it a named-speaker id or put it in `names` (it must
                // render via the shared helper, stay un-nameable/un-enrollable).
                idForWho[who] = SpeakerID.unknown
            } else if let sm = speakerN.firstMatch(in: who, range: r),
               let nr = Range(sm.range(at: 1), in: who), let n = Int(who[nr]) {
                idForWho[who] = n
            } else {
                let id = nextNamed; nextNamed += 1
                idForWho[who] = id
                names[id] = who
            }
        }

        // Build lines; line end = next line's start (last line gets a 0 span).
        var lines: [Line] = []
        for (i, raw) in raws.enumerated() {
            let end = (i + 1 < raws.count) ? max(raw.start, raws[i + 1].start) : raw.start
            let words = parseWords(raw.body, at: raw.start)
            let id = words.first?.id ?? UUID()
            lines.append(Line(id: id, speaker: idForWho[raw.who] ?? 0,
                              start: raw.start, end: end, words: words,
                              translations: raw.translations,
                              editedTranslations: Set(raw.translations.keys)))
        }
        return Parsed(lines: lines, names: names)
    }

    /// Strip overlap markers, then split the body into words. A `*token*` (single
    /// asterisks, the italic low-confidence mark) → sub-threshold conf so the
    /// detailed view re-flags it; everything else → conf 1.0.
    private static func parseWords(_ body: String, at t: Double) -> [Word] {
        let stripped = overlapMark.stringByReplacingMatches(
            in: body, range: NSRange(body.startIndex..<body.endIndex, in: body), withTemplate: "")
        var out: [Word] = []
        for tok in stripped.split(separator: " ", omittingEmptySubsequences: true) {
            // Any italic asterisk on the token marks it low-confidence; strip all
            // `*` so even a malformed wrap (`*반갑*습니다`) never leaks markup.
            let lowConf = tok.contains("*")
            let s = tok.replacingOccurrences(of: "*", with: "")
            if s.isEmpty { continue }
            out.append(Word(t0: t, t1: t, text: s, conf: lowConf ? 0.3 : 1.0))
        }
        return out
    }
}
