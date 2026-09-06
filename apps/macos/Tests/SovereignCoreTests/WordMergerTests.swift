// WordMergerTests — the overlap-dedup + trailing-word holdback that prevents the
// "윈도우 윈도우 소버린 수버림" doubling seen in the first hardware GUI test.
import XCTest
@testable import SovereignCore

final class WordMergerTests: XCTestCase {

    private func w(_ t0: Double, _ t1: Double, _ text: String) -> Word {
        Word(t0: t0, t1: t1, text: text, conf: 1)
    }

    /// A word re-decoded in the next segment's overlap must REPLACE the first
    /// decode (full right context wins), never duplicate it.
    func testOverlapRedecodeReplacesNotDuplicates() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "A"))
        m.add(w(0.5, 0.9, "B"))      // trailing → held
        m.segmentBreak()
        m.add(w(0.5, 0.9, "B2"))     // overlap re-decode of B
        m.add(w(1.0, 1.4, "C"))
        m.segmentBreak()
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["A", "B2", "C"],
                       "re-decode B2 replaces held B; no duplicate")
    }

    /// P1: the re-decode that replaces the held word inherits its id, so the line
    /// that starts with it keeps its identity across the segment boundary.
    func testRedecodeInheritsHeldWordIdentity() {
        var m = WordMerger()
        let held = w(0.5, 0.9, "B")
        m.add(w(0.0, 0.4, "A"))
        m.add(held)                  // trailing → held
        m.segmentBreak()
        m.add(w(0.5, 0.9, "B2"))     // overlap re-decode of B
        m.add(w(1.0, 1.4, "C"))
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["A", "B2", "C"])
        XCTAssertEqual(m.committed[1].id, held.id, "re-decode keeps the held word's id")
    }

    /// The trailing word of the final segment is released on finish() (not lost).
    func testFinishReleasesHeldWord() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "only"))
        m.segmentBreak()             // "only" becomes held, nothing committed yet
        XCTAssertTrue(m.committed.isEmpty)
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["only"])
    }

    /// displayWords shows fresh in-segment words immediately (committed + held +
    /// current buffer) so the live view isn't one segment behind.
    func testDisplayWordsIncludesLiveBuffer() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "live"))
        XCTAssertEqual(m.displayWords.map { $0.text }, ["live"])
    }

    /// Degenerate cross-chunk repeat ("ndo.com. ndo.com…") must be truncated once
    /// the same phrase has repeated past the cap — not committed forever.
    func testRunawayRepeatIsTruncated() {
        var m = WordMerger()
        var t = 0.0
        for _ in 0..<20 { m.add(w(t, t + 0.3, "ndo.com.")); t += 0.3 }
        m.finish()
        let reps = m.committed.filter { $0.text == "ndo.com." }.count
        XCTAssertLessThanOrEqual(reps, WordMerger.maxPhraseRepeats + 1,
            "runaway single-word repeat must be capped, got \(reps)")
    }

    /// A repeated multi-word phrase ("A B A B A B…") is also capped by period.
    func testRunawayPhraseRepeatIsTruncated() {
        var m = WordMerger()
        var t = 0.0
        for _ in 0..<12 { for s in ["ho", "ho"] { m.add(w(t, t + 0.2, s)); t += 0.2 } }
        m.finish()
        XCTAssertLessThan(m.committed.count, 10, "period-2 loop must be capped")
    }

    /// Genuine speech that happens to repeat a couple of times is NOT truncated.
    func testShortLegitRepeatSurvives() {
        var m = WordMerger()
        let words = ["네", "네", "네", "그래서", "우리는", "다시", "시작", "합니다"]
        var t = 0.0
        for s in words { m.add(w(t, t + 0.3, s)); t += 0.3 }
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, words, "3× backchannel + normal speech survives")
    }

    // ── L2 (2026-09-06): seam re-decode duplicate ──────────────────────────

    /// The overlap re-decodes the previous window's last word with drifted
    /// timestamps, past the watermark AND past the held-word replacement
    /// window: "that." [4.6–4.9] comes back as "that." [4.95–5.2]. Same text
    /// at the seam within 0.6 s → the same audio; drop it.
    func testSeamRedecodeOfLastWordIsDropped() {
        var m = WordMerger()
        m.add(w(3.0, 3.4, "center"))
        m.add(w(3.5, 3.9, "of"))
        m.add(w(4.6, 4.9, "that."))      // trailing → held
        m.segmentBreak()
        m.add(w(5.0, 5.3, "that."))      // seam re-decode, t0 > held.t1 + eps (4.95)
        m.add(w(5.4, 5.8, "Whatever"))
        m.add(w(5.9, 6.2, "Anthropic"))
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["center", "of", "that.", "Whatever", "Anthropic"])
        XCTAssertEqual(m.seamDuplicatesDropped, 1)
    }

    /// Case and punctuation do not hide the duplicate ("That" vs "that.").
    func testSeamDuplicateMatchIgnoresCaseAndPunctuation() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "Is"))
        m.add(w(0.5, 0.9, "it"))
        m.add(w(1.0, 1.4, "still"))
        m.add(w(1.5, 1.9, "years?"))     // held
        m.segmentBreak()
        m.add(w(2.0, 2.4, "Years"))      // seam re-decode
        m.add(w(2.5, 2.9, "No."))
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["Is", "it", "still", "years?", "No."])
    }

    /// A genuine repeat is decoded inside one window and never sits on the seam
    /// with a tiny gap: the same word starting ≥ 0.6 s after the previous one
    /// ended is kept.
    func testRepeatWithRealGapIsKept() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "no"))
        m.add(w(0.5, 0.9, "no"))         // in-window repeat → kept by the merger
        m.segmentBreak()
        m.add(w(1.6, 2.0, "no"))         // 0.7 s after the held word ended → kept
        m.add(w(2.1, 2.5, "way"))
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["no", "no", "no", "way"])
        XCTAssertEqual(m.seamDuplicatesDropped, 0)
    }

    /// Different text at the seam is untouched (the held-word replacement path
    /// still owns the "B → B2" case).
    func testSeamDifferentWordUnaffected() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "A"))
        m.add(w(0.5, 0.9, "B"))
        m.segmentBreak()
        m.add(w(1.0, 1.4, "C"))
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["A", "B", "C"])
    }

    /// The new window can open with the re-decode AND a stub copy of it.
    func testWindowStartDoubleIsDropped() {
        var m = WordMerger()
        m.add(w(148.0, 148.5, "with"))
        m.add(w(149.0, 149.5, "you?"))     // held
        m.segmentBreak()
        m.add(w(149.0, 149.5, "you?"))     // re-decode → replaces held
        m.add(w(150.02, 150.04, "You"))    // 20 ms stub of the same word
        m.add(w(150.3, 150.7, "Great"))
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["with", "you?", "Great"])
    }

    /// Identical word at the same instant, any position → dropped.
    func testSameInstantDuplicateIsDropped() {
        var m = WordMerger()
        m.add(w(321.65, 321.66, "And"))
        m.add(w(321.65, 322.21, "and"))
        m.add(w(321.65, 322.21, "and"))
        m.add(w(322.3, 322.6, "then"))
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["And", "then"])
        XCTAssertEqual(m.sameInstantDuplicatesDropped + m.seamDuplicatesDropped, 2)
    }
}
