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

    /// Plain text: `[mm:ss] Speaker: text` per line — clean for pasting into
    /// docs/email, no markup.
    static func plainText(_ lines: [Line], names: [Int: String] = [:]) -> String {
        var s = ""
        for l in lines {
            let who = names[l.speaker] ?? "Speaker \(l.speaker)"
            s += "[\(timecode(l.start))] \(who): \(l.text)\n"
        }
        return s
    }

    /// Structured JSON: per-segment speaker/time/text/per-word conf + a speaker
    /// talk-time summary. For programmatic post-processing (the structured
    /// counterpart to the stdout event stream).
    static func json(_ lines: [Line], names: [Int: String] = [:]) -> String {
        let segs: [[String: Any]] = lines.map { l in
            [
                "speaker": l.speaker,
                "name": names[l.speaker] ?? "Speaker \(l.speaker)",
                "start": l.start, "end": l.end,
                "text": l.text,
                "overlap_speakers": l.overlapSpeakers,
                "words": l.words.map { ["text": $0.text, "t0": $0.t0, "t1": $0.t1, "conf": $0.conf] as [String: Any] },
            ]
        }
        var times: [Int: Double] = [:]
        for l in lines { times[l.speaker, default: 0] += max(0, l.end - l.start) }
        let speakers: [[String: Any]] = times.sorted { $0.value > $1.value }.map {
            ["speaker": $0.key, "name": names[$0.key] ?? "Speaker \($0.key)", "talk_seconds": $0.value]
        }
        let root: [String: Any] = ["segments": segs, "speakers": speakers]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
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
