// EditorCuts.swift — editor-facing cut analysis over the per-word transcript.
// Pure post-process on the existing Word/Line model (timestamps + text); no
// engine change. The building blocks for the one-click "tighten" cut-list:
//   · fillers  (E1) — disfluency words to ripple-delete
//   · silences (E2) — dead-air gaps to tighten
// A CutRange is a [start,end) span the editor can remove from the timeline.

import Foundation

struct CutRange: Equatable {
    var start: Double
    var end: Double
    var kind: String        // "filler" | "silence"
    var label: String       // the filler word, or "" for silence
    var duration: Double { max(0, end - start) }
}

enum EditorCuts {
    /// Unambiguous disfluencies only. Content-ambiguous words (like, you know,
    /// 그, 저, 뭐, 막, 이제, ah) are deliberately EXCLUDED — a false positive here
    /// means a wrong cut, so the lexicon errs toward precision over recall.
    static let fillerLexicon: Set<String> = [
        // English
        "um", "umm", "ummm", "uhm", "uh", "uhh", "uhhh", "er", "err", "erm",
        "hmm", "hm", "hmmm", "mm", "mmm", "mhm", "uh-huh", "huh",
        // Korean
        "음", "으음", "음음", "어", "어어", "엄", "에", "흠",
    ]

    /// Lowercase, trim whitespace, strip surrounding punctuation (so "Um," and
    /// "uh…" still match). Internal characters are kept.
    static func normalize(_ s: String) -> String {
        let punct = CharacterSet(charactersIn: ",.!?…\"'`’”“()-—· ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punct)
            .lowercased()
    }

    /// Filler-word occurrences as removable cut ranges, in transcript order.
    static func fillers(_ lines: [Line]) -> [CutRange] {
        var out: [CutRange] = []
        for l in lines {
            for w in l.words where fillerLexicon.contains(normalize(w.text)) {
                out.append(CutRange(start: w.t0, end: w.t1, kind: "filler",
                                    label: w.text.trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    /// Dead-air gaps between words longer than `minGap`, as removable cut ranges.
    /// `pad` is left on each side so the surrounding speech isn't clipped — the
    /// cut spans only the interior silence. Words are time-sorted across all
    /// lines; overlapping words (negative gap) are skipped.
    static func silences(_ lines: [Line], minGap: Double = 0.6, pad: Double = 0.1) -> [CutRange] {
        let ws = lines.flatMap { $0.words }.sorted { $0.t0 < $1.t0 }
        var out: [CutRange] = []
        var i = 1
        while i < ws.count {
            let gap = ws[i].t0 - ws[i - 1].t1
            if gap > minGap {
                let s = ws[i - 1].t1 + pad
                let e = ws[i].t0 - pad
                if e > s { out.append(CutRange(start: s, end: e, kind: "silence", label: "")) }
            }
            i += 1
        }
        return out
    }

    /// One-click "tighten": fillers + silences merged into a sorted,
    /// non-overlapping list of removable ranges (the N3 headline). Adjacent or
    /// overlapping cuts fuse; a fused range of mixed kinds is labelled "mixed".
    static func tighten(_ lines: [Line], minGap: Double = 0.6, pad: Double = 0.1) -> [CutRange] {
        let all = (fillers(lines) + silences(lines, minGap: minGap, pad: pad))
            .sorted { $0.start < $1.start }
        return merge(all)
    }

    /// Merge overlapping/touching ranges (input must be sorted by start).
    static func merge(_ ranges: [CutRange]) -> [CutRange] {
        var out: [CutRange] = []
        for r in ranges {
            if var last = out.last, r.start <= last.end {
                last.end = max(last.end, r.end)
                if last.kind != r.kind { last.kind = "mixed"; last.label = "" }
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }

    // ── N4 auto-chapters ──────────────────────────────────────────────────────
    struct Chapter: Equatable { var start: Double; var title: String }

    /// Chapter boundaries for long content (YouTube chapters). A new chapter
    /// starts at a pause longer than `gap`, but only if `minLen` has elapsed
    /// since the previous chapter (so we don't over-segment). The first chapter
    /// is pinned to 0:00 (YouTube requires it). Titles are the opening words of
    /// the boundary line.
    static func chapters(_ lines: [Line], gap: Double = 2.5, minLen: Double = 20) -> [Chapter] {
        guard let first = lines.first else { return [] }
        var out: [Chapter] = [Chapter(start: 0, title: chapterTitle(first))]
        var lastEnd = first.end
        for l in lines.dropFirst() {
            let gapBefore = l.start - lastEnd
            if gapBefore > gap, l.start - (out.last?.start ?? 0) > minLen {
                out.append(Chapter(start: l.start, title: chapterTitle(l)))
            }
            lastEnd = max(lastEnd, l.end)
        }
        return out
    }

    private static func chapterTitle(_ l: Line) -> String {
        let words = l.text.split(separator: " ").prefix(7).joined(separator: " ")
        let t = String(words.prefix(40)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "챕터" : t
    }
}
