// TranscriptStoreTests — regression tests for the stable-id + overlay design
// (this is the fix that made live translation show during recording and made
// inline editing survive the per-word live rebuild). All GUI-free.
import XCTest
@testable import SovereignCore

@MainActor
final class TranscriptStoreTests: XCTestCase {

    /// A line's id must NOT change when the next word triggers rebuildLive().
    /// (Before the fix, every rebuild minted a fresh UUID and orphaned overlays.)
    func testLineIdStableAcrossRebuild() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0.0, t1: 0.3, text: "Hello", conf: 1))
        let id1 = s.lines.first?.id
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "world", conf: 1))  // → rebuildLive()
        let id2 = s.lines.first?.id
        XCTAssertNotNil(id1)
        XCTAssertEqual(id1, id2, "line id must be stable across the per-word rebuild")
    }

    /// An async translation that lands, THEN more words arrive, must persist.
    /// This is exactly the live-translate-during-recording bug.
    func testTranslationSurvivesRebuild() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0.0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id else { return XCTFail("no line") }
        s.setTranslation(id, lang: "English", "Hello")
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))  // rebuild after translation
        XCTAssertEqual(s.lines.first?.translations["English"], "Hello",
                       "translation must survive the rebuild that follows it")
    }

    /// Inline edit of a committed line persists through rebuilds and wins in text/export.
    func testEditSurvivesRebuildAndOverridesText() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0.0, t1: 0.3, text: "teh", conf: 1))
        guard let id = s.lines.first?.id else { return XCTFail("no line") }
        s.editLine(id, "the")
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "cat", conf: 1))  // rebuild
        XCTAssertEqual(s.lines.first?.text, "the", "edited text overrides joined words")
        XCTAssertTrue(s.lines.first?.isEdited ?? false)
    }

    /// reset() must clear the id-keyed overlays, not just the lines — otherwise a
    /// recycled id could resurrect a stale translation in the next session.
    func testResetClearsOverlays() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0.0, t1: 0.3, text: "x", conf: 1))
        if let id = s.lines.first?.id { s.setTranslation(id, lang: "English", "X") }
        s.reset()
        XCTAssertTrue(s.lines.isEmpty)
        s.ingest(.word(t0: 0.0, t1: 0.3, text: "x", conf: 1))  // fresh word → fresh id
        XCTAssertNil(s.lines.first?.translations["English"],
                     "reset must drop overlays so they don't leak into the next session")
    }
}
