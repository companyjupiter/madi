// TranslationStability.swift — display-stability instrumentation for live
// translation (P6 of the 2026-08-05 검증/역검증 batch).
//
// The user-facing complaint is "번역이 계속 적히고 교정된다": already-displayed
// translation text keeps being rewritten. The literature-standard measure is
// ERASURE (Arivazhagan et al. 2020, ICASSP — "Re-Translation Strategies for
// Long Form, Simultaneous, Spoken Language Translation"):
//
//   erasure of one update   E = |old| − |LCP(old, new)|
//   normalized erasure     NE = Σ E ÷ |final output|
//
// Reference points: vanilla re-translation ≈ NE 2.1; the accepted "low-revision"
// regime is NE < 0.2; Google Translate shipped NE ≈ 0.1 via masking+biasing with
// BLEU unchanged. This meter exists so Madi's stable-prefix display policy has a
// number instead of an impression, and so a regression is a diff in a log line.
//
// Units are grapheme clusters (Swift Character) — the only unit that behaves the
// same across KO/JA/ZH (no whitespace tokens) and EN. Deviation from the paper:
// NE is aggregated per SESSION (denominator = final committed translation chars),
// not per sentence — the ratio is comparable across builds, which is what the
// meter is for.

import Foundation

/// Prefix/erasure arithmetic shared by the meter and the display policy.
enum ErasureMath {
    /// Grapheme-cluster length of the longest common prefix of `a` and `b`.
    static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var n = 0
        var ia = a.startIndex, ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
            n += 1
            ia = a.index(after: ia)
            ib = b.index(after: ib)
        }
        return n
    }

    /// Characters of `old` the viewer watches disappear when `new` replaces it.
    static func erasure(from old: String, to new: String) -> Int {
        max(0, old.count - commonPrefixCount(old, new))
    }
}

/// P1 (superseded on the caption by P9 InterimDisplayAgreement, 2026-08-10 —
/// hold-then-accept still admits deep MT rewordings on the second verdict,
/// measured NE 1.18 vs 0.00; kept as the reference implementation and for
/// potential panel-side use): display policy for provisional translations.
///
/// Raw re-translation regenerates the WHOLE growing hypothesis every turn, so
/// consecutive candidates legitimately reword earlier text — that rewriting is
/// exactly the churn users complain about. The filter decides what is shown:
///
///   · pure growth (candidate extends the shown text)      → show it all
///   · tail divergence ≤ `tailTolerance` graphemes         → accept the rewrite
///     (the industry band allows revisions confined to the visible tail)
///   · deeper divergence                                   → FREEZE what is
///     shown; accept only after `agreementRuns` consecutive candidates
///     contradict it (LocalAgreement-style: one flip is noise, two is a
///     verdict — and bounds how long a bad early hypothesis can stick)
///
/// Shrink-to-prefix (loop-collapse, think-strip) counts as divergence: text
/// silently un-drawing is the worst-reading mutation, so it also waits for a
/// second opinion. Reset per caption window — a new sentence starts clean.
struct StablePrefixFilter {
    var tailTolerance = 12
    var agreementRuns = 2
    private var shown: [String: String] = [:]
    private var divergenceStreak: [String: Int] = [:]

    /// Feed one language's newest raw candidate; returns the text to display.
    mutating func stabilize(lang: String, candidate: String) -> String {
        let display = shown[lang] ?? ""
        if display.isEmpty || candidate.hasPrefix(display) {
            shown[lang] = candidate
            divergenceStreak[lang] = 0
            return candidate
        }
        if ErasureMath.erasure(from: display, to: candidate) <= tailTolerance {
            shown[lang] = candidate
            divergenceStreak[lang] = 0
            return candidate
        }
        let streak = (divergenceStreak[lang] ?? 0) + 1
        if streak >= agreementRuns {
            shown[lang] = candidate
            divergenceStreak[lang] = 0
            return candidate
        }
        divergenceStreak[lang] = streak
        return display
    }

    /// The language left the display (suppressed / routing change).
    mutating func remove(lang: String) {
        shown[lang] = nil
        divergenceStreak[lang] = nil
    }

    /// Window boundary — the next sentence must not be judged against this one.
    mutating func reset() {
        shown = [:]
        divergenceStreak = [:]
    }
}

