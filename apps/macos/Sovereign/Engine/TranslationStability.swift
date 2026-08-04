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
    }

    func reset() {
        counters = [:]
        shown = [:]
        interimTurnsRun = 0
        interimTurnsSkipped = 0
    }
}
