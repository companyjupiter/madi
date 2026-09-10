import XCTest
@testable import SovereignCore

/// X5 (2026-09-11): a weak-label island between two rows of one speaker.
@MainActor
final class SpeakerIslandTests: XCTestCase {

    override func setUp() { LiveFeatureWiring.speakerIslandAbsorption = true; LiveFeatureWiring.joinSameSpeakerNeighbors = true }
    override func tearDown() { LiveFeatureWiring.speakerIslandAbsorption = false }

    private func word(_ s: TranscriptStore, _ t0: Double, _ t1: Double, _ text: String) {
        s.ingest(.word(t0: t0, t1: t1, text: text, conf: 1))
    }
    /// Speaker 3 for 0–2 s and 3–6 s (confident), a 0.05-margin label 2–3 s in between.
    private func seed(_ s: TranscriptStore, islandMargin: Double = 0.05, aTail: String = "옛날에는", bTail: String = "없었던") {
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 3, dur: 2, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2, id: 11, dur: 1, margin: islandMargin)))
        s.ingest(.speaker(SpeakerLabel(time: 3, id: 3, dur: 3, margin: 0.9)))
        s.ingest(.wordSectionBegin)
        word(s, 0.2, 0.8, "인간은"); word(s, 0.9, 1.4, "그걸"); word(s, 1.5, 1.95, aTail)
        word(s, 2.05, 2.4, "판단할"); word(s, 2.45, 2.7, "수가"); word(s, 2.75, 2.95, bTail)
        word(s, 3.05, 3.4, "거고"); word(s, 3.5, 4.0, "판단해도"); word(s, 4.1, 4.6, "문제가")
    }

    func testIslandIsAbsorbedIntoTheSpeakerAround() {
        let s = TranscriptStore()
        seed(s)
        XCTAssertEqual(s.lines.map(\.text), ["인간은 그걸 옛날에는 판단할 수가 없었던 거고 판단해도 문제가"])
        XCTAssertEqual(s.lines.map(\.speaker), [3])
        XCTAssertGreaterThanOrEqual(s.islandAbsorptions, 1, "counted per rebuild")
        s.ingest(.wordSectionBegin)   // commit; the verdicts replay the same way
        word(s, 4.7, 5.0, "많았고")
        XCTAssertEqual(s.lines.count, 1)
        s.finalize()
        XCTAssertEqual(s.lines.map(\.speaker), [3])
    }

    func testConfidentLabelIsARealTurn() {
        let s = TranscriptStore()
        seed(s, islandMargin: 0.9)
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11, 3], "a confident label between the rows is a real interjection")
    }

    func testSentenceEndBeforeTheIslandKeepsIt() {
        let s = TranscriptStore()
        seed(s, aTail: "옛날에는.")
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11, 3], "the row before ended a sentence: the island may be a real turn")
    }

    func testFlagOffKeepsRows() {
        LiveFeatureWiring.speakerIslandAbsorption = false
        let s = TranscriptStore()
        seed(s)
        XCTAssertEqual(s.lines.map(\.speaker), [3, 11, 3])
    }

    func testGateIsNonEnglishOnly() {
        XCTAssertFalse(LiveFeatureWiring.islandAbsorption(for: 50259), "English live untouched")
        XCTAssertFalse(LiveFeatureWiring.islandAbsorption(for: nil), "auto-detect: unknown → off")
        XCTAssertTrue(LiveFeatureWiring.islandAbsorption(for: 50264))
        XCTAssertTrue(LiveFeatureWiring.islandAbsorption(for: 50260))
    }
}