/// P2: admission gate for interim caption turns. Each turn re-translates the
/// WHOLE hypothesis from scratch (0.4–1.5 s of DNA GPU), and the two interim
/// emitters (PREVIEW lane / «partial») love to flap between near-identical
/// texts — so a hypothesis that adds almost nothing since the last REQUESTED
/// turn is not worth a turn. The next real growth re-arms automatically, and a
/// gated-away tail is covered by the committed translation at window close.
enum InterimTranslateGate {
    /// Grapheme count a pure tail-extension must add to earn a turn.
    static let minDelta = 6

    static func worthTranslating(source: String, lastRequested: String,
                                 minDelta: Int = InterimTranslateGate.minDelta) -> Bool {
        guard !lastRequested.isEmpty else { return true }   // first request of the window
        if source == lastRequested { return false }         // emitter flap — nothing new
        if source.hasPrefix(lastRequested) {                // small tail growth waits
            return source.count - lastRequested.count >= minDelta
        }
        if lastRequested.hasPrefix(source) { return false } // shrunk — already covered
        return true                                         // real rewrite → translate
    }
}

/// P8: LocalAgreement-2 over the interim hypothesis stream — the SOURCE-side
/// stabilizer.
///
/// Measured 2026-08-10 (real ko1.wav × real DNA3-4B): the residual caption churn
/// after P1/P2 is dominated not by the display policy but by the preview lane
/// re-decoding the open window into a different MEANING ("아키테이였습니다" →
/// "아키텍처에 대해 이야기합니다"). Re-translating a source that changed is not
/// flicker the display layer can fix; the translation is faithfully tracking it.
///
/// So gate the source: hand the translator only the word prefix that two
/// consecutive decodes agree on (whisper_streaming's LocalAgreement-2), with the
/// surface form LOCKED at commit time so the committed text is append-only by
/// construction — the same word can never come back with different punctuation.
/// Cost is one preview cycle (~1 s) of added lag on the newest words.
///
/// Escape hatch: two emitters (PREVIEW lane / «partial») write the hypothesis,
/// and a pair that flaps between different extents could otherwise stall the
/// commit forever. After `maxStall` non-advancing hypotheses the newest tail is
/// committed outright — still append-only, because the locked prefix is kept.
struct InterimSourceGate {
    /// Non-advancing hypotheses tolerated before the newest tail is taken anyway.
    var maxStall: Int
    /// P10-2 first-paint fast path: commit the very first hypothesis of a window
    /// outright instead of waiting for a second decode to agree with it. The 0→1
    /// step is where the agreement horizon is felt as "nothing is happening" —
    /// measured on device as the dominant complaint after P8/P9 — and one
    /// unconfirmed sentence opening is a cheaper price than an empty caption.
    /// The paint is PROVISIONAL: it is shown but not committed, so it cannot
    /// poison the agreement baseline (committing it outright measured a coverage
    /// collapse — 60% → 4% — because `committed` then outran every later
    /// agreement and only the stall escape could advance it: NE 0.00 with a
    /// frozen caption is a metric win and a product loss). The provisional text
    /// yields to the first genuinely agreed prefix, which is the one revision
    /// this path trades for responsiveness.
    var fastFirst = true

    private var previous: [String] = []
    private var committed: [String] = []
    private var provisional = ""
    private var stall = 0

    // Explicit: the synthesized memberwise init is private (the state below it
    // is), so callers could not otherwise tune the stall horizon.
    init(maxStall: Int = 3, fastFirst: Bool = true) {
        self.maxStall = maxStall
        self.fastFirst = fastFirst
    }

    /// Punctuation/case are cosmetic for AGREEMENT purposes — the engine flips
    /// them between decodes ("안녕하세요." ↔ "안녕하세요") while the word is stable.
    private static func norm(_ w: String) -> String {
        w.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?…\"'")).lowercased()
    }

    /// Feed the newest hypothesis; returns the stable source to translate.
    /// The result only ever grows, and never rewrites a word it already returned.
    mutating func commit(_ hypothesis: String) -> String {
        let current = hypothesis.split(separator: " ").map(String.init)
        defer { previous = current }
        guard !previous.isEmpty else {
            // P10-2: paint the window's opening immediately, provisionally.
            if fastFirst { provisional = hypothesis }
            return provisional
        }

        var agreed = 0
        while agreed < previous.count, agreed < current.count,
              Self.norm(previous[agreed]) == Self.norm(current[agreed]) {
            agreed += 1
        }
        if agreed > committed.count {
            committed.append(contentsOf: current[committed.count..<agreed])
            stall = 0
        } else {
            stall += 1
            if stall >= maxStall, current.count > committed.count {
                committed.append(contentsOf: current[committed.count...])
                stall = 0
            }
        }
        // Until something is agreed, the provisional opening is what the viewer
        // has; the first agreed prefix then takes over permanently.
        if committed.isEmpty { return provisional }
        provisional = ""
        return committed.joined(separator: " ")
    }

    /// Window boundary — the next sentence commits from scratch.
    mutating func reset() {
        previous = []
        committed = []
        provisional = ""
        stall = 0
    }
}

