import XCTest
@testable import SovereignCore

/// P4: a live monologue supplies neither a 1.5 s pause nor sentence punctuation,
/// so the line used to grow without bound — and a growing tail line is never
/// translated (translateStableLines skips the last line) while every new word
/// invalidates whatever translation had landed. Live 0.3.6 (KO→EN·日) and the
/// user's own archive (worst line: 1753 words / 567 s) both show it.
@MainActor final class TranscriptLineCapTests: XCTestCase {
    /// Feed `n` words with no punctuation and no pause, `rate` seconds apart,
    /// continuing the store's existing timeline (a second call must not rewind —
    /// the merger sorts by time and would restructure everything).
    @discardableResult
    private func monologue(_ s: TranscriptStore, words n: Int, rate: Double = 0.35,
                           prefix: String = "말", from: Double = 0) -> Double {
        var t = from
        for i in 0..<n {
            s.ingest(.word(t0: t, t1: t + rate * 0.9, text: "\(prefix)\(i)", conf: 1))
            t += rate
        }
        return t
    }

    func testUnpunctuatedMonologueIsSplitIntoTranslatableLines() {
        let s = TranscriptStore()
        _ = monologue(s, words: 200)
        XCTAssertGreaterThan(s.lines.count, 1, "a 200-word monologue must not be one line")
        for line in s.lines {
            XCTAssertLessThanOrEqual(line.words.count, 28, "line over the word cap: \(line.text.prefix(40))")
            XCTAssertLessThan(line.end - line.start, 15.0, "line over the duration cap")
        }
    }

    /// Slow speech hits the time cap before the word cap.
    func testSlowSpeechSplitsByDuration() {
        let s = TranscriptStore()
        _ = monologue(s, words: 40, rate: 1.2)  // 1.2 s apart, under the 1.5 s gap rule
        XCTAssertEqual(s.lines.count, 1 + 40 * 12 / 168, accuracy: 3, "≈ one line per 14 s")
        for line in s.lines { XCTAssertLessThan(line.end - line.start, 15.0) }
    }

    /// Ordinary punctuated speech is untouched: the sentence rule still owns the
    /// boundary, and short lines never reach the cap.
    func testPunctuatedSpeechIsUnchanged() {
        let s = TranscriptStore()
        var t = 0.0
        for _ in 0..<6 {
            for (i, w) in ["오늘은", "회의를", "시작합니다."].enumerated() {
                s.ingest(.word(t0: t, t1: t + 0.3, text: w, conf: 1)); t += 0.35
                _ = i
            }
        }
        XCTAssertEqual(s.lines.count, 6, "one line per sentence, exactly as before")
        XCTAssertTrue(s.lines.allSatisfy { $0.words.count == 3 })
    }

    /// A comma is the preferred boundary once the line is long, but never breaks
    /// a short line.
    func testCommaBreaksOnlyPastTheSoftThreshold() {
        XCTAssertFalse(TranscriptStore.lineIsFull(words: 4, span: 2, tailEndsClause: true))
        XCTAssertTrue(TranscriptStore.lineIsFull(words: 16, span: 6, tailEndsClause: true))
        XCTAssertFalse(TranscriptStore.lineIsFull(words: 16, span: 6, tailEndsClause: false))
        XCTAssertTrue(TranscriptStore.lineIsFull(words: 28, span: 6, tailEndsClause: false))
        XCTAssertTrue(TranscriptStore.lineIsFull(words: 5, span: 14, tailEndsClause: false))
    }

    /// P15 invariant: the boundary is decided once and replayed, so the same
    /// word stream always produces the same line structure — a capped break must
    /// not re-split under the reader as later words arrive.
    func testCapBoundariesAreStableAcrossRebuilds() {
        let s = TranscriptStore()
        let t = monologue(s, words: 60)
        let idsAfter60 = s.lines.map(\.id)
        monologue(s, words: 40, prefix: "다음", from: t)   // keeps growing; earlier lines must not move
        let idsAfter100 = s.lines.map(\.id)
        XCTAssertEqual(Array(idsAfter100.prefix(idsAfter60.count - 1)),
                       Array(idsAfter60.dropLast()),
                       "already-committed capped lines keep their identity")
    }
}
