// EditorCutsTests — deterministic, word-list-independent checks of the editor
// cut logic (silence gaps + range merging). GUI-free.
import XCTest
@testable import SovereignCore

final class EditorCutsTests: XCTestCase {

    private func line(_ words: [(Double, Double, String)]) -> Line {
        let ws = words.map { Word(t0: $0.0, t1: $0.1, text: $0.2, conf: 1) }
        return Line(id: UUID(), speaker: 0, start: ws.first?.t0 ?? 0, end: ws.last?.t1 ?? 0, words: ws)
    }

    /// A gap longer than minGap between words becomes one padded silence cut.
    func testSilenceGapDetected() {
        let l = line([(0.0, 0.5, "before"), (2.0, 2.5, "after")])   // gap = 1.5s
        let cuts = EditorCuts.silences([l], minGap: 0.6, pad: 0.1)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts.first?.kind, "silence")
        // interior only: [end+pad, start-pad] = [0.6, 1.9]
        XCTAssertEqual(cuts.first?.start ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(cuts.first?.end ?? 0, 1.9, accuracy: 1e-9)
    }

    /// Sub-minGap gaps produce no cut.
    func testNoSilenceForTightSpeech() {
        let l = line([(0.0, 0.5, "a"), (0.7, 1.0, "b")])            // gap = 0.2s
        XCTAssertTrue(EditorCuts.silences([l], minGap: 0.6).isEmpty)
    }

    /// Overlapping ranges of different kinds fuse into one "mixed" range.
    func testMergeFusesOverlappingMixedKinds() {
        let ranges = [
            CutRange(start: 0.0, end: 1.0, kind: "filler", label: "um"),
            CutRange(start: 0.5, end: 2.0, kind: "silence", label: ""),
        ]
        let merged = EditorCuts.merge(ranges)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.start ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(merged.first?.end ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertEqual(merged.first?.kind, "mixed")
    }

    /// Settings toggles gate which kinds tighten() includes.
    func testTightenHonorsToggles() {
        let l = line([(0.0, 0.5, "before"), (2.0, 2.5, "after")])
        var s = EditorSettings()
        s.fillers = false; s.silences = false
        XCTAssertTrue(EditorCuts.tighten([l], s).isEmpty, "all kinds off → no cuts")
        s.silences = true
        XCTAssertEqual(EditorCuts.tighten([l], s).count, 1, "silence on → the gap cut")
    }
}
