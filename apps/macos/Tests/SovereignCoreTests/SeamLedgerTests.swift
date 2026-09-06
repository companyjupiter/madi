import XCTest
@testable import SovereignCore

/// X1 (2026-09-07): the P15 boundary ledger records a verdict only between two
/// SETTLED words. The held word is the window-edge decode ("implications."
/// conf 0.24, a hallucinated period) and the current segment's words are its
/// re-decode; a verdict decided between them was keyed by the held word's id,
/// which the re-decode inherits — so "…profound implications. | as the AI…"
/// stayed split after the period was gone. 0.3.18 live: 35 of 136 breaks.
@MainActor
final class SeamLedgerTests: XCTestCase {

    override func setUp() { LiveFeatureWiring.joinSameSpeakerNeighbors = true }

    private func word(_ s: TranscriptStore, _ t0: Double, _ t1: Double, _ text: String, conf: Double = 1) {
        s.ingest(.word(t0: t0, t1: t1, text: text, conf: conf))
    }

    /// The window-edge period is provisional: the re-decode drops it and the
    /// sentence continues on ONE row.
    func testWindowEdgePeriodDoesNotOutliveItsRedecode() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 30, margin: 0.9)))
        s.ingest(.wordSectionBegin)
        word(s, 220.3, 220.6, "could"); word(s, 220.6, 220.65, "have"); word(s, 220.65, 221.0, "profound")
        word(s, 221.08, 221.48, "implications.", conf: 0.24)
        s.ingest(.wordSectionBegin)                     // segment 2: "implications." becomes the held word
        word(s, 221.08, 221.59, "implications")         // overlap re-decode: no period
        word(s, 221.7, 221.9, "as"); word(s, 221.9, 222.1, "the"); word(s, 222.1, 222.4, "AI")
        XCTAssertEqual(s.lines.map(\.text), ["could have profound implications as the AI"],
                       "the re-decode replaces the held word in the view and no break was recorded")
        s.ingest(.wordSectionBegin)                     // segment 3 commits the re-decode
        word(s, 222.5, 222.8, "arms"); word(s, 222.8, 223.1, "race")
        XCTAssertEqual(s.lines.map(\.text), ["could have profound implications as the AI arms race"])
        s.finalize()
        XCTAssertEqual(s.lines.map(\.text), ["could have profound implications as the AI arms race"])
    }

    /// A SETTLED period still breaks, is recorded once, and is replayed.
    func testSettledPeriodStillBreaksOnce() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 30, margin: 0.9)))
        s.ingest(.wordSectionBegin)
        word(s, 0.0, 0.3, "It"); word(s, 0.3, 0.6, "was"); word(s, 0.6, 1.0, "benign.")
        word(s, 1.2, 1.5, "But"); word(s, 1.5, 1.8, "I"); word(s, 1.8, 2.1, "think")
        s.ingest(.wordSectionBegin)                     // "think" held; the rest committed
        word(s, 1.85, 2.15, "think"); word(s, 2.2, 2.5, "so.")
        XCTAssertEqual(s.lines.map(\.text), ["It was benign.", "But I think so."])
        s.ingest(.wordSectionBegin)
        word(s, 3.0, 3.3, "Yes.")
        XCTAssertEqual(s.lines.map(\.text), ["It was benign.", "But I think so.", "Yes."])
    }

    /// The tail boundary held→re-decode is decided fresh each rebuild, so a
    /// speaker id that only the CURRENT segment's words carry does not pin a
    /// split once the label fix arrives.
    func testUnsettledSpeakerSplitIsNotPinned() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 2, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2, id: 2, dur: 2, margin: 0.2)))   // provisional
        s.ingest(.wordSectionBegin)
        word(s, 0.1, 0.9, "You"); word(s, 1.1, 1.9, "know,")
        s.ingest(.wordSectionBegin)                     // "know," held
        word(s, 1.1, 1.9, "know,"); word(s, 2.1, 2.9, "I"); word(s, 3.1, 3.9, "mean")
        XCTAssertEqual(s.lines.count, 2, "the provisional id splits the live tail")
        s.ingest(.speakerFix(SpeakerLabel(time: 2, id: 1, dur: 2, margin: 0.9)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.map(\.text), ["You know, I mean"], "no ledger entry to flip: regrouped as one row")
    }

    func testHeldWordIDIsExposed() {
        let s = TranscriptStore()
        s.ingest(.wordSectionBegin)
        word(s, 0, 0.3, "a"); word(s, 0.4, 0.7, "b")
        XCTAssertNil(s.heldWordID)
        s.ingest(.wordSectionBegin)
        XCTAssertEqual(s.heldWordID, s.lines.last?.words.last?.id)
    }

    // ── X4: label-window edge → turn head ───────────────────────────────────

    /// "I" starts 0.1 s before the label window flips to speaker 2; it is the
    /// head of speaker 2's turn, not a one-word row for speaker 1.
    func testTurnHeadAdoptsTheNextSpeaker() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 2, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2, id: 2, dur: 2, margin: 0.3)))
        s.ingest(.wordSectionBegin)
        word(s, 0.2, 0.6, "Is"); word(s, 0.6, 0.9, "it"); word(s, 0.9, 1.4, "higher?")
        word(s, 1.9, 2.0, "I"); word(s, 2.05, 2.3, "use"); word(s, 2.35, 2.7, "Claude"); word(s, 2.75, 3.0, "Code")
        XCTAssertEqual(s.lines.map(\.text), ["Is it higher?", "I use Claude Code"])
        XCTAssertEqual(s.lines.map(\.speaker), [1, 2])
        s.ingest(.wordSectionBegin); word(s, 3.2, 3.5, "daily.")   // commits; the verdicts are recorded and replayed
        s.ingest(.speaker(SpeakerLabel(time: 4, id: 2, dur: 2, margin: 0.3)))
        XCTAssertEqual(s.lines.map(\.text), ["Is it higher?", "I use Claude Code daily."])
        XCTAssertEqual(s.lines.map(\.speaker), [1, 2], "replayed rebuilds keep the adopted speaker")
        s.finalize()
        XCTAssertEqual(s.lines.map(\.speaker), [1, 2])
    }

    /// A short row that ENDS a sentence is a real utterance ("Yes." / "No.").
    func testShortFinishedRowIsNotATurnHead() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 2, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2, id: 2, dur: 2, margin: 0.3)))
        s.ingest(.wordSectionBegin)
        word(s, 1.5, 1.9, "Yes."); word(s, 2.05, 2.3, "use"); word(s, 2.35, 2.7, "it")
        XCTAssertEqual(s.lines.map(\.text), ["Yes.", "use it"])
        XCTAssertEqual(s.lines.map(\.speaker), [1, 2])
    }

    /// Three words before the change are a turn of their own; a pause too.
    func testLongerRowOrPauseStaysASpeakerTurn() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 2, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2, id: 2, dur: 4, margin: 0.3)))
        s.ingest(.wordSectionBegin)
        word(s, 1.0, 1.3, "I"); word(s, 1.3, 1.6, "don't"); word(s, 1.6, 1.95, "know"); word(s, 2.05, 2.4, "exactly")
        XCTAssertEqual(s.lines.map(\.speaker), [1, 2], "3-word row: kept as a turn")
        let u = TranscriptStore()
        u.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 2, margin: 0.9)))
        u.ingest(.speaker(SpeakerLabel(time: 2, id: 2, dur: 4, margin: 0.3)))
        u.ingest(.wordSectionBegin)
        word(u, 1.3, 1.6, "It"); word(u, 1.6, 1.95, "was"); word(u, 2.05, 2.4, "during")
        XCTAssertEqual(u.lines.map(\.speaker), [1, 2], "2-word row: a short turn, kept")
        let t = TranscriptStore()
        t.ingest(.speaker(SpeakerLabel(time: 0, id: 1, dur: 2, margin: 0.9)))
        t.ingest(.speaker(SpeakerLabel(time: 2, id: 2, dur: 4, margin: 0.3)))
        t.ingest(.wordSectionBegin)
        word(t, 1.0, 1.3, "Okay"); word(t, 2.5, 2.9, "so")
        XCTAssertEqual(t.lines.map(\.speaker), [1, 2], "1.2 s pause: kept as a turn")
    }
}
