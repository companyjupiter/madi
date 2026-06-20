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

/// User-adjustable editor-feature toggles + thresholds (persisted). Every editor
/// analysis reads from here so the UI can tune behavior without code changes.
struct EditorSettings: Codable, Equatable {
    // include toggles (which signals are produced / exported)
    var fillers = true
    var silences = true
    var chapters = true
    var retakes = true
    var highlights = true
    // E2 / N3 silence
    var silenceMinGap = 0.6
    var silencePad = 0.1
    // N4 chapters
    var chapterGap = 2.5
    var chapterMinLen = 20.0
    // N1 retakes
    var retakeSim = 0.7
    var retakeMinTokens = 3
    // N5 highlights
    var hlMinWords = 5
    var hlMinPause = 1.0
    var hlMinConf = 0.8

    private static let key = "editorSettings"
    static func load() -> EditorSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(EditorSettings.self, from: d) else { return .init() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
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

    /// Settings-aware tighten: includes only the enabled kinds, with the
    /// configured silence thresholds.
    static func tighten(_ lines: [Line], _ s: EditorSettings) -> [CutRange] {
        var all: [CutRange] = []
        if s.fillers { all += fillers(lines) }
        if s.silences { all += silences(lines, minGap: s.silenceMinGap, pad: s.silencePad) }
        return merge(all.sorted { $0.start < $1.start })
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

    // ── N1 retake detection ───────────────────────────────────────────────────
    struct RetakeGroup: Equatable { var keepStart: Double; var keepText: String; var drops: [CutRange] }

    /// Adjacent near-duplicate takes (a creator redoing a line). A run of
    /// consecutive lines whose word-set Jaccard ≥ `simThreshold` is a retake
    /// group; we suggest keeping the highest-confidence take and dropping the
    /// rest (as removable "retake" ranges). Conservative: both lines must have
    /// ≥ `minTokens` words, so short back-channels ("네", "yeah") don't match.
    /// A *suggestion* — the creator confirms; not auto-applied.
    static func retakes(_ lines: [Line], simThreshold: Double = 0.7, minTokens: Int = 3) -> [RetakeGroup] {
        var out: [RetakeGroup] = []
        var i = 0
        while i < lines.count {
            var j = i
            while j + 1 < lines.count,
                  lines[j].words.count >= minTokens, lines[j + 1].words.count >= minTokens,
                  jaccard(lines[j], lines[j + 1]) >= simThreshold { j += 1 }
            if j > i {
                let run = Array(lines[i...j])
                let keep = run.max(by: { avgConf($0) < avgConf($1) })!
                let drops = run.filter { $0.id != keep.id }.map {
                    CutRange(start: $0.start, end: $0.end, kind: "retake",
                             label: String($0.text.prefix(40)))
                }
                out.append(RetakeGroup(keepStart: keep.start,
                                       keepText: String(keep.text.prefix(40)), drops: drops))
                i = j + 1
            } else { i += 1 }
        }
        return out
    }

    private static func avgConf(_ l: Line) -> Double {
        let cs = l.words.map(\.conf)
        return cs.isEmpty ? 0 : cs.reduce(0, +) / Double(cs.count)
    }

    // ── N5 highlight candidates (speculative) ─────────────────────────────────
    struct Highlight: Equatable { var start: Double; var end: Double; var text: String; var score: Double }

    /// Speculative "moments worth clipping" surface. The original idea keyed on
    /// loudness, but per-word RMS isn't in the app model — so this uses available
    /// proxies for emphasis: a line PRECEDED BY A PAUSE (≥ minPause: the speaker
    /// set up a point), delivered CLEARLY (avg conf ≥ minConf), and SUBSTANTIAL
    /// (≥ minWords). All three gate; score = pauseBefore × avgConf, sorted desc.
    /// Heuristic candidates for review, NOT guaranteed highlights.
    static func highlights(_ lines: [Line], minWords: Int = 5, minPause: Double = 1.0,
                           minConf: Double = 0.8) -> [Highlight] {
        var out: [Highlight] = []
        var prevEnd: Double? = nil
        for l in lines {
            defer { prevEnd = max(prevEnd ?? l.end, l.end) }
            guard l.words.count >= minWords else { continue }
            let conf = avgConf(l)
            guard conf >= minConf else { continue }
            let pause = prevEnd.map { l.start - $0 } ?? 0
            guard pause >= minPause else { continue }
            out.append(Highlight(start: l.start, end: l.end,
                                 text: String(l.text.prefix(60)), score: pause * conf))
        }
        return out.sorted { $0.score > $1.score }
    }

    private static func jaccard(_ a: Line, _ b: Line) -> Double {
        let sa = Set(a.words.map { normalize($0.text) }.filter { !$0.isEmpty })
        let sb = Set(b.words.map { normalize($0.text) }.filter { !$0.isEmpty })
        if sa.isEmpty || sb.isEmpty { return 0 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }
}
