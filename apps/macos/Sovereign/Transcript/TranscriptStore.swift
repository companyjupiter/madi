// TranscriptStore.swift — assemble engine events into a live transcript, then
// apply mid/final relabel (SPKFIX) + causal/final overlap markers (SPKOV).
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
    /// P4: translations generated from an OLDER revision of this line's text.
    /// Display-only (grayed in the panel, excluded from exports/caption): the
    /// reader keeps the old rendering until the re-translation replaces it in
    /// place, instead of watching text vanish into a loading placeholder.
    var staleTranslations: [String: String] = [:]
    var editedTranslations: Set<String> = []   // languages explicitly corrected by the user
    /// P0: languages whose translation turn was guard-suppressed at THIS text
    /// revision — no result is coming, so the status row must not keep promising
    /// one. Lifted automatically when the line's text changes (re-translation).
    var suppressedTranslations: Set<String> = []
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

    /// Per-segment AI processing state (Phase 3). DERIVED, not stored — the
    /// segment's data (words/translations) stays the single source of truth,
    /// so status can never drift out of sync with the content it describes.
    func status(activeLangs: [String], isLiveTail: Bool, translateBusy: Bool) -> SegmentStatus {
        if isLiveTail { return .transcribing }
        if translateBusy, !activeLangs.isEmpty,
           activeLangs.contains(where: { translations[$0] == nil && !suppressedTranslations.contains($0) }) {
            return .translating
        }
        return .completed
    }
}

