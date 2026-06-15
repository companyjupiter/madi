// EditorCutsTests.swift — filler (E1) + silence (E2) cut detection.
// Build standalone:
//   swiftc -parse-as-library Sovereign/Transcript/EditorCuts.swift \
//          Tests/CaptionStub.swift Tests/EditorCutsTests.swift -o /tmp/ectest && /tmp/ectest

import Foundation

@main
struct EditorCutsTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1; print("FAIL: \(msg)") } }

        func line(_ toks: [(String, Double, Double)], speaker: Int = 0) -> Line {
            let ws = toks.map { Word(t0: $0.1, t1: $0.2, text: $0.0) }
            return Line(speaker: speaker, start: ws.first?.t0 ?? 0, end: ws.last?.t1 ?? 0, words: ws)
        }

        // ── 1. Unambiguous fillers flagged (case + punctuation insensitive) ──
        do {
            let l = line([("Um,", 0, 0.3), ("the", 0.3, 0.6), ("uh", 0.6, 0.8),
                          ("plan", 0.8, 1.2), ("음", 1.2, 1.4), ("works", 1.4, 1.8)])
            let cuts = EditorCuts.fillers([l])
            check(cuts.count == 3, "expected 3 fillers, got \(cuts.count): \(cuts.map(\.label))")
            check(cuts.allSatisfy { $0.kind == "filler" }, "kind should be filler")
            check(cuts.first?.start == 0 && cuts.first?.end == 0.3, "first filler range wrong")
        }

        // ── 2. Content-ambiguous words NOT flagged (precision over recall) ──
        do {
            // 그/저/뭐/이제/like/ah are intentionally excluded.
            let l = line([("그", 0, 0.3), ("저", 0.3, 0.6), ("뭐", 0.6, 0.9),
                          ("이제", 0.9, 1.2), ("like", 1.2, 1.5), ("ah", 1.5, 1.8),
                          ("really", 1.8, 2.2)])
            let cuts = EditorCuts.fillers([l])
            check(cuts.isEmpty, "ambiguous content words must not be flagged, got \(cuts.map(\.label))")
        }

        // ── 3. Normalize: trailing punctuation / case / spaces ──
        do {
            check(EditorCuts.normalize("  UH… ") == "uh", "normalize failed: \(EditorCuts.normalize("  UH… "))")
            check(EditorCuts.normalize("Hmm,") == "hmm", "normalize failed: \(EditorCuts.normalize("Hmm,"))")
            check(EditorCuts.fillerLexicon.contains(EditorCuts.normalize("Um,")), "Um, should match")
        }

        // ── 4. Order preserved across multiple lines ──
        do {
            let a = line([("uh", 0, 0.2), ("yes", 0.2, 0.6)])
            let b = line([("no", 5, 5.3), ("um", 5.3, 5.6)], speaker: 1)
            let cuts = EditorCuts.fillers([a, b])
            check(cuts.map(\.start) == [0, 5.3], "fillers not in order: \(cuts.map(\.start))")
        }

        // ── 5. Silence: gaps > minGap become padded cut ranges ──
        do {
            // gap 0.5→2.0 = 1.5s (>0.6); gap 2.3→2.4 = 0.1s (< minGap, no cut)
            let l = line([("a", 0, 0.5), ("b", 2.0, 2.3), ("c", 2.4, 2.8)])
            let cuts = EditorCuts.silences([l], minGap: 0.6, pad: 0.1)
            check(cuts.count == 1, "expected 1 silence, got \(cuts.count)")
            if let c = cuts.first {
                check(abs(c.start - 0.6) < 1e-9, "silence start (pad) wrong: \(c.start)")
                check(abs(c.end - 1.9) < 1e-9, "silence end (pad) wrong: \(c.end)")
                check(c.kind == "silence", "kind should be silence")
            }
        }

        // ── 6. Silence: padding never produces a negative/zero range ──
        do {
            // gap exactly 0.65s, pad 0.1 each side → 0.45s cut (ok). A 0.7s gap
            // with pad 0.4 each → would be negative, must be dropped.
            let l = line([("a", 0, 1.0), ("b", 1.7, 2.0)])
            check(EditorCuts.silences([l], minGap: 0.6, pad: 0.4).isEmpty,
                  "over-padded silence must be dropped")
            check(EditorCuts.silences([l], minGap: 0.6, pad: 0.1).count == 1,
                  "normal-padded silence should appear")
        }

        // ── 7. Silence: overlapping words (negative gap) skipped ──
        do {
            let l = line([("a", 0, 2.0), ("b", 1.5, 3.0)])  // b starts before a ends
            check(EditorCuts.silences([l]).isEmpty, "overlap must not produce a silence cut")
        }

        // ── 8. Tighten: fillers + silences merged, sorted, non-overlapping ──
        do {
            // "uh"(0–0.3) filler, then 0.3→2.0 silence (1.7s gap). The filler end
            // (0.3) touches the silence start (0.3+0.1 pad=0.4) — not overlapping,
            // so 2 cuts; verify sorted + each well-formed.
            let l = line([("uh", 0, 0.3), ("ok", 2.0, 2.4), ("um", 2.4, 2.7)])
            let cuts = EditorCuts.tighten([l], minGap: 0.6, pad: 0.1)
            check(cuts.count >= 2, "tighten should find filler + silence, got \(cuts.count)")
            for i in 1..<cuts.count { check(cuts[i].start >= cuts[i - 1].start, "tighten not sorted") }
            for i in 1..<cuts.count { check(cuts[i].start >= cuts[i - 1].end - 1e-9, "tighten overlaps at \(i)") }
        }

        // ── 9. Merge fuses overlapping ranges into one (mixed kind) ──
        do {
            let r = [CutRange(start: 0, end: 1.0, kind: "filler", label: "uh"),
                     CutRange(start: 0.8, end: 2.0, kind: "silence", label: "")]
            let m = EditorCuts.merge(r)
            check(m.count == 1, "overlapping ranges must merge, got \(m.count)")
            check(m.first?.end == 2.0 && m.first?.kind == "mixed", "merge result wrong: \(m)")
        }

        // ── 10. Chapters: first at 0:00; a long pause past minLen splits ──
        do {
            let a = line([("intro", 0, 0.4), ("topic", 0.5, 1.0)])
            // gap 1.0→30.0 = 29s (>2.5) and 30s past chapter 0 (>20) → new chapter
            let b = line([("second", 30.0, 30.5), ("part", 30.6, 31.0)], speaker: 1)
            let ch = EditorCuts.chapters([a, b], gap: 2.5, minLen: 20)
            check(ch.first?.start == 0, "first chapter must be 0:00, got \(ch.first?.start ?? -1)")
            check(ch.count == 2, "expected 2 chapters, got \(ch.count)")
            check(ch.last?.start == 30.0, "second chapter start wrong: \(ch.last?.start ?? -1)")
            check(!(ch.first?.title.isEmpty ?? true), "chapter title empty")
        }

        // ── 11. Chapters: a pause too soon (within minLen) does NOT split ──
        do {
            let a = line([("a", 0, 0.4)])
            let b = line([("b", 5.0, 5.4)])   // 4.6s gap but only 5s in (< minLen 20)
            check(EditorCuts.chapters([a, b], gap: 2.5, minLen: 20).count == 1,
                  "early pause must not create a chapter")
        }

        // ── 12. Retake: two near-identical takes → keep higher-conf, drop other ──
        do {
            var w1 = [Word(t0: 0, t1: 0.4, text: "let's"), Word(t0: 0.4, t1: 0.8, text: "start"),
                      Word(t0: 0.8, t1: 1.2, text: "the"), Word(t0: 1.2, t1: 1.6, text: "intro")]
            for i in w1.indices { w1[i].conf = 0.55 }            // weaker take
            var w2 = [Word(t0: 3, t1: 3.4, text: "let's"), Word(t0: 3.4, t1: 3.8, text: "start"),
                      Word(t0: 3.8, t1: 4.2, text: "the"), Word(t0: 4.2, t1: 4.6, text: "intro")]
            for i in w2.indices { w2[i].conf = 0.95 }            // stronger take → keep
            let a = Line(speaker: 0, start: 0, end: 1.6, words: w1)
            let b = Line(speaker: 0, start: 3, end: 4.6, words: w2)
            let rt = EditorCuts.retakes([a, b], simThreshold: 0.7, minTokens: 3)
            check(rt.count == 1, "expected 1 retake group, got \(rt.count)")
            check(rt.first?.keepStart == 3, "should keep the higher-conf (later) take")
            check(rt.first?.drops.first?.start == 0, "should drop the weaker take at 0")
        }

        // ── 13. Retake: dissimilar lines, and too-short lines, not grouped ──
        do {
            let a = line([("the", 0, 0.4), ("weather", 0.4, 0.9), ("today", 0.9, 1.4)])
            let b = line([("stock", 3, 3.4), ("market", 3.4, 3.9), ("news", 3.9, 4.4)])
            check(EditorCuts.retakes([a, b]).isEmpty, "dissimilar lines must not be a retake")
            let s1 = line([("네", 0, 0.3)]); let s2 = line([("네", 1, 1.3)])
            check(EditorCuts.retakes([s1, s2]).isEmpty, "too-short lines must not be a retake")
        }

        // ── 14. Highlight: pause-preceded + confident + substantial line surfaces ──
        do {
            func conf(_ toks: [(String, Double, Double)], _ c: Double, sp: Int = 0) -> Line {
                var ws = toks.map { Word(t0: $0.1, t1: $0.2, text: $0.0) }
                for i in ws.indices { ws[i].conf = c }
                return Line(speaker: sp, start: ws.first!.t0, end: ws.last!.t1, words: ws)
            }
            // line A ends at 1.0; line B starts at 3.0 (2.0s pause), 6 words, conf .95 → highlight
            let a = conf([("ok", 0, 0.5), ("so", 0.5, 1.0)], 0.9)
            let b = conf([("this", 3.0, 3.3), ("is", 3.3, 3.5), ("the", 3.5, 3.7),
                          ("key", 3.7, 4.0), ("point", 4.0, 4.4), ("today", 4.4, 4.9)], 0.95)
            let hi = EditorCuts.highlights([a, b], minWords: 5, minPause: 1.0, minConf: 0.8)
            check(hi.count == 1, "expected 1 highlight, got \(hi.count)")
            check(hi.first?.start == 3.0, "highlight should be the pause-preceded line")
            check((hi.first?.score ?? 0) > 0, "highlight score should be positive")
        }

        // ── 15. Highlight: no pause, low conf, or too-short → no candidate ──
        do {
            func conf(_ toks: [(String, Double, Double)], _ c: Double) -> Line {
                var ws = toks.map { Word(t0: $0.1, t1: $0.2, text: $0.0) }
                for i in ws.indices { ws[i].conf = c }
                return Line(speaker: 0, start: ws.first!.t0, end: ws.last!.t1, words: ws)
            }
            // back-to-back (no pause), confident, long → no highlight (no setup pause)
            let a = conf([("one", 0, 0.5), ("two", 0.5, 1.0)], 0.9)
            let b = conf([("a", 1.0, 1.3), ("b", 1.3, 1.6), ("c", 1.6, 1.9),
                          ("d", 1.9, 2.2), ("e", 2.2, 2.5)], 0.95)
            check(EditorCuts.highlights([a, b]).isEmpty, "no-pause line must not be a highlight")
            // pause + long but LOW conf → no highlight
            let c = conf([("x", 5.0, 5.3), ("y", 5.3, 5.6), ("z", 5.6, 5.9),
                          ("w", 5.9, 6.2), ("v", 6.2, 6.5)], 0.4)
            check(EditorCuts.highlights([a, c]).isEmpty, "low-conf line must not be a highlight")
        }

        if failures == 0 { print("OK: all EditorCuts tests passed") }
        else { print("\(failures) FAILURE(S)"); exit(1) }
    }
}
