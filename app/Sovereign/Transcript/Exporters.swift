// Exporters.swift — render a finalized transcript to Markdown / SRT.
// Markdown carries the interruption markers; matches the runner's saved-.md style.

import Foundation

enum Exporters {
    /// Markdown: low-confidence words become *italic* (markdown has no color) so
    /// the SAVED doc still flags exactly the words to double-check — the export
    /// keeps the live view's confidence signal instead of dropping it.
    static func markdown(_ lines: [Line], names: [Int: String] = [:]) -> String {
        var s = "# Transcript\n\n"
        s += "> *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.\n\n"
        for l in lines {
            let who = names[l.speaker] ?? "Speaker \(l.speaker)"
            let body = renderWords(l.words)
            let mark = l.overlapSpeakers
                .map { " ⟨+\(names[$0] ?? "Speaker \($0)") 겹침⟩" }
                .joined()
            s += "- **[\(timecode(l.start))] \(who)** \(body)\(mark)\n"
        }
        return s
    }

    /// Join words; wrap below-threshold ones in markdown italics.
    private static func renderWords(_ words: [Word]) -> String {
        var s = ""
        for (i, w) in words.enumerated() {
            if i > 0, w.text.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            let t = w.text.trimmingCharacters(in: .whitespaces)
            s += (w.conf < Theme.confThreshold && !t.isEmpty) ? "*\(t)*" : w.text
        }
        return s
    }

    static func srt(_ lines: [Line], names: [Int: String] = [:]) -> String {
        var s = ""
        for (i, l) in lines.enumerated() {
            let who = names[l.speaker] ?? "Speaker \(l.speaker)"
            s += "\(i + 1)\n"
            s += "\(srtTime(l.start)) --> \(srtTime(max(l.end, l.start + 1.2)))\n"
            s += "\(who): \(l.text)\n\n"
        }
        return s
    }

    private static func timecode(_ t: Double) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func srtTime(_ t: Double) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        let ms = Int((t - t.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
