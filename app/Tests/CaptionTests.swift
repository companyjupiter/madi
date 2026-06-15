// CaptionTests.swift — caption-spec SRT/VTT re-flow invariants.
// Build standalone:
//   swiftc -parse-as-library Sovereign/Transcript/Exporters.swift \
//          Tests/CaptionStub.swift Tests/CaptionTests.swift -o /tmp/captest && /tmp/captest

import Foundation

@main
struct CaptionTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond { failures += 1; print("FAIL: \(msg)") }
        }

        // Helper: synthesize a line of evenly-spaced words.
        func line(speaker: Int, start: Double, wps: Double, _ toks: [String]) -> Line {
            var ws: [Word] = []
            var t = start
            let dur = 1.0 / wps
            for tok in toks { ws.append(Word(t0: t, t1: t + dur * 0.9, text: tok)); t += dur }
            return Line(speaker: speaker, start: start, end: t, words: ws)
        }

        let spec = Exporters.CaptionSpec()  // defaults: 42×2, CPS17, 1.0–7.0s, gap1.0

        // ── 1. A long monologue splits into many ≤2-line cues, each ≤42 chars ──
        do {
            let toks = (0..<60).map { "word\($0)" }     // 60 words → must split
            let cues = Exporters.captionCues([line(speaker: 0, start: 0, wps: 3, toks)], spec: spec)
            check(cues.count > 1, "monologue must split into multiple cues, got \(cues.count)")
            for (i, c) in cues.enumerated() {
                check(c.lines.count <= spec.maxLines, "cue \(i): \(c.lines.count) lines > \(spec.maxLines)")
                for ln in c.lines { check(ln.count <= spec.maxCharsPerLine, "cue \(i) line over \(spec.maxCharsPerLine): \"\(ln)\" (\(ln.count))") }
            }
        }

        // ── 2. Times monotonic + non-overlapping; min duration honored ──
        do {
            let toks = (0..<40).map { "w\($0)" }
            let cues = Exporters.captionCues([line(speaker: 0, start: 5, wps: 4, toks)], spec: spec)
            for i in 0..<cues.count {
                check(cues[i].end >= cues[i].start, "cue \(i) end < start")
                if i + 1 < cues.count {
                    check(cues[i].end <= cues[i + 1].start + 1e-6, "cue \(i) overlaps next (\(cues[i].end) > \(cues[i + 1].start))")
                    check(cues[i + 1].start >= cues[i].start, "cues not chronological at \(i)")
                }
            }
        }

        // ── 3. Reading speed: a SHORT phrase gets extended to ≥ minDur ──
        do {
            let l = line(speaker: 0, start: 0, wps: 20, ["hi", "there"])  // ~0.1s span
            let cues = Exporters.captionCues([l], spec: spec)
            check(cues.count == 1, "short phrase → 1 cue, got \(cues.count)")
            if let c = cues.first { check(c.end - c.start >= spec.minDur - 1e-6, "short cue not extended to minDur: \(c.end - c.start)") }
        }

        // ── 4. CPS cap: a dense cue's duration covers its chars at ≤ maxCPS ──
        do {
            // 2 lines × ~40 chars packed into a tiny time span → must stretch.
            let toks = Array(repeating: "abcde", count: 14)   // 14×5 + spaces ≈ 84 chars
            let l = line(speaker: 0, start: 0, wps: 50, toks)  // very fast → tiny span
            let cues = Exporters.captionCues([l], spec: spec)
            for c in cues {
                let chars = c.lines.reduce(0) { $0 + $1.count }
                let cps = Double(chars) / max(0.001, c.end - c.start)
                // allow maxDur clamp to keep CPS slightly above the cap on huge cues
                check(cps <= spec.maxCPS + 0.5 || (c.end - c.start) >= spec.maxDur - 1e-6,
                      "cue CPS \(cps) > \(spec.maxCPS) and not maxDur-clamped")
            }
        }

        // ── 5. Speaker labels: prefix on speaker change when >1 speaker ──
        do {
            let a = line(speaker: 0, start: 0, wps: 3, ["alpha", "beta"])
            let b = line(speaker: 1, start: 5, wps: 3, ["gamma", "delta"])
            let cues = Exporters.captionCues([a, b], names: [0: "Ana", 1: "Bob"], spec: spec)
            check(cues.first?.lines.first?.hasPrefix("Ana:") ?? false, "first cue missing speaker label: \(cues.first?.lines ?? [])")
            check(cues.contains { $0.lines.first?.hasPrefix("Bob:") ?? false }, "speaker change missing Bob label")
        }

        // ── 6. No speaker labels with a single speaker (clean YouTube captions) ──
        do {
            let l = line(speaker: 0, start: 0, wps: 3, ["one", "two", "three"])
            let cues = Exporters.captionCues([l], names: [0: "Solo"], spec: spec)
            check(!(cues.first?.lines.first?.contains("Solo:") ?? true), "single-speaker should not be labeled")
        }

        // ── 7. A long silence starts a fresh cue ──
        do {
            var ws = [Word(t0: 0, t1: 0.4, text: "before")]
            ws.append(Word(t0: 5.0, t1: 5.4, text: "after"))  // 4.6s gap > gapBreak
            let l = Line(speaker: 0, start: 0, end: 5.4, words: ws)
            let cues = Exporters.captionCues([l], spec: spec)
            check(cues.count == 2, "silence gap must split cue, got \(cues.count)")
        }

        // ── 8. SRT/VTT render shape ──
        do {
            let l = line(speaker: 0, start: 0, wps: 3, ["hello", "world", "foo", "bar"])
            let srt = Exporters.srt([l])
            let vtt = Exporters.vtt([l])
            check(srt.contains(" --> "), "SRT missing arrow")
            check(srt.contains(","), "SRT time should use comma ms")
            check(vtt.hasPrefix("WEBVTT"), "VTT missing header")
            check(vtt.contains("."), "VTT time should use dot ms")
            check(!vtt.contains(",0"), "VTT should not use comma ms")
        }

        // ── 9. No words dropped (round-trip token preservation, single speaker) ──
        do {
            let toks = (0..<30).map { "tok\($0)" }
            let cues = Exporters.captionCues([line(speaker: 0, start: 0, wps: 3, toks)], spec: spec)
            let got = cues.flatMap { $0.lines }.joined(separator: " ").split(separator: " ").map(String.init)
            check(got == toks, "tokens not preserved: \(got.count) vs \(toks.count)")
        }

        if failures == 0 { print("OK: all caption-spec tests passed") }
        else { print("\(failures) FAILURE(S)"); exit(1) }
    }
}
