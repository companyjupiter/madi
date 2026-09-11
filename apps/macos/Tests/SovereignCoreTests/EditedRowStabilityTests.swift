import XCTest
@testable import SovereignCore

/// E1 (2026-09-11): an edited row survives a rebuild with exactly its words.
@MainActor
final class EditedRowStabilityTests: XCTestCase {

    private func word(_ s: TranscriptStore, _ t0: Double, _ t1: Double, _ text: String) {
        s.ingest(.word(t0: t0, t1: t1, text: text, conf: 1))
    }
    /// One speaker, one sentence of six words, committed.
    private func seed(_ s: TranscriptStore) {
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 0, dur: 20, margin: 0.9)))
        s.ingest(.wordSectionBegin)
        word(s, 0.2, 0.6, "이거"); word(s, 0.7, 0.9, "두"); word(s, 1.0, 1.3, "개를"); word(s, 1.4, 1.7, "제가")
        word(s, 1.8, 2.3, "스티커를"); word(s, 2.4, 3.0, "모았거든요.")
        s.ingest(.wordSectionBegin)
    }

    func testFormatterEditSurvivesTheNextRebuild() {
        let s = TranscriptStore()
        seed(s)
        XCTAssertEqual(s.lines.count, 1)
        let id = s.lines[0].id
        let formatted = KoreanNumberFormatter.format(s.lines[0].text)
        XCTAssertEqual(formatted, "이거 2개를 제가 스티커를 모았거든요.")
        XCTAssertTrue(s.editLine(id, formatted))
        // more words arrive → the store regroups
        word(s, 3.5, 3.9, "그래서"); word(s, 4.0, 4.4, "여기"); word(s, 4.5, 5.0, "붙여놨는데")
        s.ingest(.wordSectionBegin)
        XCTAssertEqual(s.lines.map(\.text), ["이거 2개를 제가 스티커를 모았거든요.", "그래서 여기 붙여놨는데"])
        XCTAssertEqual(s.lines[0].words.count, 6, "the edited row keeps all six words, not just the first")
        // a relabel rebuild and finalize keep it too
        s.ingest(.speakerFix(SpeakerLabel(time: 0, id: 0, dur: 20, margin: 0.95)))
        s.flushPendingSpeakerFixRebuild()
        XCTAssertEqual(s.lines.map(\.text), ["이거 2개를 제가 스티커를 모았거든요.", "그래서 여기 붙여놨는데"])
        s.finalize()
        XCTAssertEqual(s.lines.map(\.text), ["이거 2개를 제가 스티커를 모았거든요.", "그래서 여기 붙여놨는데"])
        XCTAssertEqual(s.lines[0].words.count, 6)
    }

    func testEditedRowDoesNotGrowAndNextRowIsNotEdited() {
        let s = TranscriptStore()
        seed(s)
        let id = s.lines[0].id
        XCTAssertTrue(s.editLine(id, "이거 2개를 제가 스티커를 모았거든요."))
        word(s, 3.5, 3.9, "그래서"); word(s, 4.0, 4.4, "여기")   // same speaker, gap under lineBreakGap: an unedited row would have grown
        s.ingest(.wordSectionBegin)
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines.last?.text, "그래서 여기")
        XCTAssertEqual(s.lines.last?.isEdited, false)
        XCTAssertEqual(s.lines.first?.words.count, 6)
    }

    func testWordEditSurvivesFinalize() {
        let s = TranscriptStore()
        seed(s)
        XCTAssertTrue(s.editWord(s.lines[0].id, index: 1, to: "2"))
        s.finalize()
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].text, "이거 2 개를 제가 스티커를 모았거든요.")
    }
}
