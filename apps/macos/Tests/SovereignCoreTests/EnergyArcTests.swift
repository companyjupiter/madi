// EnergyArcTests — pure meeting-energy binning over the transcript. GUI-free.
import XCTest
@testable import SovereignCore

final class EnergyArcTests: XCTestCase {

    private func line(_ start: Double, _ end: Double, speaker: Int = 0, overlap: [Int] = []) -> Line {
        Line(id: UUID(), speaker: speaker, start: start, end: end,
             words: [Word(t0: start, t1: end, text: "x", conf: 1)], overlapSpeakers: overlap)
    }

    func testEmptyAndDegenerateReturnEmpty() {
        XCTAssertTrue(EnergyArc.compute(lines: []).isEmpty)
        XCTAssertTrue(EnergyArc.compute(lines: [line(0, 0)]).isEmpty)   // zero span
    }

    func testEmitsBucketCountAndNormalizedRange() {
        let lines = (0..<10).map { line(Double($0), Double($0) + 0.8) }   // 0–9.8s
        let e = EnergyArc.compute(lines: lines, buckets: 12)
        XCTAssertEqual(e.count, 12)
        XCTAssertTrue(e.allSatisfy { $0 >= 0 && $0 <= 1 }, "all buckets in 0...1")
        XCTAssertEqual(e.max() ?? 0, 1.0, accuracy: 1e-9, "normalized — peak bucket hits 1")
    }

    func testBusyBucketBeatsSilentBucket() {
        // Dense, overlapping speech early (0–2s); a long silent gap; one lone
        // line at 9–10s extends the span so the middle buckets are truly empty.
        let lines = [
            line(0, 2, speaker: 0),
            line(0, 2, speaker: 1, overlap: [0]),     // overlap boosts early energy
            line(0.5, 1.5, speaker: 2, overlap: [0, 1]),
            line(9, 10, speaker: 0),                  // lone late line, no overlap
        ]
        let e = EnergyArc.compute(lines: lines, buckets: 10)   // 1s buckets over 0–10s
        XCTAssertEqual(e.count, 10)
        XCTAssertGreaterThan(e[0], e[9], "early dense/overlapping bucket > late lone bucket")
        XCTAssertEqual(e[5], 0, accuracy: 1e-9, "mid-meeting silence → 0 energy")
    }
}
