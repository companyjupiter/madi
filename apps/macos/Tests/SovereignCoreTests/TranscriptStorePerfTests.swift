import XCTest
@testable import SovereignCore

/// P2 (2026-09-03): the per-word ingest cost must not grow with the session.
/// Live 0.3.5 at 37 min (~400 lines) spent ~20% of the main thread inside
/// TranscriptStore.ingest — `lines = frozen + tail` plus full-transcript overlay
/// passes on EVERY word. This drives ~500 lines in and reports the cost of the
/// last 200 word events (the number PERF_LOG cites; the assertion only guards
/// the invariant that a tail-only rebuild equals a full one).
@MainActor final class TranscriptStorePerfTests: XCTestCase {
    private func drive(_ s: TranscriptStore, lines: Int) -> (() -> Void) {
        var t = 0.0, n = 0
        func word() {
            s.ingest(.word(t0: t, t1: t + 0.25, text: "word\(n % 7)", conf: n % 9 == 0 ? 0.3 : 0.9))
            t += 0.3; n += 1
        }
        for line in 0..<lines {
            s.ingest(.speaker(SpeakerLabel(time: t, id: (line / 5) % 3, dur: 4.0, margin: 0.5)))
            for _ in 0..<12 { word() }
            t += 1.6
            if line % 20 == 0 { s.ingest(.wordSectionBegin) }
        }
        return word
    }

    func testIngestCostAtSessionLength() {
        let s = TranscriptStore()
        let word = drive(s, lines: 500)
        let before = s.lines.count
        let clock = ContinuousClock()
        let d = clock.measure { for _ in 0..<200 { word() } }
        let ms = (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 / 200
        print(String(format: "PERF ingest avg %.3f ms/word at %d lines", ms, s.lines.count))
        XCTAssertGreaterThan(s.lines.count, before)
        // Invariant: every line's overlay fields equal a from-scratch recompute.
        let snapshot = s.lines
        s.recomputeAllOverlaysForTest()
        XCTAssertEqual(snapshot, s.lines, "tail-only overlay pass must equal a full pass")
    }
}
