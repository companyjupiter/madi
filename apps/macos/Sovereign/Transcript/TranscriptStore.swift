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

struct Word: Identifiable, Equatable {
    let id: UUID
    let t0: Double
    let t1: Double
    let text: String
    var conf: Double = 1.0   // softmax confidence of the chosen token(s); <1 = uncertain
    /// `id` defaults to a fresh UUID; WordMerger passes the HELD word's id when the
    /// next segment's re-decode replaces it, so the line that started with that
    /// word keeps its identity (P15 boundary ledger, translations, SwiftUI rows).
    init(id: UUID = UUID(), t0: Double, t1: Double, text: String, conf: Double = 1.0) {
        self.id = id; self.t0 = t0; self.t1 = t1; self.text = text; self.conf = conf
    }
}

struct Line: Identifiable, Equatable {
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
    /// P0 (2026-09-03): values views used to derive from `lines` inside their
    /// bodies — every such read subscribed the WHOLE view to the synchronous
    /// per-word / per-token writes and defeated the 30 fps coalescing above
    /// (ContentView re-evaluated per token; at ~100 lines the main thread
    /// saturated in SwiftUI layout and the session stalled). They are refreshed
    /// together with `displayLines`, so views observe only snapshot state.
    private(set) var displayLastLineID: UUID? = nil
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

