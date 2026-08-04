// P4 — a line whose text moves on no longer deletes its displayed translation:
// the old rendering is kept as stale display text and replaced in place.
import XCTest
@testable import SovereignCore

@MainActor
final class TranslationStaleKeepTests: XCTestCase {

    func testGrowthKeepsOldRenderingAsStale() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello", sourceRevision: rev))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))   // line grows → new revision
        let line = s.lines.first!
        XCTAssertNil(line.translations["English"], "outdated result must leave the valid slot")
        XCTAssertEqual(line.staleTranslations["English"], "Hello",
                       "…but stay visible as a stale rendering instead of vanishing")
    }

    func testReplacementClearsStaleInPlace() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello", sourceRevision: rev))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))
        guard let rev2 = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello, nice to meet you",
                                       sourceRevision: rev2))
        let line = s.lines.first!
        XCTAssertEqual(line.translations["English"], "Hello, nice to meet you")
        XCTAssertNil(line.staleTranslations["English"], "replaced in place — no stale leftover")
    }

    func testEditLineKeepsStaleRendering() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "소버림", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Soverim", sourceRevision: rev))
        XCTAssertTrue(s.editLine(id, "소버린", expectedRevision: rev))
        let line = s.lines.first!
        XCTAssertNil(line.translations["English"])
        XCTAssertEqual(line.staleTranslations["English"], "Soverim",
                       "user's source edit grays the old translation, doesn't erase it")
    }

    func testPruneKeepsOldRevisionButDropsUnroutedLanguage() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello", sourceRevision: rev))
        XCTAssertTrue(s.setTranslation(id, lang: "Korean", "안녕", sourceRevision: rev))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))
        guard let rev2 = s.sourceRevision(for: id) else { return XCTFail() }
        // Routing now excludes Korean; English is merely from an older revision.
        let valid = s.pruneTranslations(id, validTargets: ["English"], sourceRevision: rev2)
        XCTAssertTrue(valid.isEmpty, "old-revision result must not count as existing")
        let line = s.lines.first!
        XCTAssertEqual(line.staleTranslations["English"], "Hello", "kept for display")
        XCTAssertNil(line.staleTranslations["Korean"], "unrouted language is gone for good")
        XCTAssertNil(line.translations["Korean"])
    }

    func testStatusStillReportsTranslatingWhileStale() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요.", conf: 1))
        s.ingest(.word(t0: 2.5, t1: 2.8, text: "다음", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello.", sourceRevision: rev))
        s.editLine(id, "안녕하세요. 여러분")
        let line = s.lines.first!
        // The slot needs a re-translation, so the STATE is still 'translating' —
        // the view suppresses the dots because the stale text is the status.
        XCTAssertEqual(line.status(activeLangs: ["English"], isLiveTail: false, translateBusy: true),
                       .translating)
        XCTAssertFalse(line.staleTranslations.isEmpty)
    }
}
