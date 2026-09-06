import XCTest
@testable import SovereignCore

/// L1 gate (2026-09-06): replay a tee_transcribe capture's stdout (words, SPK,
/// SPKFIX — the exact stream the app saw) through TranscriptStore and measure
/// live line fragmentation with the same-speaker join OFF and ON, then against
/// the finalize regroup (the structure the saved file gets). Runs only when
/// MADI_CAPTURE_STDOUT points at a capture's stdout.log; prints the table.
///
///   MADI_CAPTURE_STDOUT=~/Library/Application\ Support/Madi/engine-capture/<dir>/stdout.log \
///     swift test --filter CaptureFragmentationGateTests
@MainActor
final class CaptureFragmentationGateTests: XCTestCase {

    struct Metrics {
        var lines = 0, sameSpeakerPairs = 0, unexplainedBreaks = 0, shortLines = 0
        var p50 = 0, p90 = 0, joins = 0
        var row: String {
            "lines \(lines)  same-spk pairs \(sameSpeakerPairs)  unexplained breaks \(unexplainedBreaks)"
            + "  words/line p50 \(p50) p90 \(p90)  ≤5-word lines \(shortLines)  joins \(joins)"
        }
    }

    private static let sentence: Set<Character> = [".", "?", "!", "。", "？", "！"]
    private static let clause: Set<Character> = [",", "，", "、", ";", "；", ":", "："]

    private func measure(_ s: TranscriptStore) -> Metrics {
        var m = Metrics(); m.lines = s.lines.count; m.joins = s.sameSpeakerJoins
        for (a, b) in zip(s.lines, s.lines.dropFirst()) where a.speaker == b.speaker {
            m.sameSpeakerPairs += 1
            let t = a.text.trimmingCharacters(in: .whitespaces)
            let last = t.last
            let wc = a.words.count
            if let l = last, Self.sentence.contains(l) { continue }
            if wc >= 16, let l = last, Self.clause.contains(l) { continue }
            if wc >= 28 { continue }
            if let t1 = a.words.last?.t1, let t0 = b.words.first?.t0, t0 - t1 >= 1.5 { continue }   // pause rule
            m.unexplainedBreaks += 1
        }
        let wcs = s.lines.map(\.words.count).sorted()
        if !wcs.isEmpty { m.p50 = wcs[wcs.count / 2]; m.p90 = wcs[min(wcs.count - 1, Int(0.9 * Double(wcs.count)))] }
        m.shortLines = wcs.filter { $0 <= 5 }.count
        return m
    }

    private func replay(_ raw: String, join: Bool) -> (live: Metrics, final: Metrics) {
        LiveFeatureWiring.joinSameSpeakerNeighbors = join
        defer { LiveFeatureWiring.joinSameSpeakerNeighbors = true }
        let s = TranscriptStore()
        let dec = EngineProtocol.Decoder()
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let ev = dec.decode(line: String(line))
            switch ev {
            case .word, .wordSectionBegin, .speaker, .speakerOverlap, .speakerOverlapReset:
                s.ingest(ev)
            case .speakerFix:
                s.ingest(ev)
                s.flushPendingSpeakerFixRebuild()
            default: break
            }
        }
        let live = measure(s)
        s.finalize()
        return (live, measure(s))
    }

    func testCaptureFragmentation() throws {
        guard let path = ProcessInfo.processInfo.environment["MADI_CAPTURE_STDOUT"] else {
            throw XCTSkip("set MADI_CAPTURE_STDOUT to a capture stdout.log")
        }
        let raw = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        let off = replay(raw, join: false)
        let on = replay(raw, join: true)
        print("CAPTURE-GATE join=off live : \(off.live.row)")
        print("CAPTURE-GATE join=on  live : \(on.live.row)")
        print("CAPTURE-GATE finalize      : \(on.final.row)")
        XCTAssertLessThanOrEqual(on.live.unexplainedBreaks, off.live.unexplainedBreaks)
        XCTAssertEqual(on.final.lines, off.final.lines, "finalize structure must not depend on the live join")
    }
}