/// P9: LocalAgreement-2 on the TRANSLATION output — the display-side commit.
///
/// After P8, the source is append-only, but the MT still rewords its own
/// earlier output as the source grows ("Hello. Today is cloud." →
/// "Hello. Today, we are talking about…"). Measured 2026-08-10 over four
/// language pairs (3 KO clips → EN, jfk → KO): committing to the screen only
/// the words TWO consecutive MT results agree on drives caption erasure to
/// literally zero (NE 0.00, rewrites 0 on every pair) at 61% mean end-of-window
/// coverage — the remainder arrives via the committed-lane translation that
/// already replaces the caption at window close. That is the Camp-B operating
/// point (Wordly/Interprefy: append-only, ~2-3 s behind).
///
/// Reuses InterimSourceGate's exact semantics (word agreement, surface locked
/// at commit, stall escape) — one gate per target language.
struct InterimDisplayAgreement {
    /// P10-2: show the first MT result for a window without waiting for a second
    /// one to agree. Combined with the source-side fast path this removes the
    /// compounded 0→1 delay (source cycle + MT turn) that made the caption feel
    /// dead at the start of every window.
    var fastFirst = true
    private var gates: [String: InterimSourceGate] = [:]

    init(fastFirst: Bool = true) { self.fastFirst = fastFirst }

    /// Feed one language's newest MT candidate; returns the committed text to
    /// display (append-only per language).
    mutating func feed(lang: String, candidate: String) -> String {
        var g = gates[lang] ?? InterimSourceGate(fastFirst: fastFirst)
        let shown = g.commit(candidate)
        gates[lang] = g
        return shown
    }

    /// The language left the display (suppressed / routing change).
    mutating func remove(lang: String) { gates[lang] = nil }

    /// Window boundary — the next sentence commits from scratch.
    mutating func reset() { gates = [:] }
}

/// P10-5: the responsiveness dials, resolved once per session start.
///
/// "조금만 더 빨라지면" is a tuning question, not a rebuild question — every
/// number that trades caption latency against GPU spend is settable without
/// touching code. Resolution order: environment (dev override) → UserDefaults
/// (product setting) → shipped default, clamped to a sane range.
///
///   interimGuaranteeSeconds  MADI_INTERIM_GUARANTEE_S   default 3.0  [0…10]
///       seconds between guaranteed interim turns under committed backlog
///       (0 disables the reservation). Lower = livelier caption, more GPU.
///   interimDebounceMs        MADI_INTERIM_DEBOUNCE_MS   default 300  [80…1000]
///       quiet time after a hypothesis change before a turn is considered.
///   interimMinDelta          MADI_INTERIM_MIN_DELTA     default 6    [1…30]
///       graphemes a pure tail-extension must add to earn a turn.
///
/// (The other 3-second dial, translateTailSeconds, is already a product
/// setting in 설정 → 번역 — both are meant to be adjusted together.)
enum InterimTuning {
    static func resolve(env: String, defaultsKey: String,
                        default d: Double, min lo: Double, max hi: Double,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard) -> Double {
        if let raw = environment[env], let v = Double(raw) { return Swift.min(hi, Swift.max(lo, v)) }
        if defaults.object(forKey: defaultsKey) != nil {
            return Swift.min(hi, Swift.max(lo, defaults.double(forKey: defaultsKey)))
        }
        return d
    }
    static var guaranteeSeconds: Double {
        resolve(env: "MADI_INTERIM_GUARANTEE_S", defaultsKey: "interimGuaranteeSeconds",
                default: 3.0, min: 0, max: 10)
    }
    static var debounceMs: Double {
        resolve(env: "MADI_INTERIM_DEBOUNCE_MS", defaultsKey: "interimDebounceMs",
                default: 300, min: 80, max: 1000)
    }
    static var minDelta: Int {
        Int(resolve(env: "MADI_INTERIM_MIN_DELTA", defaultsKey: "interimMinDelta",
                    default: 6, min: 1, max: 30))
    }

