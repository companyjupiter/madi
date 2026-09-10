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
        /// A row whose whole text repeats the END of the previous row (1–4 words,
        /// punctuation/case-insensitive): the window-seam re-decode committed
        /// twice ("…center of that." / "that.", "Is it still 50 years?" ×2).
        var seamDuplicateRows = 0
        /// Adjacent committed WORDS with the same normalized text within 1 s —
        /// the merger let a window-seam re-decode through as a second word.
        var duplicateWords = 0
        /// Highest display number minted (S1: transient ids should not spend one).
        var maxDisplayNumber = 0
        var distinctSpeakerIDs = 0
        /// X1: a row whose first word starts BEFORE the previous row's last word
        /// ends — the held word and its re-decode shown side by side.
        var overlapRows = 0
        /// X4: a 1–2 word row followed within 0.3 s by another speaker, no
        /// sentence end — the next turn's head under the previous label.
        var turnHeadRows = 0
        /// X5: A-B-A — a row of ≤4 words under another speaker between two rows
        /// of one speaker, no sentence end and no pause on either side.
        var islandRows = 0
        /// W: adjacent rows of different speakers where the first does not end a
        /// sentence and the gap is < 0.3 s — a sentence cut by a label change.
        var midSentenceSpeakerBreaks = 0
        var row: String {
            "lines \(lines)  same-spk pairs \(sameSpeakerPairs)  unexplained breaks \(unexplainedBreaks)"
            + "  words/line p50 \(p50) p90 \(p90)  ≤5-word lines \(shortLines)  joins \(joins)"
            + "  seam-dup rows \(seamDuplicateRows)  dup words \(duplicateWords)"
            + "  ids \(distinctSpeakerIDs) maxNumber \(maxDisplayNumber)"
            + "  overlap rows \(overlapRows)  turn-head rows \(turnHeadRows)  islands \(islandRows)"
            + "  mid-sentence spk breaks \(midSentenceSpeakerBreaks)"
        }
    }

    private static func norm(_ t: String) -> String {
        t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    private static let sentence: Set<Character> = [".", "?", "!", "。", "？", "！"]
    private static let clause: Set<Character> = [",", "，", "、", ";", "；", ":", "："]

    private func measure(_ s: TranscriptStore) -> Metrics {
        var m = Metrics(); m.lines = s.lines.count; m.joins = s.sameSpeakerJoins
        if s.lines.count >= 3 {
            for i in 1..<(s.lines.count - 1) {
                let a = s.lines[i - 1], b = s.lines[i], c = s.lines[i + 1]
                guard a.speaker == c.speaker, b.speaker != a.speaker, b.words.count <= 4,
                      let at = a.words.last, let bt = b.words.last,
                      !(at.text.last.map { Self.sentence.contains($0) } ?? false),
                      !(bt.text.last.map { Self.sentence.contains($0) } ?? false),
                      b.start - a.end < 0.3, c.start - b.end < 0.3 else { continue }
                m.islandRows += 1
            }
        }
        for (a, b) in zip(s.lines, s.lines.dropFirst()) {
            guard let at = a.words.last, let bh = b.words.first else { continue }
            if bh.t0 < at.t1 - 0.05 { m.overlapRows += 1 }
            let tail = at.text.trimmingCharacters(in: .whitespaces)
            if a.speaker != b.speaker, a.words.count <= 2, bh.t0 - at.t1 < 0.3,
               !(tail.last.map { Self.sentence.contains($0) } ?? false) { m.turnHeadRows += 1 }
            if a.speaker != b.speaker, bh.t0 - at.t1 < 0.3,
               !(tail.last.map { Self.sentence.contains($0) } ?? false) { m.midSentenceSpeakerBreaks += 1 }
        }
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
        for (a, b) in zip(s.lines, s.lines.dropFirst()) where b.words.count <= 4 {
            let bt = Self.norm(b.text)
            guard !bt.isEmpty else { continue }
            let tail = Self.norm(a.words.suffix(b.words.count).map(\.text).joined(separator: " "))
            if bt == tail, (b.start - a.end) < 2.0 {
                m.seamDuplicateRows += 1
                if ProcessInfo.processInfo.environment["MADI_GATE_VERBOSE"] != nil, let al = a.words.last, let bf = b.words.first {
                    print(String(format: "  SEAMROW …%@ [%.2f-%.2f] | %@ [%.2f-%.2f] spk %d/%d", al.text, al.t0, al.t1, b.text, bf.t0, bf.t1, a.speaker, b.speaker))
                }
            }
        }
        let allWords = s.lines.flatMap(\.words)
        let lineStarts = Set(s.lines.compactMap { $0.words.first?.id })
        var shown = 0
        for (x, y) in zip(allWords, allWords.dropFirst()) {
            let nx = Self.norm(x.text), ny = Self.norm(y.text)
            if !nx.isEmpty, nx == ny, y.t0 - x.t1 < 1.0, y.t0 - x.t0 < 1.5 {
                m.duplicateWords += 1
                if shown < 10, ProcessInfo.processInfo.environment["MADI_GATE_VERBOSE"] != nil {
                    shown += 1
                    print(String(format: "  DUP %@ [%.2f-%.2f] → %@ [%.2f-%.2f] gap %.2f%@",
                                 x.text, x.t0, x.t1, y.text, y.t0, y.t1, y.t0 - x.t1,
                                 lineStarts.contains(y.id) ? "  (y starts a row)" : ""))
                }
            }
        }
        let ids = Set(s.lines.map(\.speaker))
        m.distinctSpeakerIDs = ids.count
        m.maxDisplayNumber = s.speakerNumbers.numbers.values.max() ?? 0   // ever minted, not just ids still on rows
        let wcs = s.lines.map(\.words.count).sorted()
        if !wcs.isEmpty { m.p50 = wcs[wcs.count / 2]; m.p90 = wcs[min(wcs.count - 1, Int(0.9 * Double(wcs.count)))] }
        m.shortLines = wcs.filter { $0 <= 5 }.count
        return m
    }

    private func replay(_ raw: String, join: Bool) -> (live: Metrics, final: Metrics, store: TranscriptStore) {
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
        return (live, measure(s), s)
    }

    /// Same metrics from an engine EVENTS_FILE (the app passes one every
    /// session; it survives in $TMPDIR after the session) — words + window
    /// boundaries only, no speaker labels, so it measures the word merger and
    /// the seam duplicates, not the speaker-driven breaks.
    ///   MADI_EVENTS_JSONL=/var/folders/…/madi-engine-<uuid>.events.jsonl swift test --filter CaptureFragmentationGateTests
    func testEventsSeamDuplicates() throws {
        guard let path = ProcessInfo.processInfo.environment["MADI_EVENTS_JSONL"] else {
            throw XCTSkip("set MADI_EVENTS_JSONL to an engine events file")
        }
        let raw = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        let s = TranscriptStore()
        var inSection = false
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["t"] as? String else { continue }
            switch t {
            case "word":
                if !inSection { s.ingest(.wordSectionBegin); inSection = true }
                s.ingest(.word(t0: obj["t0"] as? Double ?? 0, t1: obj["t1"] as? Double ?? 0,
                               text: obj["text"] as? String ?? "", conf: obj["conf"] as? Double ?? 1))
            case "seg_end": inSection = false
            default: break
            }
        }
        let live = measure(s)
        print("EVENTS-GATE live : \(live.row)")
        s.finalize()
        print("EVENTS-GATE final: \(measure(s).row)")
    }

    func testCaptureFragmentation() throws {
        guard let path = ProcessInfo.processInfo.environment["MADI_CAPTURE_STDOUT"] else {
            throw XCTSkip("set MADI_CAPTURE_STDOUT to a capture stdout.log")
        }
        // Lossy: a Korean session's «partial» lines carry BPE-split multibyte
        // fragments that are not valid UTF-8 (the live Decoder sees the same bytes).
        let raw = String(decoding: try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)), as: UTF8.self)
        // X5 is a per-session gate (non-English); MADI_GATE_ISLANDS=1 turns it on for a Korean capture.
        LiveFeatureWiring.speakerIslandAbsorption = ProcessInfo.processInfo.environment["MADI_GATE_ISLANDS"] == "1"
        defer { LiveFeatureWiring.speakerIslandAbsorption = false }
        // W is the same per-session gate; MADI_GATE_WEAK=<margin> turns it on for a Korean capture.
        LiveFeatureWiring.weakLabelContinuation = ProcessInfo.processInfo.environment["MADI_GATE_WEAK"].flatMap(Double.init) ?? 0
        defer { LiveFeatureWiring.weakLabelContinuation = 0 }
        let off = replay(raw, join: false)
        let on = replay(raw, join: true)
        print("CAPTURE-GATE join=off live : \(off.live.row)")
        print("CAPTURE-GATE join=on  live : \(on.live.row)")
        print("CAPTURE-GATE finalize      : \(on.final.row)")
        // X1/X4 (2026-09-07): each lever off, the other on — live rows.
        LiveFeatureWiring.settledLedger = false
        let x1off = replay(raw, join: true)
        LiveFeatureWiring.settledLedger = true
        LiveFeatureWiring.turnHeadAdoption = false
        let x4off = replay(raw, join: true)
        LiveFeatureWiring.turnHeadAdoption = true
        print("CAPTURE-GATE X1 off   live : \(x1off.live.row)")
        // MADI_GATE_DUMP=<file>: the finalized transcript text, one line per row
        // (speaker, start, text) — the input for a live-vs-reference CER check.
        if let dump = ProcessInfo.processInfo.environment["MADI_GATE_DUMP"] {
            let final = replay(raw, join: true).store
            let text = final.lines.map { String(format: "%d\t%.2f\t%@", $0.speaker, $0.start, $0.text) }.joined(separator: "\n")
            try? text.write(toFile: dump, atomically: true, encoding: .utf8)
            print("CAPTURE-GATE dumped \(final.lines.count) rows → \(dump)")
        }
        print("CAPTURE-GATE X4 off   live : \(x4off.live.row)")
        // S1: display numbers minted with immediate numbering vs the 3 s floor.
        let savedFloor = SpeakerDisplayNumber.minSecondsToNumber
        var floors: [String] = []
        for floor in [0.0, 3.0, 6.0, 10.0, 15.0] {
            SpeakerDisplayNumber.minSecondsToNumber = floor
            let r = replay(raw, join: true)
            floors.append("\(Int(floor))s→\(r.live.maxDisplayNumber)")
        }
        SpeakerDisplayNumber.minSecondsToNumber = savedFloor
        print("CAPTURE-GATE numbering (floor→max number minted, ids on rows at end \(on.live.distinctSpeakerIDs)): " + floors.joined(separator: "  "))
        XCTAssertLessThanOrEqual(on.live.unexplainedBreaks, off.live.unexplainedBreaks)
        XCTAssertEqual(on.final.lines, off.final.lines, "finalize structure must not depend on the live join")
    }
}
