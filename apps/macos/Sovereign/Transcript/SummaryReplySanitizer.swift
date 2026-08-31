// SummaryReplySanitizer.swift — post-processes raw summary-engine replies before
// they reach the app (SummaryEngine final/fold results). Foundation-only →
// SovereignCore + XCTest.
//
// Guards three SMALL-MODEL pathologies, all reproduced on the shipped DNA3.0-2B
// during the 2026-08-31 template probe (docs/SUMMARY_TEMPLATES.md §7); the same
// class of runaway hit live STT partials before (tokenCollapse, PR#185):
//   1. Stray "</think>" leakage — the engine prefills <think>\n\n</think> to
//      disable thinking, but the 2B sometimes re-emits "</think>" mid-reply and
//      RESTATES the whole answer (2/9 probe replies) → duplicated sections in
//      every parser downstream. Fix: keep the segment after the last </think>
//      that still carries the head marker, else the longest segment.
//   2. Alternating-line repetition loops — [후속] degenerated into the same
//      Q/A line pair repeated ~20× until the token budget cut it. Fix: drop
//      exact-duplicate non-empty lines (order-preserving; a real summary never
//      repeats a byte-identical line), and collapse blank runs to one.
//   3. Hallucinated section tails — [용어] grew to 65 terms (14 grounded), the
//      model padding past the source once real material ran out; in-prompt
//      count limits are ignored. Fix: per-section bullet cap from the
//      SummarySection registry (first bullets are the grounded ones).
//
// A healthy reply (today's meeting output on the 4B) passes through unchanged —
// golden-tested.

import Foundation

enum SummaryReplySanitizer {

    /// Content-line cap for text before any recognized section header, and for
    /// unrecognized "[…]" headers. Generous — runaways produce dozens.
    static let defaultBulletCap = 12

    /// Clean one raw engine reply. `headMarker` identifies the real answer among
    /// think segments — "[요약]" for template summaries, "■" for the 화자별 view.
    static func sanitize(_ reply: String, headMarker: String = "[요약]") -> String {
        var text = stripThink(reply, headMarker: headMarker)

        var out: [String] = []
        var seen = Set<String>()
        var blankRun = 0
        var cap = defaultBulletCap
        var linesInSection = 0

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
                out.append(raw)
                continue
            }
            blankRun = 0
            if seen.contains(line) { continue }
            seen.insert(line)

            if let section = sectionHeader(line) {
                cap = section.bulletCap
                linesInSection = 0
            } else if line.hasPrefix("[") {
                cap = defaultBulletCap
                linesInSection = 0
            } else {
                // Cap counts every content line, NOT just "- " bullets: the 2B
                // drops the dash under pressure ("Q: …" lines in the EN probe),
                // and a runaway is a runaway whatever the line prefix.
                linesInSection += 1
                if linesInSection > cap { continue }
            }
            out.append(raw)
        }
        text = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    /// Keep the model's FINAL answer when "</think>" leaks into the reply:
    /// the last segment still carrying the head marker (the restatement is the
    /// polished one), else the longest segment (a truncated restatement must not
    /// beat a complete draft).
    static func stripThink(_ reply: String, headMarker: String) -> String {
        guard reply.contains("</think>") else { return reply }
        let segments = reply.components(separatedBy: "</think>")
        let carrying = segments.filter { $0.contains(headMarker) }
        let best = carrying.last ?? segments.max(by: { $0.count < $1.count }) ?? reply
        return best.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The registry section whose model tag opens this line ("[문답] …" → qa).
    private static func sectionHeader(_ line: String) -> SummarySection? {
        guard line.hasPrefix("[") else { return nil }
        return SummarySection.registry.first { line.hasPrefix("[\($0.tag)]") }
    }
}
