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

    // ── X1/X2 (2026-09-07, 0.3.18 live bundle) ──────────────────────────────

    /// X1: what the view shows between segment boundaries must equal what the
    /// merge will commit — the held word and its overlap re-decode are never
    /// both displayed ("thoughts thoughts", "race race escalates, escalates,").
    func testDisplayWordsMirrorTheSeamMerge() {
        var m = WordMerger()
        m.add(w(211.0, 211.2, "cosmic"))
        m.add(w(211.25, 211.6, "thoughts"))       // trailing → held
        m.segmentBreak()
        m.add(w(210.9, 211.2, "cosmic"))          // overlap re-decode, before the watermark → filtered
        m.add(w(211.27, 211.66, "thoughts"))      // re-decode of the held word
        m.add(w(211.7, 212.0, "into"))
        let shown = m.displayWords.map(\.text)
        XCTAssertEqual(shown, ["cosmic", "thoughts", "into"], "held word replaced in the view, not doubled")
        m.segmentBreak(); m.finish()
        XCTAssertEqual(m.committed.map(\.text), shown, "the view and the merge agree")
    }

    /// X1: the re-decode shown in place of the held word carries the held
    /// word's id, exactly as merge() will assign it (line ids, ledger keys).
    func testDisplayRedecodeCarriesHeldIdentity() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "profound"))
        m.add(w(0.5, 0.9, "implications."))
        m.segmentBreak()
        let heldID = m.displayWords.last!.id
        m.add(w(0.52, 1.0, "implications"))
        m.add(w(1.1, 1.3, "as"))
        XCTAssertEqual(m.displayWords.map(\.text), ["profound", "implications", "as"])
        XCTAssertEqual(m.displayWords[1].id, heldID)
        m.finish()
        XCTAssertEqual(m.committed[1].id, heldID)
    }

    /// X1: a seam re-decode of the last COMMITTED word (drifted timestamps) is
    /// dropped from the view as merge() drops it.
    func testDisplayDropsSeamDuplicateOfCommittedWord() {
        var m = WordMerger()
        m.add(w(4.0, 4.4, "of"))
        m.add(w(4.6, 4.9, "that."))
        m.segmentBreak()                          // "that." held
        m.add(w(5.0, 5.3, "Whatever"))            // covers nothing: held "that." commits below
        m.segmentBreak()                          // "Whatever" held, "that." committed
        m.add(w(5.02, 5.31, "Whatever"))          // re-decode of the held word → replaces
        m.add(w(5.4, 5.8, "Anthropic"))
        XCTAssertEqual(m.displayWords.map(\.text), ["of", "that.", "Whatever", "Anthropic"])
        m.finish()
        XCTAssertEqual(m.committed.map(\.text), ["of", "that.", "Whatever", "Anthropic"])
    }

    /// X2: a window-tail stub ("AI." 40 ms, conf 0.24) followed by continuing
    /// speech is the decoder closing the audio edge, not a word — dropped.
    func testTailStubDroppedWhenSpeechContinues() {
        var m = WordMerger()
        m.add(w(280.7, 281.2, "company"))
        m.add(w(281.22, 281.44, "with"))
        m.add(Word(t0: 281.44, t1: 281.48, text: "AI.", conf: 0.24))   // held
        m.segmentBreak()
        m.add(w(281.22, 281.52, "with"))          // overlap re-decode, t0 < watermark → filtered
        m.add(w(281.64, 281.89, "the"))           // 0.16 s after the stub: speech continues
        m.add(w(281.9, 282.35, "most"))
        XCTAssertEqual(m.displayWords.map(\.text), ["company", "with", "the", "most"])
        m.finish()
        XCTAssertEqual(m.committed.map(\.text), ["company", "with", "the", "most"])
    }

    /// X2: the same stub before a real pause is kept — nothing re-decodes it.
    func testTailStubKeptBeforeAPause() {
        var m = WordMerger()
        m.add(w(195.8, 196.36, "don't"))
        m.add(Word(t0: 196.4, t1: 196.48, text: "release.", conf: 0.21))
        m.segmentBreak()
        m.add(w(199.5, 199.9, "Anthropic"))       // 3 s later: a new turn
        m.finish()
        XCTAssertEqual(m.committed.map(\.text), ["don't", "release.", "Anthropic"])
    }

    /// A segment made only of pre-held strays must not lose the held word.
    func testStrayOnlySegmentKeepsHeldWord() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "A"))
        m.add(w(0.5, 0.9, "B"))                   // held
        m.segmentBreak()
        m.add(w(0.0, 0.45, "A"))                  // t0 ≤ held.t1 + eps, but ends before held starts
        m.segmentBreak()
        m.add(w(1.0, 1.4, "C"))
        m.finish()
        XCTAssertEqual(m.committed.map(\.text), ["A", "B", "C"])
    }
}
