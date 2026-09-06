import XCTest
@testable import SovereignCore

/// L1 (2026-09-06): a recluster/AI relabel that makes two ADJACENT lines the
/// same speaker joins them when the first line is mid-sentence. Finished
/// lines, real speaker turns and user-edited lines are never touched.
@MainActor
final class SameSpeakerJoinTests: XCTestCase {

    override func setUp() { LiveFeatureWiring.joinSameSpeakerNeighbors = true }

    /// Two label windows: the second gets a PROVISIONAL different id.
    /// `words` are laid 1 word/second so 2 words fall in each 2 s window.
    private func seed(_ s: TranscriptStore, words: [String], secondID: Int = 2, margin: Double = 0.05) {
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 1, dur: 2.0, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2.0, id: secondID, dur: 2.0, margin: margin)))
        s.ingest(.wordSectionBegin)
        for (i, t) in words.enumerated() {
            let t0 = Double(i) + 0.1   // off the label edge: 2 words per window
            s.ingest(.word(t0: t0, t1: t0 + 0.8, text: t, conf: 1))
        }
        s.ingest(.wordSectionBegin)   // X1: commit the words — live verdicts are recorded once settled
    }

    func testFixJoinsUnfinishedSameSpeakerTailLines() {
        let s = TranscriptStore()
        seed(s, words: ["It", "was,", "during", "the"])
        XCTAssertEqual(s.lines.count, 2, "provisional id opens a second row")
        let firstID = s.lines[0].id
        s.ingest(.speakerFix(SpeakerLabel(time: 2.0, id: 1, dur: 2.0, margin: 0.9)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.count, 1, "same speaker + mid-sentence → one row")
        XCTAssertEqual(s.lines[0].id, firstID, "the survivor keeps the first line's id")
        XCTAssertEqual(s.lines[0].text, "It was, during the")
        XCTAssertEqual(s.sameSpeakerJoins + s.speakerFixRebuilds, 2, "one rebuild; tail joins via the ledger")
    }

    func testFinishedLineKeepsItsRow() {
        let s = TranscriptStore()
        seed(s, words: ["Hello.", "Yes.", "during", "the"])
        XCTAssertEqual(s.lines.map(\.text), ["Hello.", "Yes.", "during the"])
        s.ingest(.speakerFix(SpeakerLabel(time: 2.0, id: 1, dur: 2.0, margin: 0.9)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.map(\.text), ["Hello.", "Yes.", "during the"], "a sentence-ended line is a finished row")
        XCTAssertEqual(Set(s.lines.map(\.speaker)), [1])
    }

    func testRealTurnStaysSplit() {
        let s = TranscriptStore()
        seed(s, words: ["It", "was", "during", "the"])
        XCTAssertEqual(s.lines.count, 2)
        // the fix CONFIRMS speaker 2 (margin settles high) — still a turn
        s.ingest(.speakerFix(SpeakerLabel(time: 2.0, id: 2, dur: 2.0, margin: 0.9)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines.map(\.speaker), [1, 2])
    }

    func testFrozenPairJoinsInPlaceAndTranslationGoesStaleNotLost() {
        let s = TranscriptStore()
        // 12 words over 12 s: the first two lines freeze (6 s behind the head)
        var words = ["It", "was", "during", "the"]
        words += ["pandemic", "so", "the", "story", "goes", "and", "then", "more"]
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 1, dur: 2.0, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2.0, id: 2, dur: 2.0, margin: 0.05)))
        s.ingest(.speaker(SpeakerLabel(time: 4.0, id: 3, dur: 8.0, margin: 0.9)))
        s.ingest(.wordSectionBegin)
        for (i, t) in words.enumerated() {
            let t0 = Double(i) + 0.1
            s.ingest(.word(t0: t0, t1: t0 + 0.8, text: t, conf: 1))
        }
        s.ingest(.wordSectionBegin)
        XCTAssertGreaterThanOrEqual(s.lines.count, 3, "\(s.lines.map(\.text))")
        XCTAssertEqual(s.lines[0].text, "It was")
        XCTAssertEqual(s.lines[1].text, "during the")
        let first = s.lines[0]
        guard let rev = s.sourceRevision(for: first.id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(first.id, lang: "Korean", "그것은 였다", sourceRevision: rev))
        let before = s.lines.count
        s.ingest(.speakerFix(SpeakerLabel(time: 2.0, id: 1, dur: 2.0, margin: 0.9)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.count, before - 1, "the frozen pair joined in place: \(s.lines.map(\.text))")
        let joined = s.lines[0]
        XCTAssertEqual(joined.id, first.id)
        XCTAssertEqual(joined.text, "It was during the")
        XCTAssertNil(joined.translations["Korean"], "old fragment translation is no longer valid…")
        XCTAssertEqual(joined.staleTranslations["Korean"], "그것은 였다", "…but is kept as stale until re-translated")
        XCTAssertEqual(s.sameSpeakerJoins, 1)
    }

    func testUserEditedLineNeverJoins() {
        let s = TranscriptStore()
        seed(s, words: ["It", "was", "during", "the"])
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertTrue(s.editWord(s.lines[0].id, index: 0, to: "That"))
        s.ingest(.speakerFix(SpeakerLabel(time: 2.0, id: 1, dur: 2.0, margin: 0.9)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.count, 2, "an edited line is the user's; never restructure it")
    }

    func testWiringOffKeepsRows() {
        LiveFeatureWiring.joinSameSpeakerNeighbors = false
        defer { LiveFeatureWiring.joinSameSpeakerNeighbors = true }
        let s = TranscriptStore()
        seed(s, words: ["It", "was", "during", "the"])
        s.ingest(.speakerFix(SpeakerLabel(time: 2.0, id: 1, dur: 2.0, margin: 0.9)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.sameSpeakerJoins, 0)
    }

    /// S1: a transient id with under 3 s of speech spends no display number.
    func testTransientSpeakerIDGetsNoNumberUntilItHasSpeech() {
        SpeakerDisplayNumber.minSecondsToNumber = 3.0
        defer { SpeakerDisplayNumber.minSecondsToNumber = 10.0 }
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 1, dur: 4.0, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 4.0, id: 7, dur: 1.0, margin: 0.9)))   // one short window
        s.ingest(.speaker(SpeakerLabel(time: 5.0, id: 1, dur: 4.0, margin: 0.9)))
        for (i, t) in ["we", "were", "at", "the", "park.", "yes", "and", "then", "we"].enumerated() {
            let t0 = Double(i) + 0.1
            s.ingest(.word(t0: t0, t1: t0 + 0.8, text: t, conf: 1))
        }
        XCTAssertEqual(s.speakerNumbers.number(1), 1)
        XCTAssertNil(s.speakerNumbers.number(7), "0.8 s of speech: still deciding, no number spent")
        s.finalize()
        XCTAssertEqual(s.speakerNumbers.number(7), 2, "finalize numbers what is left, in order")
    }
}
