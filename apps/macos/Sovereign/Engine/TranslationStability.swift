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

/// P1: display policy for the caption's provisional translations.
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
            + " holds=\(stabilizerHolds)"
    }

    func reset() {
        counters = [:]
        shown = [:]
        interimTurnsRun = 0
        interimTurnsSkipped = 0
        stabilizerHolds = 0
    }
}
