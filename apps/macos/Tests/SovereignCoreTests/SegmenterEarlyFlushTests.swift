// SegmenterEarlyFlushTests.swift — the silence early-flush must cut a window
// as soon as the speaker finishes (trailing silence) WITHOUT breaking the
// offset clock, the overlap chain, or far-field (quiet-speech) sessions.

import XCTest
@testable import SovereignCore

final class SegmenterEarlyFlushTests: XCTestCase {
    private let sr = 16000
    private func speech(_ seconds: Double, amp: Int16 = 3000) -> [Int16] {
        // ±amp square wave — loud enough to register as voiced hops
        (0..<Int(seconds * Double(sr))).map { $0 % 2 == 0 ? amp : -amp }
    }
    private func silence(_ seconds: Double, amp: Int16 = 40) -> [Int16] {
        (0..<Int(seconds * Double(sr))).map { $0 % 2 == 0 ? amp : -amp }
    }

    func testEarlyFlushAfterTrailingSilence() {
        var seg = Segmenter(sampleRate: sr, segmentSeconds: 10, overlapSeconds: 3,
                            firstSegmentSeconds: 10)
        // 3s speech then silence — window should close ~0.7s into the silence,
        // long before the 10s boundary.
        XCTAssertTrue(seg.push(speech(3)).isEmpty)
        let cut = seg.push(silence(1.0))
        XCTAssertEqual(cut.count, 1)
        XCTAssertEqual(cut[0].offset, 0)
        // body = everything pushed so far (4s), well under the 10s window
        XCTAssertEqual(cut[0].bodyCount, Int(4.0 * Double(sr)))
    }

    func testNoFlushWithoutSpeech() {
        var seg = Segmenter(sampleRate: sr, segmentSeconds: 10, overlapSeconds: 3,
                            firstSegmentSeconds: 10)
        // pure silence never early-cuts (would chop dead air into segments)
        XCTAssertTrue(seg.push(silence(6)).isEmpty)
    }

    func testNoFlushBeforeMinBody() {
        var seg = Segmenter(sampleRate: sr, segmentSeconds: 10, overlapSeconds: 3,
                            firstSegmentSeconds: 10)
        // 1s speech + 1s silence = 2s body < 2.5s minimum → hold
        XCTAssertTrue(seg.push(speech(1)).isEmpty)
        XCTAssertTrue(seg.push(silence(1)).isEmpty)
    }

    func testDisabledIsLegacyBehavior() {
        var seg = Segmenter(sampleRate: sr, segmentSeconds: 5, overlapSeconds: 1,
                            firstSegmentSeconds: 5)
        seg.earlyFlushSilenceSeconds = 0
        XCTAssertTrue(seg.push(speech(3)).isEmpty)
        XCTAssertTrue(seg.push(silence(1.9)).isEmpty)      // 4.9s < 5s window
        let cut = seg.push(silence(0.2))                   // crosses 5s → regular cut
        XCTAssertEqual(cut.count, 1)
        XCTAssertEqual(cut[0].bodyCount, Int(5.0 * Double(sr)))
    }

    func testOffsetContinuityAfterEarlyCut() {
        var seg = Segmenter(sampleRate: sr, segmentSeconds: 10, overlapSeconds: 2,
                            firstSegmentSeconds: 10)
        _ = seg.push(speech(3))
        let first = seg.push(silence(1.0))
        XCTAssertEqual(first.count, 1)
        let bodyA = first[0].bodyCount
        // next utterance: the second segment's offset must equal bodyA start −
        // overlap (the emitted-body clock keeps counting through early cuts)
        _ = seg.push(speech(3))
        let second = seg.push(silence(1.0))
        XCTAssertEqual(second.count, 1)
        let expectedOffset = Double(bodyA - seg.overlapSamples) / Double(sr)
        XCTAssertEqual(second[0].offset, expectedOffset, accuracy: 0.001)
        // overlap chain intact: second segment carries the 2s tail
        XCTAssertEqual(second[0].samples.count, second[0].bodyCount + seg.overlapSamples)
    }

    func testFarFieldQuietSpeechNotChopped() {
        var seg = Segmenter(sampleRate: sr, segmentSeconds: 10, overlapSeconds: 3,
                            firstSegmentSeconds: 10)
        // far-field speech: mean |x| ≈ 220 (AMI-level) — must count as VOICED
        // under the adaptive floor, so continuous quiet speech never early-cuts.
        let farSpeech = (0..<Int(6.0 * Double(sr))).map { i -> Int16 in
            i % 2 == 0 ? 220 : -220
        }
        XCTAssertTrue(seg.push(farSpeech).isEmpty)
    }
}
