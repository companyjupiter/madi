// TranscriptStore.swift — assemble engine events into a live transcript, then
// apply FLUSH-time relabel (SPKFIX) + overlap markers (SPKOV) for the final.
//
// Two-stage rendering mirrors the engine contract:
//   live  — words grouped into lines, each line's speaker = nearest SPK window
//   final — speakers re-assigned from SPKFIX windows; lines overlapping a SPKOV
//           window from a DIFFERENT speaker get a "⟨+Speaker N 겹침⟩" marker
//           (identical rule to the runner's relabel awk).

import Foundation
import Observation

struct Word: Identifiable {
    let id = UUID()
    let t0: Double
    let t1: Double
    let text: String
}

struct Line: Identifiable {
    let id = UUID()
    var speaker: Int
    var start: Double
    var end: Double
    var text: String
    var overlapSpeakers: [Int] = []   // from SPKOV, rendered as interruption markers
}

@Observable
@MainActor
final class TranscriptStore {
    private(set) var lines: [Line] = []

    private var words: [Word] = []
    private var spk: [SpeakerLabel] = []      // streaming
    private var spkFix: [SpeakerLabel] = []   // FLUSH
    private var spkOv: [SpeakerLabel] = []     // FLUSH overlap

    func reset() {
        lines.removeAll(); words.removeAll()
        spk.removeAll(); spkFix.removeAll(); spkOv.removeAll()
    }

    func ingest(_ event: EngineEvent) {
        switch event {
        case .word(let t0, let t1, let text):
            words.append(Word(t0: t0, t1: t1, text: text))
            rebuildLive()
        case .speaker(let l):        spk.append(l); rebuildLive()
        case .speakerFix(let l):     spkFix.append(l)
        case .speakerOverlap(let l): spkOv.append(l)
        default: break
        }
    }

    /// Called on <<FLUSH_END>>: produce the corrected, overlap-annotated transcript.
    func finalize() {
        let labels = spkFix.isEmpty ? spk : spkFix
        lines = Self.group(words: words, labels: labels)
        for i in lines.indices {
            let l = lines[i]
            var seen = Set<Int>()
            for ov in spkOv where ov.id != l.speaker {
                let os = ov.time, oe = ov.time + ov.dur
                if oe > l.start, os < l.end, !seen.contains(ov.id) {
                    seen.insert(ov.id)
                    lines[i].overlapSpeakers.append(ov.id)
                }
            }
        }
    }

    private func rebuildLive() {
        lines = Self.group(words: words, labels: spk)
    }

    /// Group consecutive same-speaker words into lines (runner's merge_seg rule,
    /// simplified): each word's speaker = the label window covering its onset.
    private static func group(words: [Word], labels: [SpeakerLabel]) -> [Line] {
        guard !words.isEmpty else { return [] }
        let sorted = labels.sorted { $0.time < $1.time }
        func speakerAt(_ t: Double) -> Int {
            // nearest window whose [time, time+dur] covers t; else nearest start
            var best = sorted.first?.id ?? 0
            var bestDist = Double.greatestFiniteMagnitude
            for l in sorted {
                if t >= l.time, t <= l.time + l.dur { return l.id }
                let d = abs(t - l.time)
                if d < bestDist { bestDist = d; best = l.id }
            }
            return best
        }

        var out: [Line] = []
        for w in words.sorted(by: { $0.t0 < $1.t0 }) {
            let sp = speakerAt(w.t0)
            if var last = out.last, last.speaker == sp {
                last.end = max(last.end, w.t1)
                last.text += separator(last.text, w.text) + w.text
                out[out.count - 1] = last
            } else {
                out.append(Line(speaker: sp, start: w.t0, end: w.t1, text: w.text))
            }
        }
        return out
    }

    /// No space before CJK/punctuation-glued tokens; space otherwise.
    private static func separator(_ prev: String, _ next: String) -> String {
        if next.first.map({ ",.!?…".contains($0) }) == true { return "" }
        return prev.isEmpty ? "" : " "
    }
}
