// Exporters.swift — render a finalized transcript to Markdown / SRT.
// Markdown carries the interruption markers; matches the runner's saved-.md style.

import Foundation

enum Exporters {
    static func markdown(_ lines: [Line], names: [Int: String] = [:]) -> String {
        var s = "# Transcript\n\n"
        for l in lines {
            let who = names[l.speaker] ?? "Speaker \(l.speaker)"
            let mark = l.overlapSpeakers
                .map { " ⟨+\(names[$0] ?? "Speaker \($0)") 겹침⟩" }
                .joined()
            s += "- **[\(timecode(l.start))] \(who)** \(l.text)\(mark)\n"
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