    /// P12 (Idea 3): the reservation adapts to committed pressure instead of
    /// firing blindly every N seconds — under a deep backlog the caption's
    /// guaranteed slot is what pushes committed lines into the shed path.
    /// backlog ≤2 → base interval; ≤6 → 2× base; deeper → reservation off
    /// (ordinary admission still applies when the lane goes quiet). Returns nil
    /// for "no reservation right now".
    static func adaptiveGuarantee(base: Double, committedBacklog: Int) -> Double? {
        guard base > 0 else { return nil }
        if committedBacklog <= 2 { return base }
        if committedBacklog <= 6 { return base * 2 }
        return nil
    }
}

/// P12 (Idea 1): sentence-scoped interim translation.
///
/// Each interim turn used to re-translate the WHOLE agreed prefix — by the end
/// of a window that is a 60-80 token prefill every ~3s, and under the P10-1
/// reservation that cost comes straight out of the committed lane (measured on
/// device: caption work can take 30-40% of engine time in continuous speech).
/// The P9 display is append-only anyway, so a sentence that has COMPLETED
/// inside the agreed source never changes again on screen: translate it once,
/// freeze its translation, and from then on spend turns only on the OPEN
/// sentence — a 10-30 token turn instead of the whole window.
///
/// (Sentence-freeze was refuted for DISPLAY in the 2026-08-10 sweep because
/// boundary rewrites leaked to screen; the display-side agreement gate P9 now
/// filters exactly those, so the refutation no longer applies — re-measured in
/// the same harness before wiring.)
struct InterimSentenceLedger {
    static let enders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]

    /// Split an agreed source prefix into completed sentences + the open tail.
    static func split(_ source: String) -> (completed: [String], current: String) {
        var completed: [String] = []
        var cur = ""
        for ch in source {
            cur.append(ch)
            if enders.contains(ch) {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { completed.append(t) }
                cur = ""
            }
        }
        return (completed, cur.trimmingCharacters(in: .whitespaces))
    }

    private(set) var sentences: [String] = []

    /// Feed the newest agreed source; returns sentences that JUST completed
    /// (each needs exactly one translation turn) and the open tail. The
    /// completed list only ever grows — the source gate is append-only, so a
    /// sentence that completed can never un-complete.
    mutating func advance(source: String) -> (newlyCompleted: [String], current: String) {
        let (completed, current) = Self.split(source)
        guard completed.count > sentences.count else { return ([], current) }
        let fresh = Array(completed[sentences.count...])
        sentences = completed
        return (fresh, current)
    }

    mutating func reset() { sentences = [] }
}

/// Session-scoped erasure counters for the two translation surfaces.
///
///   .caption — the floating caption overlay's provisional interim translations
///              (keyed by target language)
///   .panel   — committed per-line translations in the transcript panel
///              (keyed by "lineID|lang")
///
/// Every visible mutation goes through `recordShown`; a provisional text that is
/// superseded by an authoritative replacement at a session/window boundary is
/// dropped via `closeCaption()` WITHOUT counting (that replacement is the final,
/// not flicker). The summary line prints at session finalize and reset.
@MainActor
final class TranslationStabilityMetrics {
    static let shared = TranslationStabilityMetrics()

    enum Surface: String, CaseIterable {
        case caption, panel
    }

    struct Counters {
        var erasedChars = 0
        var updates = 0    // recordShown calls that changed the text
        var rewrites = 0   // updates with erasure > 0 (what the eye registers)
    }

    private(set) var counters: [Surface: Counters] = [:]
    private var shown: [Surface: [String: String]] = [:]

    /// P2 telemetry: interim DNA turns actually spent vs gated away.
    var interimTurnsRun = 0
    var interimTurnsSkipped = 0
    /// P1 telemetry: candidates the stable-prefix filter held back (each one
    /// was a whole-prefix rewrite the viewer did NOT see).
    var stabilizerHolds = 0
    /// P8 telemetry: hypothesis characters withheld from the translator because
    /// two consecutive decodes had not yet agreed on them.
    var sourceHeldChars = 0

    // ── P10-0: the LATENCY axis ────────────────────────────────────────────
    // Stability and responsiveness trade against each other — P8/P9 drove
    // caption erasure to zero and made the app feel SLOWER, which the erasure
    // meter alone could not show. From now on every translation change records
    // both, so a win on one axis can never hide a regression on the other.

