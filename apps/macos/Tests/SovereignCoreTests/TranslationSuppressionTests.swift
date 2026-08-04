// P0 — guard-suppressed finals must roll back their streamed partials instead
// of leaving guard-invalid text on screen posing as a translation.
import XCTest
@testable import SovereignCore

@MainActor
final class TranslationSuppressionTests: XCTestCase {

    private func lineID(_ s: TranscriptStore) -> UUID? { s.lines.first?.id }

    func testSuppressRollsBackStreamedPartial() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = lineID(s), let rev = s.sourceRevision(for: id) else { return XCTFail() }
        // Streamed partial landed via the same write path the engine uses…
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hel", sourceRevision: rev))
        // …then the final failed the guard chain → suppression.
        XCTAssertTrue(s.suppressTranslation(id, lang: "English", sourceRevision: rev))
        XCTAssertNil(s.lines.first?.translations["English"],
                     "guard-invalid streamed text must not persist")
        XCTAssertTrue(s.lines.first?.suppressedTranslations.contains("English") ?? false)
    }

    func testSuppressedLangStopsPromisingATranslation() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요.", conf: 1))
        s.ingest(.word(t0: 2.5, t1: 2.8, text: "다음", conf: 1))   // first line stops being last
        guard let id = lineID(s), let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.suppressTranslation(id, lang: "English", sourceRevision: rev))
        let line = s.lines.first!
        XCTAssertEqual(line.status(activeLangs: ["English"], isLiveTail: false, translateBusy: true),
                       .completed,
                       "a suppressed language must not hold the status row in 'translating'")
    }

    func testStaleSuppressionIsRejected() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = lineID(s), let rev = s.sourceRevision(for: id) else { return XCTFail() }
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))   // revision moved on
        XCTAssertFalse(s.suppressTranslation(id, lang: "English", sourceRevision: rev),
                       "a verdict for an older revision must not touch the current line")
        XCTAssertFalse(s.lines.first?.suppressedTranslations.contains("English") ?? true)
    }

    func testTextRevisionLiftsSuppression() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = lineID(s), let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.suppressTranslation(id, lang: "English", sourceRevision: rev))
        // The line grows → new revision → re-translation is queued by the
        // session layer; the stale verdict must lift.
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))
        XCTAssertFalse(s.lines.first?.suppressedTranslations.contains("English") ?? true,
                       "suppression binds to one source revision only")
    }

    func testUserEditedTranslationIsNeverSuppressed() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = lineID(s) else { return XCTFail() }
        XCTAssertTrue(s.editTranslation(id, lang: "English", "Hello (fixed)"))
        XCTAssertFalse(s.suppressTranslation(id, lang: "English"))
        XCTAssertEqual(s.lines.first?.translations["English"], "Hello (fixed)")
    }

    func testFreshSuppressionWithoutPriorTextStillRecordsVerdict() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = lineID(s), let rev = s.sourceRevision(for: id) else { return XCTFail() }
        // No partial ever streamed (echo caught before first frame) — the
        // verdict alone must still stick so the status row settles.
        XCTAssertTrue(s.suppressTranslation(id, lang: "Japanese", sourceRevision: rev))
        XCTAssertTrue(s.lines.first?.suppressedTranslations.contains("Japanese") ?? false)
    }
}
