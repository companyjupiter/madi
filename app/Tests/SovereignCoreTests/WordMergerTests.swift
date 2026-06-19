// WordMergerTests — the overlap-dedup + trailing-word holdback that prevents the
// "윈도우 윈도우 소버린 수버림" doubling seen in the first hardware GUI test.
import XCTest
@testable import SovereignCore

final class WordMergerTests: XCTestCase {

    private func w(_ t0: Double, _ t1: Double, _ text: String) -> Word {
        Word(t0: t0, t1: t1, text: text, conf: 1)
    }

    /// A word re-decoded in the next segment's overlap must REPLACE the first
    /// decode (full right context wins), never duplicate it.
    func testOverlapRedecodeReplacesNotDuplicates() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "A"))
        m.add(w(0.5, 0.9, "B"))      // trailing → held
        m.segmentBreak()
        m.add(w(0.5, 0.9, "B2"))     // overlap re-decode of B
        m.add(w(1.0, 1.4, "C"))
        m.segmentBreak()
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["A", "B2", "C"],
                       "re-decode B2 replaces held B; no duplicate")
    }

    /// The trailing word of the final segment is released on finish() (not lost).
    func testFinishReleasesHeldWord() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "only"))
        m.segmentBreak()             // "only" becomes held, nothing committed yet
        XCTAssertTrue(m.committed.isEmpty)
        m.finish()
        XCTAssertEqual(m.committed.map { $0.text }, ["only"])
    }

    /// displayWords shows fresh in-segment words immediately (committed + held +
    /// current buffer) so the live view isn't one segment behind.
    func testDisplayWordsIncludesLiveBuffer() {
        var m = WordMerger()
        m.add(w(0.0, 0.4, "live"))
        XCTAssertEqual(m.displayWords.map { $0.text }, ["live"])
    }
}