    /// Monotonic clock; injectable so tests are deterministic.
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    enum Timing: String, CaseIterable {
        /// Per TURN: engine request → that turn's first text on screen.
        case turnTTFT
        /// Per WINDOW: first interim hypothesis char → first caption paint.
        case captionFirstPaint
        /// Per LINE: line becomes translatable → its first translation shown.
        case lineFirstTranslation
    }
    private(set) var samples: [Timing: [Double]] = [:]
    private var startedAt: [Timing: [String: Double]] = [:]

    /// Open a stopwatch for `key`; a second start for a live key is ignored so
    /// re-arming (debounce, retry) cannot reset an already-running measurement.
    func markStart(_ t: Timing, key: String) {
        guard startedAt[t, default: [:]][key] == nil else { return }
        startedAt[t, default: [:]][key] = now()
    }
    /// Close the stopwatch for `key`. No-op when it was never started or when
    /// it already fired — first paint is what we measure, not every repaint.
    func markEnd(_ t: Timing, key: String) {
        guard let s = startedAt[t]?[key] else { return }
        startedAt[t]?[key] = nil
        samples[t, default: []].append(now() - s)
    }
    /// The measurement no longer applies (window closed, line dropped).
    func cancel(_ t: Timing, key: String) { startedAt[t]?[key] = nil }
    func cancelAll(_ t: Timing) { startedAt[t] = [:] }

    private func pct(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[i]
    }
    /// "median/p95 ms (n)" for one timing, or "—" when nothing was measured.
    func latencySummary(_ t: Timing) -> String {
        let xs = samples[t, default: []]
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.0f/%.0fms(n=%d)", pct(xs, 0.5) * 1000, pct(xs, 0.95) * 1000, xs.count)
    }

    /// `text == nil` means the key was removed from screen (counts as full erase
    /// of what was shown). Identical text is a no-op.
    func recordShown(_ surface: Surface, key: String, text: String?) {
        let old = shown[surface, default: [:]][key]
        if let text, !text.isEmpty {
            guard old != text else { return }
            var c = counters[surface, default: Counters()]
            c.updates += 1
            if let old {
                let e = ErasureMath.erasure(from: old, to: text)
                c.erasedChars += e
                if e > 0 { c.rewrites += 1 }
            }
            counters[surface] = c
            shown[surface, default: [:]][key] = text
        } else if let old {
            var c = counters[surface, default: Counters()]
            c.updates += 1
            c.rewrites += 1
            c.erasedChars += old.count
            counters[surface] = c
            shown[surface]?[key] = nil
        }
    }

    /// Window/session boundary: the caption's provisional text was replaced by
    /// the committed translation (the final). Forget without counting.
    func closeCaption() {
        shown[.caption] = [:]
    }

    /// NE denominator: what the panel currently shows is the session's final
    /// output once translation has drained.
    var finalPanelChars: Int {
        shown[.panel, default: [:]].values.reduce(0) { $0 + $1.count }
    }

    func summary() -> String {
        let finals = finalPanelChars
        func part(_ s: Surface) -> String {
            let c = counters[s, default: Counters()]
            let ne = finals > 0 ? String(format: "%.2f", Double(c.erasedChars) / Double(finals)) : "—"
            return "\(s.rawValue) NE=\(ne) erased=\(c.erasedChars) updates=\(c.updates) rewrites=\(c.rewrites)"
        }
        return "[translate-stability] \(part(.caption)) | \(part(.panel))"
            + " | finalChars=\(finals) interimTurns=\(interimTurnsRun) gated=\(interimTurnsSkipped)"
            + " holds=\(stabilizerHolds) srcHeld=\(sourceHeldChars)"
            + " | ttft=\(latencySummary(.turnTTFT))"
            + " firstPaint=\(latencySummary(.captionFirstPaint))"
            + " lineTr=\(latencySummary(.lineFirstTranslation))"
    }

    /// Sessions launched from the Dock have no readable stdout — the ledger
    /// line is ALSO appended to App Support/Madi/stability.log, so a
    /// measurement exists no matter how the app was started or stopped.
    func flushSummary(_ tag: String, directory: URL? = nil) {
        let line = summary() + " " + tag
        print(line)
        fflush(stdout)
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Madi", isDirectory: true)
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stability.log")
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(stamped.utf8))
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }

    func reset() {
        counters = [:]
        shown = [:]
        interimTurnsRun = 0
        interimTurnsSkipped = 0
        stabilizerHolds = 0
        sourceHeldChars = 0
        samples = [:]
        startedAt = [:]
    }
}