    /// P2 (2026-09-03): low-confidence word refs for the review bar, cached per
    /// display revision + threshold. ContentView.body recomputed this over every
    /// word of every line — with a UserDefaults read per word — on each 30 fps
    /// snapshot (18% of the main thread at ~400 lines, live 0.3.5).
    @ObservationIgnored private var flaggedCacheKey: (revision: UInt64, threshold: Double)? = nil
    @ObservationIgnored private var flaggedCache: [(line: UUID, text: String)] = []
    func flaggedWords(threshold: Double) -> [(line: UUID, text: String)] {
        let snapshot = displayLines
        if let k = flaggedCacheKey, k.revision == displayRevision, k.threshold == threshold {
            return flaggedCache
        }
        var out: [(line: UUID, text: String)] = []
        for l in snapshot {
            for w in l.words where w.conf < threshold {
                let t = w.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append((l.id, t)) }
            }
        }
        flaggedCache = out
        flaggedCacheKey = (displayRevision, threshold)
        return out
    }

    private func publishDisplayLines(_ newLines: [Line], invalidateEnergy: Bool) {
        displayRevision &+= 1
        displayLines = newLines
        if displayLastLineID != newLines.last?.id { displayLastLineID = newLines.last?.id }
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
    // P2 (2026-09-03): the frozen lines ARE `lines[0..<frozenCount]` — no separate
    // base array. The old `lines = frozen + tail` re-copied every Line and then
    // re-applied every overlay (hashing every line's joined text) on EVERY word;
    // live 0.3.5 at ~400 lines spent ~20% of the main thread there. Mutations
    // (translations, edits, speaker fixes) already land on `lines[i]` in place, so
    // a rebuild only splices the live tail and refreshes overlays from the splice.
    private var frozenCount = 0               // frozen line prefix of `lines`
    private var frozenWordCount = 0           // prefix length into merger words
    private static let freezeMargin = 6.0     // ~2 engine windows behind live

    /// Start a new line when the inter-word gap exceeds this (readability —
    /// without it a monologue renders as one giant line).
    private let lineBreakGap = 1.5
    // P4 (2026-09-03): the gap and the sentence-ender were the ONLY break rules,
    // and a fast monologue supplies neither — Korean Whisper output routinely
    // carries no mid-utterance punctuation, and a presenter rarely pauses 1.5 s.
    // The line then grows without bound, and because `translateStableLines`
    // dispatches everything EXCEPT the last line, a growing tail line is never
    // translated while it grows; each new word also changes its revision, so any
    // translation that did land is永久 stale. Live 0.3.6 (KO→EN·日) showed a
    // committed line past 250 characters still carrying a translation of text
    // from a minute earlier. Measured over 952 lines of the user's own saved
    // transcripts (~/Documents/Madi 회의록, 8 sessions): p50 5 words / 2 s,
    // p95 20 words / 11 s, p99 41 words / 36 s, worst 1753 words and 567 s —
    // ONE line for a 9-minute stretch of a lecture. A hard cap at 28 words or
    // 14 s therefore splits 2.6 % / 2.1 % of real lines while bounding the
    // pathological case. Preferred boundary inside the window: a comma, which
    // 40 % of the long lines offer.
    private static let maxLineWords = 28
    private static let maxLineSeconds = 14.0
    private static let softLineWords = 16
    // P15 — decided-once boundary ledger. A boundary between two adjacent words
    // is evaluated exactly ONCE, the first time the pair meets at the growth
    // head, and the decision is replayed on every later rebuild. Mid-session
    // recluster (SPKFIX) flips label windows under EXISTING words; re-deriving
    // boundaries from those labels collapsed every merged speaker boundary at
    // once — 3-5 rows vanished together, translations orphaned (repro:
    // SpeakerFixStructureStabilityTests). With the ledger, SPKFIX only changes
    // the speaker SHOWN on each line; the real merge happens at finalize's
    // one-shot regroup, which bypasses the ledger (finalized == true).
    @ObservationIgnored private var breakDecided: Set<UUID> = []
    @ObservationIgnored private var breakAfter: Set<UUID> = []

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
        // P13: a replacement whose predecessor came from an OLDER source
        // revision is a REVISION (the line's text changed under it) — split out
        // in the ledger so panel churn is attributable.
        let cause: TranslationStabilityMetrics.ShowCause =
            (translationsByLine[id]?[lang]).map { $0.sourceRevision != current ? .revision : .stream }
            ?? .stream
        translationsByLine[id, default: [:]][lang] = TranslationRecord(
            text: t, sourceRevision: current, userEdited: userEdited)
        lines[i].translations[lang] = t
        lines[i].staleTranslations[lang] = nil   // P4: replaced in place
        if userEdited { lines[i].editedTranslations.insert(lang) }
        else { lines[i].editedTranslations.remove(lang) }
        TranslationStabilityMetrics.shared.recordShown(.panel, key: Self.meterKey(id, lang), text: t,
                                                       cause: cause)
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

    // ── P14: cosmetic-edit translation rebinding ────────────────────────────
    // The 2026-08-11 live session attributed 100% of panel erasure to REVISION
    // replacements, and a large class of those edits — the mid-session
    // reconcile re-decoding the same audio, glossary/punctuation normalization
    // — changes only surface form. A translation of "안녕하세요 오늘은" is not
    // invalidated by the text becoming "안녕하세요, 오늘은": re-bind the existing
    // records to the new revision instead of stale-ing them and spending DNA
    // turns re-deriving the same translation.
    private static let cosmeticChars = Set(",.!?…。、·:;'\"“”‘’()–—-«»") // punctuation only
    static func cosmeticallyEqual(_ a: String, _ b: String) -> Bool {
        materialForm(a) == materialForm(b)
    }
    private static func materialForm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }).filter { !Self.cosmeticChars.contains($0) }
    }

    /// Re-key every provenance record of `id` to the line's CURRENT revision.
    private func rebindTranslations(_ id: UUID, lineIndex i: Int) {
        let newRev = TextRevision.of(lines[i].text)
        if var records = translationsByLine[id] {
            for (lang, record) in records {
                var r = record; r.sourceRevision = newRev; records[lang] = r
            }
            translationsByLine[id] = records
        }
        if var verdicts = suppressedByLine[id] {
            for lang in verdicts.keys { verdicts[lang] = newRev }
            suppressedByLine[id] = verdicts
        }
        TranslationStabilityMetrics.shared.cosmeticRebinds += 1
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
        let cosmetic = Self.cosmeticallyEqual(lines[i].text, t)
        editsByLine[id] = t
        lines[i].editedText = t
        if cosmetic { rebindTranslations(id, lineIndex: i) }
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
        let beforeText = lines[li].text
        lines[li].words[index] = Word(t0: old.t0, t1: old.t1, text: t, conf: 1.0)
        lines[li].editedText = lines[li].joinedText
        editsByLine[lineID] = lines[li].editedText
        // (Frozen lines live in `lines` itself — the fix is already in the base.)
        // P14: a review fix that only touches punctuation/case keeps the
        // translation (confirming a word is also a common review action).
        if Self.cosmeticallyEqual(beforeText, lines[li].text) {
            rebindTranslations(lineID, lineIndex: li)
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
        joinSameSpeakerNeighbors()   // L1
    }

    /// Re-attribute one line to a different speaker (mislabel fix).
    func relabelSpeaker(lineID: UUID, to speaker: Int) {
        speakerOverrides[lineID] = speaker
        applySpeakerOverlays()
        joinSameSpeakerNeighbors()   // L1
    }

    var hasSpeakerCorrections: Bool { !speakerMerges.isEmpty || !speakerOverrides.isEmpty }

    /// Undo every AI speaker correction in one step (back to acoustic labels).
    func revertSpeakerCorrections() {
        speakerMerges.removeAll(); speakerOverrides.removeAll()
        rebuildFromCurrentLabels()
    }

    private func applySpeakerOverlays(from: Int = 0) {
        if from < lines.count {
            for i in from..<lines.count {
                if let ov = speakerOverrides[lines[i].id] { lines[i].speaker = resolvedSpeaker(ov) }
                else { lines[i].speaker = resolvedSpeaker(lines[i].speaker) }
            }
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
        breakDecided.removeAll(); breakAfter.removeAll()
        speakerMerges.removeAll(); speakerOverrides.removeAll()
        speakerNumbers.reset()
        frozenCount = 0; frozenWordCount = 0
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

    /// Test hook (TranscriptStorePerfTests): a from-scratch overlay recompute over
    /// every line, to assert the incremental (tail-only) pass left nothing stale.
    func recomputeAllOverlaysForTest() {
        applyOverlays()
        applyOverlapSpeakers()
    }

    /// Re-apply id-keyed overlays after any (re)grouping — from `from` on
    /// (rebuildLive passes the splice point; everything else defaults to all).
    private func applyOverlays(from: Int = 0) {
        guard from < lines.count else { return }
        for i in from..<lines.count {
            if let e = editsByLine[lines[i].id] { lines[i].editedText = e }
            refreshTranslationOverlay(lines[i].id, lineIndex: i)
        }
        applySpeakerOverlays(from: from)
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
            DebugLog.shared?.emit("store", "spk", ["time": l.time, "id": l.id, "margin": l.margin, "dur": l.dur])
            liveLabelLookupCache = nil
            rebuildLive()
        case .speakerFix(let l):
            // S4: mid-session recluster corrections arrive DURING recording —
            // update the live label windows in place (so earlier lines fix on
            // screen now) and buffer for finalize. At finalize the last write
            // per window wins (see dedupe there).
            spkFix.append(l)
            DebugLog.shared?.emit("store", "spkfix", ["time": l.time, "id": l.id, "margin": l.margin, "dur": l.dur])
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
            guard spkFixRebuildScheduled else { return }   // a test flushed it already
            spkFixRebuildScheduled = false
            performSpeakerFixRebuild()
        }
    }
    private func performSpeakerFixRebuild() {
        speakerFixRebuilds += 1
        liveLabelLookupCache = nil
        reassignFrozenSpeakers()
        rebuildFromCurrentLabels()
        joinSameSpeakerNeighbors()
    }
    /// Tests and offline replays: run a pending coalesced SPKFIX rebuild now
    /// instead of waiting the 50 ms.
    func flushPendingSpeakerFixRebuild() {
        guard spkFixRebuildScheduled else { return }
        spkFixRebuildScheduled = false
        performSpeakerFixRebuild()
    }

    // ── L1 (2026-09-06): join same-speaker neighbours the label churn split ──
    //
    // A boundary is decided ONCE at first adjacency (P15). At that moment the
    // newer window often carries a PROVISIONAL speaker id that the recluster
    // corrects ~24 s later with SPKFIX: measured on the 0.3.9 live capture, 23
    // of 110 initial speaker turns (21 %) were reverted to the previous speaker.
    // Each of those left a permanent line break in the middle of a sentence —
    // "It was during the pandemic, so the story goes," / "and a bunch of early
    // employees …" as separate rows of the same Speaker 1 — and a translation
    // of each fragment. The finalize regroup merged them, so the saved file was
    // fine and only the live view fragmented.
    //
    // This re-decides exactly those boundaries: when two ADJACENT lines come to
    // share a speaker (SPKFIX, an LLM relabel/merge, or a line freezing next to
    // an already-eligible neighbour) and the first line is unfinished — no
    // sentence-ending punctuation, gap under lineBreakGap, caps not hit — the
    // pair joins. Frozen pairs join in place (their words are fixed); tail pairs
    // get their ledger entry cleared so the ordinary regroup joins them. Nothing
    // else about P15 changes: finished lines keep their identity, and a boundary
    // that stays a real speaker turn is never touched. Joined text changes the
    // first line's revision, so its translation shows as stale until it is
    // re-translated once for the whole sentence — one 4B turn instead of the two
    // fragment turns it replaces.
    //
    // Deferring the first verdict while the label is provisional was measured
    // and rejected: 44 of the 87 REAL turns in the same capture also began with
    // an unsettled margin (< 0.35), so "provisional → continue" would have
    // delayed half of all real speaker changes.
    /// Boundaries re-decided so far — frozen joins plus tail ledger flips
    /// (telemetry, tests, the capture gate).
    @ObservationIgnored private(set) var sameSpeakerJoins = 0

    private func canJoin(_ a: Line, _ b: Line) -> Bool {
        guard LiveFeatureWiring.joinSameSpeakerNeighbors else { return false }
        guard a.speaker == b.speaker, a.speaker != SpeakerID.unknown,
              !a.isEdited, !b.isEdited,
              let tail = a.words.last, let head = b.words.first, let bLast = b.words.last
        else { return false }
        if Self.endsSentence(tail.text) || sentenceBreaks.contains(tail.id) { return false }
        if head.t0 - tail.t1 >= lineBreakGap { return false }
        if Self.lineIsFull(words: a.words.count, span: bLast.t1 - a.start,
                           tailEndsClause: Self.endsClause(tail.text)) { return false }
        if a.words.count + b.words.count > Self.maxLineWords { return false }
        if bLast.t1 - a.start > Self.maxLineSeconds { return false }
        // The joined row must be one the per-word rule would also have grown:
        // a clause-ender past the soft cap INSIDE `b` is where the finalize
        // regroup would cut, so joining across it would only be re-split later.
        for (k, w) in b.words.dropLast().enumerated()
        where a.words.count + k + 1 >= Self.softLineWords && Self.endsClause(w.text) { return false }
        return true
    }

    /// Join frozen line `i+1` into frozen line `i`. The survivor keeps its id
    /// (= its first word's id, what translations and edits are keyed by).
    private func joinFrozen(at i: Int) {
        let b = lines[i + 1]
        var a = lines[i]
        if let boundary = a.words.last?.id { breakAfter.remove(boundary); breakDecided.remove(boundary) }
        a.words.append(contentsOf: b.words)
        a.end = max(a.end, b.end)
        a.speakerMargin = min(a.speakerMargin, b.speakerMargin)
        for sp in b.overlapSpeakers where !a.overlapSpeakers.contains(sp) { a.overlapSpeakers.append(sp) }
        lines[i] = a
        lines.remove(at: i + 1)
        if i + 1 < frozenCount { frozenCount -= 1 }
        translationsByLine[b.id] = nil; suppressedByLine[b.id] = nil
        editsByLine[b.id] = nil; speakerOverrides[b.id] = nil
        refreshTranslationOverlay(a.id, lineIndex: i)   // survivor's records → stale (kept)
        sameSpeakerJoins += 1
        DebugLog.shared?.emit("store", "join", ["frozen": true, "speaker": a.speaker,
                                                "survivor": a.text, "joined": b.text, "start": a.start])
        scheduleRender()
    }

    /// Scan every adjacent pair: frozen pairs join in place, tail pairs get
    /// their ledger verdict cleared and the tail is regrouped once.
    func joinSameSpeakerNeighbors() {
        guard !finalized, LiveFeatureWiring.joinSameSpeakerNeighbors else { return }
        var flipped = false
        var i = 0
        while i + 1 < lines.count {
            if i + 1 < frozenCount {
                if canJoin(lines[i], lines[i + 1]) { joinFrozen(at: i); continue }
            } else if i >= frozenCount, canJoin(lines[i], lines[i + 1]), let t = lines[i].words.last,
                      breakAfter.contains(t.id) {
                breakAfter.remove(t.id); breakDecided.remove(t.id)   // re-decide with today's labels
                sameSpeakerJoins += 1
                flipped = true
                DebugLog.shared?.emit("store", "ledger-flip", ["speaker": lines[i].speaker,
                                                               "prev": lines[i].text, "next": lines[i + 1].text])
            }
            i += 1
        }
        if flipped { rebuildLive() }
    }

    /// A line just froze next to its frozen predecessor: if the pair qualifies
    /// (the SPKFIX that made them the same speaker may have landed while the
    /// newer line was still in the tail), join now.
    private func joinNewlyFrozen(promoted: Int) {
        guard promoted > 0, LiveFeatureWiring.joinSameSpeakerNeighbors else { return }
        var k = max(1, frozenCount - promoted)
        while k < frozenCount {
            if canJoin(lines[k - 1], lines[k]) { joinFrozen(at: k - 1) } else { k += 1 }
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
    /// S1: ids with enough speech on their lines to deserve a display number,
    /// in first-appearance order (so the first speaker heard stays number 1).
    private func numberableSpeakers() -> [Int] {
        var seconds: [Int: Double] = [:]
        var order: [Int] = []
        for l in lines {
            if seconds[l.speaker] == nil { order.append(l.speaker) }
            seconds[l.speaker, default: 0] += max(0, l.end - l.start)
        }
        return order.filter { (seconds[$0] ?? 0) >= SpeakerDisplayNumber.minSecondsToNumber }
    }

    func finalize() {
        DebugLog.shared?.emit("store", "finalize", ["linesBefore": lines.count, "joins": sameSpeakerJoins,
                                                    "spkfixRebuilds": speakerFixRebuilds])
        speakerNumbers.assignAll(lines.map(\.speaker))   // S1: everyone left gets a number in the saved file
        finalized = true
        // The one-shot full regroup below supersedes the live frozen prefix —
        // thaw so SPKFIX boundaries can reshape the whole transcript once.
        frozenCount = 0; frozenWordCount = 0
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
        let committedCount = merger.committed.count
        // Defensive: the frozen prefix must mirror the merger's committed
        // prefix (append-only). If it ever doesn't, thaw rather than misindex.
        if frozenWordCount > committedCount || frozenCount > lines.count {
            frozenCount = 0; frozenWordCount = 0
        }
        let tailWords = merger.displayWords(from: frozenWordCount)
        // X1: only the committed prefix of the tail is SETTLED; the held word
        // and the current segment's words are still one re-decode away.
        let tail = group(words: tailWords, lookup: liveLabelLookup(),
                         settled: merger.committed.count - frozenWordCount)
        // Promote settled tail lines. Conditions: fully older than the freeze
        // watermark; their words already in the merger's committed region (past
        // the holdback churn); and never the last line (it stays live).
        let watermark = (tailWords.last?.t1 ?? 0) - Self.freezeMargin
        let splice = frozenCount
        var promoted = 0
        while tail.count - promoted > 1, tail[promoted].end < watermark,
              frozenWordCount + tail[promoted].words.count <= committedCount {
            frozenWordCount += tail[promoted].words.count
            promoted += 1
        }
        frozenCount += promoted
        // Only the live tail is regrouped: lines before `splice` are frozen and
        // already carry their overlays (mutations land on `lines[i]` in place).
        lines.replaceSubrange(splice..<lines.count, with: tail)
        applyOverlays(from: splice)
        applyOverlapSpeakers(from: splice)
        // Mint display numbers in transcript (time) order, after the overlays have
        // resolved each line's final speaker. First speaker heard = number 1, and
        // it stays 1: assignAll only ever adds ids it has not numbered before.
        speakerNumbers.assignAll(numberableSpeakers())   // S1: ≥ minSecondsToNumber of speech
        joinNewlyFrozen(promoted: promoted)   // L1
        scheduleRender()
    }

    /// Project causal/final SPKOV rows onto every currently visible line. This
    /// is rebuilt from the compact event list so future words also inherit an
    /// overlap row that arrived before their line was materialized.
    private func applyOverlapSpeakers(from: Int = 0) {
        guard from < lines.count else { return }
        for i in from..<lines.count {
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
        guard frozenCount > 0, frozenCount <= lines.count else { return }
        let look = liveLabelLookup()
        for i in 0..<frozenCount {
            let mid = (lines[i].start + lines[i].end) / 2
            let label = look.at(mid)
            // Same resolution applyOverlays would give a regrouped line.
            lines[i].speaker = speakerOverrides[lines[i].id].map(resolvedSpeaker)
                ?? resolvedSpeaker(label.speaker)
            lines[i].speakerMargin = label.margin
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

    private func group(words: [Word], lookup: SpeakerLabelLookup, settled: Int = .max) -> [Line] {
        guard !words.isEmpty else { return [] }
        return groupLoop(words: words, lookup: lookup, settled: settled)
    }

    /// The merger's held word, if any (see WordMerger.heldWordID).
    var heldWordID: UUID? { merger.heldWordID }
    var heldWordText: String? { merger.heldWordText }
    var heldWord: Word? { merger.heldWord }
    /// Committed watermark and the committed words since `t` (PreviewTrim).
    var committedEnd: Double { merger.committedEnd }
    func committedWords(since t: Double) -> [Word] { merger.committed(since: t) }

    /// A word's trailing char ends a sentence → the next word starts a new line.
    /// Guards against a lone-period false break (e.g. "3.5" ends mid-token, not
    /// with a bare "."); requires the punctuation to be the actual last char.
    private static let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
    private static func endsSentence(_ text: String?) -> Bool {
        guard let t = text?.trimmingCharacters(in: .whitespaces), let ch = t.last else { return false }
        return sentenceEnders.contains(ch)
    }
    private static let clauseEnders: Set<Character> = [",", "，", "、", ";", "；", ":", "："]
    /// X4: a one-word row followed within `turnHeadMaxGap` by another speaker
    /// mid-sentence is the next turn's head (see groupLoop).
    static let turnHeadMaxWords = 1
    static let turnHeadMaxGap = 0.3
    private static func endsClause(_ text: String?) -> Bool {
        guard let t = text?.trimmingCharacters(in: .whitespaces), let ch = t.last else { return false }
        return clauseEnders.contains(ch)
    }

    /// P4: has this line grown past what one translation unit should carry?
    /// Pure so the thresholds are testable without a store (see
    /// TranscriptLineCapTests). `words` = the line so far, `span` = seconds from
    /// its first word to the incoming one, `tailEndsClause` = the last word
    /// carries a comma, which is the boundary we prefer once the line is long.
    static func lineIsFull(words: Int, span: Double, tailEndsClause: Bool) -> Bool {
        if words >= maxLineWords || span >= maxLineSeconds { return true }
        return words >= softLineWords && tailEndsClause
    }

    private func groupLoop(words: [Word], lookup: SpeakerLabelLookup, settled: Int) -> [Line] {
        var out: [Line] = []
        // X1 (2026-09-07): a boundary verdict is RECORDED only between two
        // settled words. The held word and the current segment's words change
        // text at the next segment boundary (the overlap re-decode replaces the
        // window-edge word, usually dropping its hallucinated period), and the
        // re-decode inherits the held word's id (P1) — so a verdict decided
        // against them outlived the text it was decided on. Unsettled
        // boundaries are still shown (decided fresh on every rebuild, like the
        // preview they are) and recorded once their words commit.
        let settledIDs: Set<UUID>? = LiveFeatureWiring.settledLedger && settled < words.count
            ? Set(words.prefix(max(0, settled)).map(\.id)) : nil
        func isSettled(_ w: Word) -> Bool { settledIDs?.contains(w.id) ?? true }
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
            // each affected line's translation. P15 generalizes it (see the
            // ledger note at breakDecided): EVERY boundary decision is made once
            // and replayed, so label rewrites can't restructure existing lines —
            // they only change which speaker a line displays.
            let tail = out.last?.words.last
            let cont: Bool
            if let last = out.last, editsByLine[last.id] != nil || editsByLine[w.id] != nil {
                // A row the user rewrote is theirs: never grown, never absorbed
                // (an unsettled tail is regrouped fresh each rebuild — X1).
                cont = false
            } else if !finalized, let t = tail, breakDecided.contains(t.id) {
                cont = !breakAfter.contains(t.id)   // replay the recorded decision
            } else {
                let brokenBefore = tail.map { sentenceBreaks.contains($0.id) } ?? false
                cont = out.last.map { last in
                    let sameSpeaker = last.speaker == sp
                    // X4 (2026-09-07): label-window edge. A word takes the label
                    // window covering its ONSET, so the first word or two of a
                    // new turn — onset still inside the previous speaker's
                    // window — opened a 1–2 word row under the wrong speaker
                    // ("I | use Claude Code", "No | one.", "Welcome | to").
                    // 0.3.18 live, 20 min: 30 of 93 speaker-change breaks left
                    // a one-word row (6 a two-word row — those read as short
                    // turns, "It was", and stay); 19 had no pause and no
                    // sentence end. A one-word row is the turn's HEAD: it
                    // adopts the new speaker below.
                    let turnHead = LiveFeatureWiring.turnHeadAdoption && !sameSpeaker &&
                        last.words.count <= Self.turnHeadMaxWords && w.t0 - last.end < Self.turnHeadMaxGap
                    return (sameSpeaker && w.t0 - last.end < lineBreakGap || turnHead) &&
                    !brokenBefore && !Self.endsSentence(last.words.last?.text) &&
                    // P4: length/duration cap — the rule that bounds a monologue
                    // when neither punctuation nor a pause ever arrives. Recorded
                    // in the P15 ledger like every other verdict, so the boundary
                    // is decided once and replayed (no re-split under the reader).
                    !Self.lineIsFull(words: last.words.count,
                                     span: w.t1 - last.start,
                                     tailEndsClause: Self.endsClause(last.words.last?.text))
                } ?? false
                if !finalized, let t = tail, isSettled(t), isSettled(w) {   // record the first-adjacency verdict
                    breakDecided.insert(t.id)
                    if !cont { breakAfter.insert(t.id) }
                    if let dbg = DebugLog.shared, let last = out.last {
                        dbg.emit("store", "boundary", [
                            "cont": cont, "prev": t.text, "next": w.text,
                            "prevSpk": last.speaker, "nextSpk": sp, "nextMargin": m,
                            "gap": w.t0 - last.end, "prevEndsSentence": Self.endsSentence(t.text),
                            "brokenBefore": brokenBefore, "prevWords": last.words.count,
                            "t0": w.t0])
                    }
                }
            }
            if var last = out.last, cont {
                // X4: a continued one-word row under another speaker is that
                // turn's head — replayed from the ledger the same way, so the
                // row's speaker is stable across rebuilds.
                if LiveFeatureWiring.turnHeadAdoption, last.speaker != sp, last.words.count <= Self.turnHeadMaxWords {
                    last.speaker = sp; last.speakerMargin = m
                }
                last.end = max(last.end, w.t1)
                last.words.append(w)
                last.speakerMargin = min(last.speakerMargin, m)
                out[out.count - 1] = last
            } else {
                // Remember punctuation-driven breaks (also honoured at finalize) —
                // settled punctuation only (X1): a window-edge period is provisional.
                if let t = tail, Self.endsSentence(t.text), isSettled(t), isSettled(w) { sentenceBreaks.insert(t.id) }
                // id = first word's id → stable across rebuilds (see Line.id note)
                var line = Line(id: w.id, speaker: sp, start: w.t0, end: w.t1, words: [w])
                line.speakerMargin = m
                out.append(line)
            }
        }
        return out
    }
}
