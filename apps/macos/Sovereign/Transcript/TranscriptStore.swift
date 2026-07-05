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
    // Identity is the FIRST word's id — stable across the per-word live rebuild
    // (a fresh UUID() each rebuild would orphan async translations + user edits).
    var id: UUID
    var speaker: Int
    var start: Double
    var end: Double
    var words: [Word]                 // per-word, so the view can flag low-confidence words
    var overlapSpeakers: [Int] = []   // from SPKOV, rendered as interruption markers
    /// Lowest acoustic speaker-margin of the label windows covering this line
    /// (S2). < ~0.35 means "the engine wasn't sure who spoke" — the only lines
    /// the LLM reconcile pass may relabel (S3 fusion gate).
    var speakerMargin: Double = 1.0
    var translations: [String: String] = [:]   // targetLang → text (multi-target live translation)
    var editedText: String? = nil     // user edit (live or post); overrides the joined words
    /// Words joined with the engine's spacing convention.
    var joinedText: String {
        var s = ""
        for w in words {
            if !s.isEmpty, w.text.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            s += w.text
        }
        return s
    }
    /// Display / export text — the user's edit if present, else the joined words.
    var text: String { editedText ?? joinedText }
    var isEdited: Bool { editedText != nil }
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

    // Overlays keyed by stable line id (= first word id). Survive the per-word
    // live rebuild and the FLUSH regroup, so an async translation that arrives
    // seconds later — or a user edit made mid-recording — still lands.
    private var translationsByLine: [UUID: [String: String]] = [:]
    private var editsByLine: [UUID: String] = [:]

    /// Attach a per-language translation to a line by id (from TranslateEngine, async).
    func setTranslation(_ id: UUID, lang: String, _ text: String) {
        translationsByLine[id, default: [:]][lang] = text
        if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].translations[lang] = text }
    }

    /// Replace a line's text (inline editing, live or post). Keyed by the stable
    /// line id so the edit persists through subsequent live rebuilds.
    func editLine(_ id: UUID, _ newText: String) {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        editsByLine[id] = t
        if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].editedText = t }
    }

    // ── AI reconcile (speaker corrections as OVERLAYS) ──────────────────────
    // Corrections are id/speaker-keyed overlays, NOT direct mutations: every
    // .word/.speaker event rebuilds `lines` from the raw labels (rebuildLive),
    // and finalize regroups from SPKFIX — a direct mutation would be erased
    // within seconds (역검증 fusion-0). Overlays are re-applied after every
    // (re)group, exactly like translations/edits, and reverting = clearing the
    // overlays — which restores the CURRENT acoustic labels, not a stale
    // mid-session snapshot (fusion-3).
    private var speakerMerges: [Int: Int] = [:]      // from → into (LLM merge)
    private var speakerOverrides: [UUID: Int] = [:]  // line id → speaker (LLM relabel)

    /// Merge every line of speaker `from` into `into` (over-split fix).
    func mergeSpeaker(from: Int, into: Int) {
        speakerMerges[from] = into
        applySpeakerOverlays()
    }

    /// Re-attribute one line to a different speaker (mislabel fix).
    func relabelSpeaker(lineID: UUID, to speaker: Int) {
        speakerOverrides[lineID] = speaker
        applySpeakerOverlays()
    }

    var hasSpeakerCorrections: Bool { !speakerMerges.isEmpty || !speakerOverrides.isEmpty }

    /// Undo every AI speaker correction in one step (back to acoustic labels).
    func revertSpeakerCorrections() {
        speakerMerges.removeAll(); speakerOverrides.removeAll()
        rebuildFromCurrentLabels()
    }

    private func applySpeakerOverlays() {
        for i in lines.indices {
            if let ov = speakerOverrides[lines[i].id] { lines[i].speaker = ov }
            else if let mg = speakerMerges[lines[i].speaker] { lines[i].speaker = mg }
        }
    }
    /// Regroup from whatever label set currently applies (live vs finalized).
    private func rebuildFromCurrentLabels() {
        if finalized { finalize() } else { rebuildLive() }
    }
    private var finalized = false

    func reset() {
        lines.removeAll()
        merger = WordMerger()
        spk.removeAll(); spkFix.removeAll(); spkOv.removeAll()
        translationsByLine.removeAll(); editsByLine.removeAll()
        speakerMerges.removeAll(); speakerOverrides.removeAll()
        finalized = false; diarNamespaceBroken = false
    }

    /// Replace the transcript with externally-parsed lines — re-opening an
    /// archived .md from the workspace explorer. This is a static view of a
    /// finished session, not a live capture, so all streaming state is cleared.
    func load(_ newLines: [Line]) {
        reset()
        lines = newLines
    }

    /// Re-apply id-keyed overlays after any (re)grouping.
    private func applyOverlays() {
        for i in lines.indices {
            if let tr = translationsByLine[lines[i].id] { lines[i].translations = tr }
            if let e = editsByLine[lines[i].id] { lines[i].editedText = e }
        }
        applySpeakerOverlays()
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
        case .speakerFix(let l):
            // S4: mid-session recluster corrections arrive DURING recording —
            // update the live label windows in place (so earlier lines fix on
            // screen now) and buffer for finalize. At finalize the last write
            // per window wins (see dedupe there).
            spkFix.append(l)
            // 근접 매칭만: containment는 3s 오버랩으로 시간이 겹치는 이웃 창의
            // 라벨까지 뒤집는다 (역검증 watchdog-conc-7)
            var touched = false
            for i in spk.indices where abs(spk[i].time - l.time) < 0.11 {
                spk[i] = SpeakerLabel(time: spk[i].time, id: l.id, dur: spk[i].dur, margin: l.margin)
                touched = true
            }
            if touched { rebuildLive() }
        case .speakerOverlap(let l): spkOv.append(l)
        default: break
        }
    }

    /// W2 engine restart happened mid-session: the new engine's speaker ids
    /// start over and its FLUSH SPKFIX only covers the re-fed tail — using it
    /// would destroy the pre-restart labels (역검증 app-state-6). When set,
    /// finalize keeps the LIVE labels (which already absorbed mid-session
    /// fixes in place).
    private var diarNamespaceBroken = false
    func markDiarNamespaceBroken() { diarNamespaceBroken = true }

    /// Called on <<FLUSH_END>>: produce the corrected, overlap-annotated transcript.
    func finalize() {
        finalized = true
        merger.finish()
        // dedupe SPKFIX by window time keeping the LAST entry — mid-session
        // corrections are superseded by the FLUSH full re-emission.
        var lastByTime: [Int: SpeakerLabel] = [:]
        var order: [Int] = []
        for l in spkFix {
            let key = Int((l.time * 100).rounded())
            if lastByTime[key] == nil { order.append(key) }
            lastByTime[key] = l
        }
        let dedupedFix = order.compactMap { lastByTime[$0] }
        let labels = (dedupedFix.isEmpty || diarNamespaceBroken) ? spk : dedupedFix
        lines = group(words: merger.committed, labels: labels)
        applyOverlays()
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
        applyOverlays()
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

        func marginAt(_ t: Double) -> Double {
            for l in sorted where t >= l.time && t <= l.time + l.dur { return l.margin }
            return 1.0
        }

        var out: [Line] = []
        for w in words.sorted(by: { $0.t0 < $1.t0 }) {
            let sp = speakerAt(w.t0)
            let m = marginAt(w.t0)
            if var last = out.last, last.speaker == sp, w.t0 - last.end < lineBreakGap {
                last.end = max(last.end, w.t1)
                last.words.append(w)
                last.speakerMargin = min(last.speakerMargin, m)
                out[out.count - 1] = last
            } else {
                // id = first word's id → stable across rebuilds (see Line.id note)
                var line = Line(id: w.id, speaker: sp, start: w.t0, end: w.t1, words: [w])
                line.speakerMargin = m
                out.append(line)
            }
        }
        return out
    }
}
