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

    /// A translation remains attached across unrelated rebuilds when its source
    /// line is unchanged (stable-id overlay contract).
    func testTranslationSurvivesUnrelatedRebuild() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0.0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id else { return XCTFail("no line") }
        s.setTranslation(id, lang: "English", "Hello")
        s.ingest(.word(t0: 2.0, t1: 2.3, text: "다음", conf: 1))  // new line; first source unchanged
        XCTAssertEqual(s.lines.first?.translations["English"], "Hello",
                       "translation must survive an unrelated rebuild")
    }

    /// Same id does not mean same source: a growing live line invalidates a
    /// translation generated from its shorter, older revision.
    func testTranslationFromOlderSourceRevisionIsRemoved() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0.0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let revision = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello", sourceRevision: revision))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))
        XCTAssertNil(s.lines.first?.translations["English"])
        XCTAssertFalse(s.setTranslation(id, lang: "English", "stale", sourceRevision: revision))
    }

    func testStaleCorrectionCannotOverwriteNewerUserEdit() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 1, text: "teh", conf: 1))
        guard let id = s.lines.first?.id, let revision = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.editLine(id, "the"))
        XCTAssertFalse(s.editLine(id, "AI old result", expectedRevision: revision))
        XCTAssertEqual(s.lines.first?.text, "the")
    }

    func testDirectTranslationEditIsMarkedAndInvalidatedWithSource() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 1, text: "안녕", conf: 1))
        guard let id = s.lines.first?.id else { return XCTFail() }
        XCTAssertTrue(s.editTranslation(id, lang: "English", "Hi"))
        XCTAssertEqual(s.lines.first?.translations["English"], "Hi")
        XCTAssertTrue(s.lines.first?.editedTranslations.contains("English") ?? false)
        XCTAssertTrue(s.editLine(id, "안녕하세요"))
        XCTAssertTrue(s.lines.first?.translations.isEmpty ?? false)
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

    func testSpeakerMergeResolvesTransitively() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0, id: 3, dur: 10, margin: 1)))
        s.ingest(.word(t0: 0, t1: 1, text: "hello", conf: 1))
        s.mergeSpeaker(from: 3, into: 2)
        s.mergeSpeaker(from: 2, into: 1)
        XCTAssertEqual(s.lines.first?.speaker, 1)
    }
}