/// Stable, process-independent content revision used to bind every async
/// translation/correction result to the exact source text that produced it.
/// Swift's `hashValue` is intentionally randomized between processes, so it is
/// unsuitable for persisted/archive-visible provenance or deterministic tests.
enum TextRevision {
    static func of(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

private struct TranslationRecord {
    var text: String
    var sourceRevision: UInt64
    var userEdited: Bool
}

private struct SpeakerLabelLookup {
    private let sorted: [SpeakerLabel]
    private let maxDur: Double

    init(_ labels: [SpeakerLabel]) {
        sorted = labels.sorted { $0.time < $1.time }
        maxDur = labels.reduce(0) { max($0, $1.dur) }
    }

    func at(_ t: Double) -> (speaker: Int, margin: Double) {
        guard !sorted.isEmpty else { return (0, 1.0) }

        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        let insertion = lo

        // Preserve the old "first sorted label containing t wins" behavior, but
        // only scan the local overlap window instead of every historical label.
        var containing: SpeakerLabel? = nil
        var i = insertion
        while i > 0 {
            i -= 1
            let l = sorted[i]
            if t - l.time > maxDur { break }
            if t >= l.time, t <= l.time + l.dur { containing = l }
        }
        if let l = containing { return (l.id, l.margin) }

        // If no label covers the word, keep the old nearest-start fallback.
        var bestIndex = min(insertion, sorted.count - 1)
        if insertion > 0 {
            let prev = insertion - 1
            if abs(sorted[prev].time - t) < abs(sorted[bestIndex].time - t) {
                bestIndex = prev
            }
        }
        return (sorted[bestIndex].id, 1.0)
    }
}

struct SpeakerShareSnapshot: Equatable {
    var speaker: Int
    var seconds: Double
    var fraction: Double
}

/// The unified per-segment model of the transcript list (Phase 3): one value
/// carries the transcription (words), speaker attribution, translations and
/// AI-processing status. `Line` is its historical name across the codebase.
typealias TranscriptSegment = Line

/// idle → transcribing → diarizing → translating → completed, per segment.
/// (.transcribing renders as the inline gray live tail; .translating as a
/// small pending-dots row where the translation will appear.)
enum SegmentStatus: Equatable {
    case transcribing   // live tail — words still arriving
    case translating    // committed, translation queued or streaming
    case completed
}

@Observable
@MainActor
final class TranscriptStore {
    /// Source of truth, updated SYNCHRONOUSLY by every event — engine callbacks,
    /// stale-guards, exports and autosave all read this and must never see a
    /// coalescing delay.
    private(set) var lines: [Line] = []

    // ── Render coalescing (Phase 1) ─────────────────────────────────────────
    // The view renders `displayLines`, a snapshot of `lines` refreshed at most
    // ~30fps. Word events and translation tokens arrive every ~19-30ms EACH;
    // publishing `lines` directly re-diffed the whole list per token, which is
    // what made row heights twitch. Views observing only `displayLines` are
    // untouched by the synchronous writes above (@Observable tracks per key).
    private(set) var displayLines: [Line] = []
    @ObservationIgnored private var renderScheduled = false
    @ObservationIgnored private var displayRevision: UInt64 = 0
    @ObservationIgnored private var energyCacheKey: EnergySnapshotCacheKey? = nil
    @ObservationIgnored private var energyCache: EnergyArc.Snapshot = .empty
    @ObservationIgnored private var speakerShareCacheRevision: UInt64? = nil
    @ObservationIgnored private var speakerShareCache: [SpeakerShareSnapshot] = []

    private struct EnergySnapshotCacheKey: Equatable {
        /// In finished/file views this is the exact display revision. During
        /// live recording it is 0, because the energy graph intentionally trails
        /// transcript edits by at most one wall second instead of rebuilding on
        /// every coalesced word burst.
        var displayRevision: UInt64
        var buckets: Int
        /// Live span is intentionally quantized to whole seconds: the right-edge
        /// mic meter still animates continuously, while the expensive transcript
        /// energy pass does not rescan a long meeting 6-10×/s during silence.
        var spanEndSecond: Int?
    }

    private func publishDisplayLines(_ newLines: [Line], invalidateEnergy: Bool) {
        displayRevision &+= 1
        displayLines = newLines
        if invalidateEnergy { energyCacheKey = nil }
    }

    /// Coalesced view refresh — many calls within a frame collapse into one
    /// `displayLines` write ~33ms later (the SwiftUI equivalent of rAF batching).
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 33_000_000)
            renderScheduled = false
            publishDisplayLines(lines, invalidateEnergy: false)
        }
    }

    /// Immediate refresh — session boundaries (reset / archive load / finalize)
    /// where a 33ms-stale frame would flash old content.
    private func flushRenderNow() {
        publishDisplayLines(lines, invalidateEnergy: true)
    }

    /// Cached side-panel energy model for live sessions. The source is
    /// `displayLines`, not raw `lines`, so word/token bursts are already
    /// coalesced before we build the relatively expensive graph snapshot.
    func displayEnergySnapshot(buckets: Int, spanEnd: Double? = nil) -> EnergyArc.Snapshot {
        let n = max(1, buckets)
        let endSecond = spanEnd.map { Int(max(0, floor($0))) }
        let key = EnergySnapshotCacheKey(displayRevision: endSecond == nil ? displayRevision : 0,
                                         buckets: n,
                                         spanEndSecond: endSecond)
        if energyCacheKey == key { return energyCache }
        let effectiveEnd = endSecond.map(Double.init) ?? spanEnd
        let snap = EnergyArc.snapshot(lines: displayLines, buckets: n, spanEnd: effectiveEnd)
        energyCacheKey = key
        energyCache = snap
        return snap
    }

    /// Cached speaking-time shares for the side panel's bar + legend. Both
    /// controls used to rescan the same long transcript independently on every
    /// SwiftUI body pass.
    func displaySpeakerShares() -> [SpeakerShareSnapshot] {
        if speakerShareCacheRevision == displayRevision { return speakerShareCache }
        var times: [Int: Double] = [:]
        for l in displayLines { times[l.speaker, default: 0] += max(0, l.end - l.start) }
        let total = max(0.001, times.values.reduce(0, +))
        speakerShareCache = times.sorted { $0.value > $1.value }.map {
            SpeakerShareSnapshot(speaker: $0.key, seconds: $0.value, fraction: $0.value / total)
        }
        speakerShareCacheRevision = displayRevision
        return speakerShareCache
    }

    /// Stable display numbers for the acoustic ids in `lines`. Engine ids churn
    /// (recluster renumbering, retroactive SPKFIX); these do not. Every user-facing
    /// speaker label goes through this — see SpeakerDisplayNumber.
    private(set) var speakerNumbers = SpeakerDisplayNumber()

    private var merger = WordMerger()
    private var spk: [SpeakerLabel] = []      // streaming
    private var spkFix: [SpeakerLabel] = []   // FLUSH
    private var spkOv: [SpeakerLabel] = []     // causal rows, replaced at FLUSH
    @ObservationIgnored private var liveLabelLookupCache: SpeakerLabelLookup? = nil

    // ── Frozen prefix (Phase 2) ─────────────────────────────────────────────
    // Lines whose audio is ≥ freezeMargin older than the newest word are
    // PROMOTED here and never regrouped again: no future word can merge into
    // them (words arrive in order; the merge window is lineBreakGap ≪ margin)
    // and streaming labels for that region have long arrived. rebuildLive then
    // regroups only the short live tail — per-word cost stops growing with
    // session length, and every frozen line's identity/boundary is literally
    // immutable, so the rendered list prefix never shifts under the reader.
    // (Mid-session SPKFIX relabels update frozen lines' speaker IN PLACE via
    // reassignFrozenSpeakers — attribute-only, boundaries stay put.)
    private var frozen: [Line] = []
    private var frozenWordCount = 0           // prefix length into merger words
    private static let freezeMargin = 6.0     // ~2 engine windows behind live

    /// Start a new line when the inter-word gap exceeds this (readability —
    /// without it a monologue renders as one giant line).
    private let lineBreakGap = 1.5

    // Overlays keyed by stable line id (= first word id). Survive the per-word
    // live rebuild and the FLUSH regroup, so an async translation that arrives
    // seconds later — or a user edit made mid-recording — still lands.
    private var translationsByLine: [UUID: [String: TranslationRecord]] = [:]
    private var editsByLine: [UUID: String] = [:]
    /// P10-3: words after which a sentence break has been taken. Keeps live line
    /// structure monotonic when a re-decode moves the punctuation.
    private var sentenceBreaks: Set<UUID> = []
    /// P0: (line, lang) pairs whose translation was guard-suppressed, keyed to the
    /// source revision the verdict applies to. A text change lifts the verdict.
    private var suppressedByLine: [UUID: [String: UInt64]] = [:]

    /// P6: stable meter key for one (line, language) translation slot.
    private static func meterKey(_ id: UUID, _ lang: String) -> String {
        "\(id.uuidString)|\(lang)"
    }

    /// Attach a per-language translation to a line by id (from TranslateEngine, async).
    @discardableResult
    func setTranslation(_ id: UUID, lang: String, _ text: String,
                        sourceRevision: UInt64? = nil, userEdited: Bool = false) -> Bool {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return false }
        let current = TextRevision.of(lines[i].text)
        guard sourceRevision == nil || sourceRevision == current else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        translationsByLine[id, default: [:]][lang] = TranslationRecord(
            text: t, sourceRevision: current, userEdited: userEdited)
        lines[i].translations[lang] = t
        lines[i].staleTranslations[lang] = nil   // P4: replaced in place
        if userEdited { lines[i].editedTranslations.insert(lang) }
        else { lines[i].editedTranslations.remove(lang) }
        TranslationStabilityMetrics.shared.recordShown(.panel, key: Self.meterKey(id, lang), text: t)
        scheduleRender()
        return true
    }

    /// Direct translation correction uses the same provenance gate as model
    /// output, but records authorship so the UI can truthfully mark it edited.
    @discardableResult
    func editTranslation(_ id: UUID, lang: String, _ text: String) -> Bool {
        setTranslation(id, lang: lang, text, userEdited: true)
    }

    /// P0: the output guard rejected this (line, lang) turn's FINAL after its
    /// partials already streamed onto the screen. Roll the provisional text back
    /// — text the guard judged invalid must not persist as if it were a
    /// translation — and remember the verdict at this source revision so the
    /// status row stops promising a result. A later text revision (which
    /// re-queues translation) lifts the verdict via applyOverlays.
    @discardableResult
    func suppressTranslation(_ id: UUID, lang: String, sourceRevision: UInt64? = nil) -> Bool {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return false }
        let current = TextRevision.of(lines[i].text)
        guard sourceRevision == nil || sourceRevision == current else { return false }
        if let record = translationsByLine[id]?[lang], record.userEdited { return false }
        if translationsByLine[id]?[lang] != nil {
            TranslationStabilityMetrics.shared.recordShown(.panel, key: Self.meterKey(id, lang), text: nil)
            translationsByLine[id]?[lang] = nil
            lines[i].translations[lang] = nil
        }
        suppressedByLine[id, default: [:]][lang] = current
        lines[i].suppressedTranslations.insert(lang)
        scheduleRender()
        return true
    }

    func sourceRevision(for id: UUID) -> UInt64? {
        lines.first(where: { $0.id == id }).map { TextRevision.of($0.text) }
    }

    func validTranslationLanguages(_ id: UUID, sourceRevision: UInt64) -> Set<String> {
        Set((translationsByLine[id] ?? [:]).compactMap { lang, record in
            record.sourceRevision == sourceRevision ? lang : nil
        })
    }

    /// Remove target languages no longer routed for this source, plus any result
    /// generated from an older source revision. Returns the still-valid keys.
    @discardableResult
    func pruneTranslations(_ id: UUID, validTargets: Set<String>, sourceRevision: UInt64) -> Set<String> {
        let previous = translationsByLine[id] ?? [:]
        // Routing changes still remove the language outright (it will not be
        // re-translated, so stale display would linger forever). P4: results
        // from an older source revision are KEPT — they surface as stale
        // display text and are replaced in place by the re-translation.
        let kept = previous.filter { validTargets.contains($0.key) }
        if kept.count != previous.count {
            for lang in previous.keys where kept[lang] == nil {
                TranslationStabilityMetrics.shared.recordShown(.panel, key: Self.meterKey(id, lang), text: nil)
            }
            translationsByLine[id] = kept
            if let i = lines.firstIndex(where: { $0.id == id }) {
                refreshTranslationOverlay(id, lineIndex: i)
            }
            scheduleRender()
        }
        return Set(kept.filter { $0.value.sourceRevision == sourceRevision }.keys)
    }

    /// Replace a line's text (inline editing, live or post). Keyed by the stable
    /// line id so the edit persists through subsequent live rebuilds.
    @discardableResult
    func editLine(_ id: UUID, _ newText: String, expectedRevision: UInt64? = nil) -> Bool {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = lines.firstIndex(where: { $0.id == id }) else { return false }
        let current = TextRevision.of(lines[i].text)
        guard expectedRevision == nil || expectedRevision == current else { return false }
        if lines[i].text == t { return true }
        editsByLine[id] = t
        lines[i].editedText = t
        invalidateTranslations(id, lineIndex: i)
        scheduleRender()
        return true
    }

    /// Replace a single word in a line (review flow). Word.text is immutable so
    /// the word is rebuilt; conf → 1.0 clears its low-confidence flag. editedText
    /// is refreshed to the new joinedText so exports/content-view stay in sync.
    @discardableResult
    func editWord(_ lineID: UUID, index: Int, to newText: String) -> Bool {
        guard let li = lines.firstIndex(where: { $0.id == lineID }),
              index >= 0, index < lines[li].words.count else { return false }
        let t = newText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let old = lines[li].words[index]
        lines[li].words[index] = Word(t0: old.t0, t1: old.t1, text: t, conf: 1.0)
        lines[li].editedText = lines[li].joinedText
        editsByLine[lineID] = lines[li].editedText
        // If the line is frozen, sync the word fix into the frozen base too —
        // otherwise the next rebuild would resurrect the old amber word.
        if let fi = frozen.firstIndex(where: { $0.id == lineID }) {
            frozen[fi].words = lines[li].words
        }
        invalidateTranslations(lineID, lineIndex: li)
        scheduleRender()
        return true
    }

    /// P4: a source-text edit no longer deletes the line's translations — the
    /// revision change reclassifies them as stale display text (grayed) until
    /// the re-translation replaces them in place.
    private func invalidateTranslations(_ id: UUID, lineIndex: Int) {
        refreshTranslationOverlay(id, lineIndex: lineIndex)
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
        guard from != into else { return }
        let target = resolvedSpeaker(into)
        speakerMerges[from] = target
        // Path compression makes chained A→B→C merges deterministic regardless
        // of command order and prevents one-hop overlays from leaking B labels.
        for (source, destination) in speakerMerges where resolvedSpeaker(destination) == target {
            speakerMerges[source] = target
        }
        // The merged pair keeps the LOWER display number, so folding 4 into 1
        // (or 1 into 4 — the direction is the clusterer's choice, not the user's)
        // never renames the speaker the user has been watching as Speaker 1.
        speakerNumbers.merge(from: from, into: target)
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
            if let ov = speakerOverrides[lines[i].id] { lines[i].speaker = resolvedSpeaker(ov) }
            else { lines[i].speaker = resolvedSpeaker(lines[i].speaker) }
        }
        scheduleRender()
    }

    private func resolvedSpeaker(_ speaker: Int) -> Int {
        var current = speaker
        var seen = Set<Int>()
        while let next = speakerMerges[current], seen.insert(current).inserted, next != current {
            current = next
        }
        return current
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
        suppressedByLine.removeAll(); sentenceBreaks.removeAll()
        speakerMerges.removeAll(); speakerOverrides.removeAll()
        speakerNumbers.reset()
        frozen.removeAll(); frozenWordCount = 0
        liveLabelLookupCache = nil
        finalized = false; diarNamespaceBroken = false
        flushRenderNow()
    }

    /// Replace the transcript with externally-parsed lines — re-opening an
    /// archived .md from the workspace explorer. This is a static view of a
    /// finished session, not a live capture, so all streaming state is cleared.
    func load(_ newLines: [Line]) {
        reset()
        lines = newLines
        // An archived transcript's ids are whatever the engine happened to mint
        // that session (sparse, gapped). Number them in file order so a re-opened
        // transcript reads as Speaker 1, 2, 3… exactly like the live one did.
        speakerNumbers.assignAll(newLines.map(\.speaker))
        for line in newLines where !line.translations.isEmpty {
            let revision = TextRevision.of(line.text)
            translationsByLine[line.id] = line.translations.mapValues {
                TranslationRecord(text: $0, sourceRevision: revision, userEdited: true)
            }
        }
        flushRenderNow()
    }

    /// Recompute one line's translation-derived fields from its records.
    /// P4: records from an older source revision are no longer DELETED here —
    /// they surface as `staleTranslations` (grayed) and are replaced in place
    /// when the re-translation for the new revision lands. The meter counts the
    /// eventual replacement (old shown text vs new) — going gray erases nothing.
    private func refreshTranslationOverlay(_ id: UUID, lineIndex i: Int) {
        let revision = TextRevision.of(lines[i].text)
        let records = translationsByLine[id] ?? [:]
        let valid = records.filter { $0.value.sourceRevision == revision }
        lines[i].translations = valid.mapValues(\.text)
        lines[i].staleTranslations =
            records.filter { $0.value.sourceRevision != revision }.mapValues(\.text)
        lines[i].editedTranslations = Set(valid.compactMap { $0.value.userEdited ? $0.key : nil })
        // P0: a suppression verdict binds to one source revision only.
        lines[i].suppressedTranslations =
            Set((suppressedByLine[id] ?? [:]).filter { $0.value == revision }.keys)
    }

    /// Re-apply id-keyed overlays after any (re)grouping.
    private func applyOverlays() {
        for i in lines.indices {
            if let e = editsByLine[lines[i].id] { lines[i].editedText = e }
            refreshTranslationOverlay(lines[i].id, lineIndex: i)
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
        case .speaker(let l):
            spk.append(l)
            liveLabelLookupCache = nil
            rebuildLive()
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
            if touched {
                liveLabelLookupCache = nil
                scheduleSpeakerFixRebuild()
            }
        case .speakerOverlap(let l):
            spkOv.append(l)
            applyOverlapSpeakers()
            scheduleRender()
        case .speakerOverlapReset:
            spkOv.removeAll()
            applyOverlapSpeakers()
            scheduleRender()
        default: break
        }
    }

    // ── P10-4: SPKFIX batch coalescing ──────────────────────────────────────
    // A mid-session recluster emits its corrections as a BURST of SPKFIX lines,
    // and each one used to run a full frozen-reassign + tail regroup — N visual
    // convulsions for one recluster ("라벨이 한꺼번에 뒤집히는" 장면). The label
    // windows themselves update synchronously above (they are data); only the
    // derived recompute is coalesced, so one recluster lands as ONE visual
    // update ~50 ms after its last label.
    @ObservationIgnored private var spkFixRebuildScheduled = false
    /// Visible recomputes actually performed for SPKFIX bursts (telemetry/tests).
    @ObservationIgnored private(set) var speakerFixRebuilds = 0
    private func scheduleSpeakerFixRebuild() {
        guard !spkFixRebuildScheduled else { return }
        spkFixRebuildScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            spkFixRebuildScheduled = false
            speakerFixRebuilds += 1
            liveLabelLookupCache = nil
            reassignFrozenSpeakers()
            rebuildFromCurrentLabels()
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
        // The one-shot full regroup below supersedes the live frozen prefix —
        // thaw so SPKFIX boundaries can reshape the whole transcript once.
        frozen.removeAll(); frozenWordCount = 0
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
        applyOverlapSpeakers()
        flushRenderNow()
    }

    private func rebuildLive() {
        let all = merger.displayWords
        // Defensive: the frozen prefix must mirror the merger's committed
        // prefix (append-only). If it ever doesn't, thaw rather than misindex.
        if frozenWordCount > all.count { frozen.removeAll(); frozenWordCount = 0 }
        var tail = group(words: Array(all[frozenWordCount...]), lookup: liveLabelLookup())
        // Promote settled tail lines. Conditions: fully older than the freeze
        // watermark; their words already in the merger's committed region (past
        // the holdback churn); and never the last line (it stays live).
        let watermark = (all.last?.t1 ?? 0) - Self.freezeMargin
        while tail.count > 1, let first = tail.first, first.end < watermark,
              frozenWordCount + first.words.count <= merger.committed.count {
            frozen.append(first)
            frozenWordCount += first.words.count
            tail.removeFirst()
        }
        lines = frozen + tail
        applyOverlays()
        applyOverlapSpeakers()
        // Mint display numbers in transcript (time) order, after the overlays have
        // resolved each line's final speaker. First speaker heard = number 1, and
        // it stays 1: assignAll only ever adds ids it has not numbered before.
        speakerNumbers.assignAll(lines.map(\.speaker))
        scheduleRender()
    }

    /// Project causal/final SPKOV rows onto every currently visible line. This
    /// is rebuilt from the compact event list so future words also inherit an
    /// overlap row that arrived before their line was materialized.
    private func applyOverlapSpeakers() {
        for i in lines.indices {
            lines[i].overlapSpeakers.removeAll(keepingCapacity: true)
            let line = lines[i]
            var seen = Set<Int>()
            for ov in spkOv where ov.id != line.speaker {
                let os = ov.time, oe = ov.time + ov.dur
                if oe > line.start, os < line.end, !seen.contains(ov.id) {
                    seen.insert(ov.id)
                    lines[i].overlapSpeakers.append(ov.id)
                }
            }
        }
    }

    /// SPKFIX touched label windows inside the frozen region: update those
    /// lines' speaker/margin IN PLACE (attribute-only — boundaries and ids are
    /// frozen; content mode re-merges adjacent same-speaker blocks anyway).
    private func reassignFrozenSpeakers() {
        guard !frozen.isEmpty else { return }
        let look = liveLabelLookup()
        for i in frozen.indices {
            let mid = (frozen[i].start + frozen[i].end) / 2
            let label = look.at(mid)
            frozen[i].speaker = label.speaker
            frozen[i].speakerMargin = label.margin
        }
    }

    /// Cached speaker/margin lookup over the live label set. Word events are far
    /// more frequent than SPK/SPKFIX rows, so the sorted index should survive
    /// across ordinary live rebuilds.
    private func liveLabelLookup() -> SpeakerLabelLookup {
        if let liveLabelLookupCache { return liveLabelLookupCache }
        let look = SpeakerLabelLookup(spk)
        liveLabelLookupCache = look
        return look
    }

    /// Group consecutive same-speaker words into lines, breaking on long pauses.
    /// Each word's speaker = the label window covering its onset.
    private func group(words: [Word], labels: [SpeakerLabel]) -> [Line] {
        guard !words.isEmpty else { return [] }
        return group(words: words, lookup: SpeakerLabelLookup(labels))
    }

    private func group(words: [Word], lookup: SpeakerLabelLookup) -> [Line] {
        guard !words.isEmpty else { return [] }
        return groupLoop(words: words, lookup: lookup)
    }

    /// A word's trailing char ends a sentence → the next word starts a new line.
    /// Guards against a lone-period false break (e.g. "3.5" ends mid-token, not
    /// with a bare "."); requires the punctuation to be the actual last char.
    private static let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
    private static func endsSentence(_ text: String?) -> Bool {
        guard let t = text?.trimmingCharacters(in: .whitespaces), let ch = t.last else { return false }
        return sentenceEnders.contains(ch)
    }

    private func groupLoop(words: [Word], lookup: SpeakerLabelLookup) -> [Line] {
        var out: [Line] = []
        for w in words.sorted(by: { $0.t0 < $1.t0 }) {
            let label = lookup.at(w.t0)
            let sp = label.speaker
            let m = label.margin
            // Break at sentence boundaries too (not just pauses): a completed
            // sentence commits as its own line so it translates ONCE and freezes,
            // instead of re-translating the whole growing monologue from the top
            // each time a word lands. (content mode re-merges these into one
            // paragraph, so reading is unchanged.)
            //
            // P10-3 split-once: a re-decode can add, drop, or move the very
            // punctuation this break was made on, which un-split and re-split
            // lines under the reader ("행이 한꺼번에 문장분리되는" churn) and reset
            // each affected line's translation. A break is therefore recorded
            // against the word it followed and honoured from then on, so live
            // line structure only ever grows.
            let tail = out.last?.words.last
            let brokenBefore = tail.map { sentenceBreaks.contains($0.id) } ?? false
            if var last = out.last, last.speaker == sp, w.t0 - last.end < lineBreakGap,
               !brokenBefore, !Self.endsSentence(last.words.last?.text) {
                last.end = max(last.end, w.t1)
                last.words.append(w)
                last.speakerMargin = min(last.speakerMargin, m)
                out[out.count - 1] = last
            } else {
                // Remember punctuation-driven breaks only. Gap/speaker breaks are
                // re-derived from timing and labels, which stay put.
                if let t = tail, Self.endsSentence(t.text) { sentenceBreaks.insert(t.id) }
                // id = first word's id → stable across rebuilds (see Line.id note)
                var line = Line(id: w.id, speaker: sp, start: w.t0, end: w.t1, words: [w])
                line.speakerMargin = m
                out.append(line)
            }
        }
        return out
    }
}
