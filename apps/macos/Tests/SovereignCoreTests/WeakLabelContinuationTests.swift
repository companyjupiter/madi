import XCTest
@testable import SovereignCore

/// W (2026-09-11): a weak label cannot break a sentence.
@MainActor
final class WeakLabelContinuationTests: XCTestCase {

    override func setUp() { LiveFeatureWiring.weakLabelContinuation = LiveFeatureWiring.weakLabelDefault; LiveFeatureWiring.joinSameSpeakerNeighbors = true }
    override func tearDown() { LiveFeatureWiring.weakLabelContinuation = 0 }

    private func word(_ s: TranscriptStore, _ t0: Double, _ t1: Double, _ text: String) {
        s.ingest(.word(t0: t0, t1: t1, text: text, conf: 1))
    }
    /// Speaker 3 (confident) for 0–2 s, then a label 11 from 2 s on with the given
    /// margin; one sentence runs across the change ("자다 보면 숨이 | 막혀요").
    private func seed(_ s: TranscriptStore, margin: Double = 0.05, aTail: String = "숨이", gap: Double = 0.1) {
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 3, dur: 2, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2, id: 11, dur: 4, margin: margin)))
        s.ingest(.wordSectionBegin)
        word(s, 0.2, 0.8, "자다"); word(s, 0.9, 1.4, "보면"); word(s, 1.5, 1.95, aTail)
        word(s, 1.95 + gap, 2.6, "막혀요."); word(s, 2.7, 3.0, "일곱"); word(s, 3.05, 3.4, "명이")
    }

    func testWeakLabelContinuesTheRowUnderItsSpeaker() {
        let s = TranscriptStore()
        seed(s)
        XCTAssertEqual(s.lines.map(\.text), ["자다 보면 숨이 막혀요.", "일곱 명이"])
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11], "the sentence stays with speaker 3; the next sentence opens under the new label")
        XCTAssertGreaterThanOrEqual(s.weakLabelContinuations, 1, "counted per rebuild")
        s.ingest(.wordSectionBegin)   // commit; the verdict replays from the ledger
        word(s, 3.5, 3.9, "한")
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11])
        s.finalize()
        XCTAssertEqual(s.lines.first?.text, "자다 보면 숨이 막혀요.")
        XCTAssertEqual(s.lines.first?.speaker, 3)
    }

    func testConfidentLabelStillBreaks() {
        let s = TranscriptStore()
        seed(s, margin: 0.6)
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11, 11], "a confident change mid-sentence is a real turn")
        XCTAssertEqual(s.lines.first?.text, "자다 보면 숨이")
    }

    func testSentenceEndBeforeTheChangeBreaks() {
        let s = TranscriptStore()
        seed(s, aTail: "숨이.")
        XCTAssertEqual(s.lines.map(\.text), ["자다 보면 숨이.", "막혀요.", "일곱 명이"])
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11, 11])
    }

    func testPauseBeforeTheChangeBreaks() {
        let s = TranscriptStore()
        seed(s, gap: 0.5)
        XCTAssertEqual(s.lines.first?.text, "자다 보면 숨이")
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11, 11])
    }

    func testOneWordRowKeepsItsOwnSpeakerAgainstAWeakHead() {
        // X4 would hand a one-word row to the next speaker; a WEAK next label
        // must not take the row with it.
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 3, dur: 0.9, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 0.9, id: 11, dur: 4, margin: 0.05)))
        s.ingest(.wordSectionBegin)
        word(s, 0.2, 0.8, "자다"); word(s, 0.95, 1.4, "보면"); word(s, 1.5, 1.95, "숨이")
        XCTAssertEqual(s.lines.map(\.speaker), [3])
        XCTAssertEqual(s.lines.first?.speakerMargin, 0.9, "a glued weak word does not lower the row's own label confidence")
    }

    func testFlagOffBreaks() {
        LiveFeatureWiring.weakLabelContinuation = 0
        let s = TranscriptStore()
        seed(s)
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11, 11])
    }

    func testGateIsNonEnglishOnly() {
        XCTAssertEqual(LiveFeatureWiring.weakLabelContinuation(for: 50259), 0, "English live untouched")
        XCTAssertEqual(LiveFeatureWiring.weakLabelContinuation(for: nil), 0, "auto-detect: unknown → off")
        XCTAssertEqual(LiveFeatureWiring.weakLabelContinuation(for: 50264), LiveFeatureWiring.weakLabelDefault)
    }
}
