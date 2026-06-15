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

        if failures == 0 { print("OK: all EditorCuts tests passed") }
        else { print("\(failures) FAILURE(S)"); exit(1) }
    }
}
