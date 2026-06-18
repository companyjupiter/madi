// TranscriptStore.swift — assemble engine events into a live transcript, then
// apply FLUSH-time relabel (SPKFIX) + overlap markers (SPKOV) for the final.
//
// Word stream goes through WordMerger (overlap dedup + trailing-word holdback,
// the merge_seg.awk semantics) — without it every 3s-overlap word appears twice
// ("윈도우 윈도우 소버린 수버림"), as the first hardware GUI test showed.
//
// Two-stage rendering mirrors the engine contract:
//   live  — merged words grouped into lines, speaker = nearest SPK window
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
    var conf: Double = 1.0   // softmax confidence of the chosen token(s); <1 = uncertain
}

struct Line: Identifiable {
    let id = UUID()
    var speaker: Int
    var start: Double
    var end: Double
    var words: [Word]                 // per-word, so the view can flag low-confidence words
    var overlapSpeakers: [Int] = []   // from SPKOV, rendered as interruption markers
    var translations: [String: String] = [:]   // targetLang → text (multi-target live translation)
    /// Plain joined text (for export / SRT / Markdown).
    var text: String {
        var s = ""
        for w in words {
            if !s.isEmpty, w.text.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            s += w.text
        }
        return s
    }
}

@Observable
@MainActor
final class TranscriptStore {
    private(set) var lines: [Line] = []

    private var merger = WordMerger()
    private var spk: [SpeakerLabel] = []      // streaming
    private var spkFix: [SpeakerLabel] = []   // FLUSH
    private var spkOv: [SpeakerLabel] = []     // FLUSH overlap

    /// Start a new line when the inter-word gap exceeds this (readability —
    /// without it a monologue renders as one giant line).
    private let lineBreakGap = 1.5

    /// Attach a per-language translation to a line by id (from TranslateEngine, async).
    func setTranslation(_ id: UUID, lang: String, _ text: String) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].translations[lang] = text
    }

    func reset() {
        lines.removeAll()
        merger = WordMerger()
        spk.removeAll(); spkFix.removeAll(); spkOv.removeAll()
    }

    func ingest(_ event: EngineEvent) {
        switch event {
        case .wordSectionBegin:
            merger.segmentBreak()
            rebuildLive()
        case .word(let t0, let t1, let text, let conf):
            merger.add(Word(t0: t0, t1: t1, text: text, conf: conf))
            rebuildLive()
        case .speaker(let l):        spk.append(l); rebuildLive()
        case .speakerFix(let l):     spkFix.append(l)
        case .speakerOverlap(let l): spkOv.append(l)
        default: break
        }
    }

    /// Called on <<FLUSH_END>>: produce the corrected, overlap-annotated transcript.
    func finalize() {
        merger.finish()
        let labels = spkFix.isEmpty ? spk : spkFix
        lines = group(words: merger.committed, labels: labels)
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
        lines = group(words: merger.displayWords, labels: spk)
    }

    /// Group consecutive same-speaker words into lines, breaking on long pauses.
    /// Each word's speaker = the label window covering its onset.
    private func group(words: [Word], labels: [SpeakerLabel]) -> [Line] {
        guard !words.isEmpty else { return [] }
        let sorted = labels.sorted { $0.time < $1.time }
        func speakerAt(_ t: Double) -> Int {
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
            if var last = out.last, last.speaker == sp, w.t0 - last.end < lineBreakGap {
                last.end = max(last.end, w.t1)
                last.words.append(w)
                out[out.count - 1] = last
            } else {
                out.append(Line(speaker: sp, start: w.t0, end: w.t1, words: [w]))
            }
        }
        return out
    }
}
