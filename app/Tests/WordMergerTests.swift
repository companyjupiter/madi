// WordMergerTests.swift — overlap dedup + holdback, reproducing the exact
// failure from the first hardware GUI test (paired duplicate words from the
// 3s segment overlap, incl. re-decode divergence "소버린"/"수버림").
// Build standalone:
//   swiftc -parse-as-library Sovereign/Transcript/WordMerger.swift \
//          Tests/WordMergerStub.swift Tests/WordMergerTests.swift -o /tmp/wmtest && /tmp/wmtest

import Foundation

@main
struct WordMergerTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond { failures += 1; print("FAIL: \(msg)") }
        }
        func texts(_ ws: [Word]) -> String { ws.map(\.text).joined(separator: " ") }

        // ── overlap dedup: seg2 re-emits seg1's overlap region words ──
        do {
            var m = WordMerger()
            m.segmentBreak() // seg1 section begins
            // seg1: 0–10s body
            m.add(Word(t0: 7.0, t1: 7.4, text: "윈도우"))
            m.add(Word(t0: 8.0, t1: 8.4, text: "상태"))
            m.add(Word(t0: 9.0, t1: 9.6, text: "소버린"))   // trailing — boundary-cut
            m.segmentBreak() // seg2 begins (7–20s with 3s overlap)
            // seg2 re-decodes the 7–10 overlap: same audio, divergent text
            m.add(Word(t0: 7.05, t1: 7.45, text: "윈도우"))  // dup — must drop
            m.add(Word(t0: 8.02, t1: 8.42, text: "상태"))    // dup — must drop
            m.add(Word(t0: 9.02, t1: 9.65, text: "수버림"))  // re-decode of held word — wins
            m.add(Word(t0: 11.0, t1: 11.5, text: "위스퍼"))
            m.finish()
            let got = texts(m.committed)
            check(got == "윈도우 상태 수버림 위스퍼",
                  "overlap dedup+holdback: got \"\(got)\"")
        }

        // ── holdback commit when next segment starts clearly after ──
        do {
            var m = WordMerger()
            m.segmentBreak()
            m.add(Word(t0: 1.0, t1: 1.5, text: "안녕"))
            m.add(Word(t0: 9.5, t1: 9.9, text: "하세요"))   // held
            m.segmentBreak()
            m.add(Word(t0: 12.0, t1: 12.4, text: "다음"))   // no overlap coverage → held commits
            m.finish()
            let got = texts(m.committed)
            check(got == "안녕 하세요 다음", "held word committed: got \"\(got)\"")
        }

        // ── final flush releases the trailing word ──
        do {
            var m = WordMerger()
            m.segmentBreak()
            m.add(Word(t0: 0.5, t1: 1.0, text: "마지막"))
            m.finish()
            check(texts(m.committed) == "마지막", "final flush emits trailing word")
        }

        // ── displayWords previews un-merged words immediately ──
        do {
            var m = WordMerger()
            m.segmentBreak()
            m.add(Word(t0: 0.5, t1: 1.0, text: "지금"))
            check(texts(m.displayWords) == "지금", "live preview shows fresh words")
            check(m.committed.isEmpty, "preview does not commit")
        }

        // ── empty segments are harmless ──
        do {
            var m = WordMerger()
            m.segmentBreak(); m.segmentBreak(); m.finish()
            check(m.committed.isEmpty, "empty segments")
        }

        if failures == 0 { print("✅ WordMerger: all checks passed") }
        else { print("❌ \(failures) failure(s)"); exit(1) }
    }
}
