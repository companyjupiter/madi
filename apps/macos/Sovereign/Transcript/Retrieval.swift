// Retrieval.swift — on-device lexical retrieval for transcript Q&A. The DNA3
// engine context is ~1024 tokens; a long meeting can't be fed whole, so we pick
// the question-relevant lines (by keyword overlap, with Korean particle-stemming)
// that fit a character budget — answering over REAL excerpts, not a clipped head.
// Pure (Foundation only) so it's unit-tested without the live engine.

import Foundation

enum Retrieval {
    /// Question → content keywords (+ Korean stems). Split on whitespace/punctuation,
    /// drop interrogatives; for ≥3-char tokens also index the trailing-particle-stripped
    /// stem so "김부장이" matches a "김부장:" line.
    static func keywords(_ q: String) -> [String] {
        let stop: Set<String> = ["무엇", "무엇을", "뭐", "뭘", "누가", "누구", "어떤", "어떻게", "언제",
            "어디", "왜", "한", "일은", "것", "건",
            "what", "who", "when", "where", "why", "how", "the", "an", "is", "are", "did", "do", "of"]
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) { if !s.isEmpty, !seen.contains(s) { seen.insert(s); out.append(s) } }
        for tok in q.lowercased().split(whereSeparator: { $0 == " " || $0.isPunctuation || $0.isWhitespace }) {
            let t = String(tok)
            guard t.count >= 2, !stop.contains(t) else { continue }
            add(t)
            if t.count >= 3 { add(String(t.dropLast())) }   // 조사 strip: 김부장이→김부장
        }
        return out
    }

    /// Rank `lines` by keyword overlap for `q` and keep the highest-scoring lines
    /// that fit `budget` characters (chronological order preserved). Returns all
    /// lines unchanged if they already fit; `[]` if nothing matches (caller can let
    /// the model answer "not in the transcript").
    static func relevantLines(_ q: String, _ lines: [String], budget: Int) -> [String] {
        let joined = lines.joined(separator: " / ")
        if joined.count <= budget { return lines }
        let kws = keywords(q)
        guard !kws.isEmpty else { return lines }
        func score(_ line: String) -> Int {
            let low = line.lowercased()
            return kws.reduce(0) { $0 + (low.contains($1) ? 1 : 0) }
        }
        let ranked = lines.enumerated()
            .map { (i: $0.offset, line: $0.element, s: score($0.element)) }
            .sorted { $0.s != $1.s ? $0.s > $1.s : $0.i < $1.i }
        var picked: [(i: Int, line: String)] = []
        var len = 0
        for r in ranked where r.s > 0 {
            if len + r.line.count + 3 > budget { continue }
            picked.append((r.i, r.line)); len += r.line.count + 3
        }
        return picked.sorted { $0.i < $1.i }.map { $0.line }
    }
}
