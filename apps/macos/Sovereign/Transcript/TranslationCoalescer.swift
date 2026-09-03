import Foundation

/// P1 (2026-09-03): the translation UNIT is decoupled from the display line.
///
/// Live speech breaks into many fragment lines ("And", "So", "tools.") because the
/// transcript splits at pauses and sentence enders; each fragment used to cost a
/// full DNA turn per target (~0.5 s each), so a fast speaker with two targets
/// pushed the committed lane 20+ lines behind. A fragment carries no translatable
/// meaning on its own — it is folded into the NEXT stable line of the same speaker
/// and translated once with it; the fragment line shows no translation row (its
/// words are covered by the anchor's translation). The display split is untouched.
struct TranslationCoalescer {
    struct Input: Equatable {
        let id: UUID
        let speaker: Int
        let text: String
        let start: Double
        let end: Double
        /// P4 (2026-09-03): the clustering has not settled on this line's speaker
        /// yet (the acoustic margin is below SpeakerID.settledMargin — the same
        /// state the UI renders as "화자분리중…"). A label nobody believes must
        /// not be used to make a decision: see `runs`.
        var undecided: Bool = false
    }
    struct Run: Equatable {
        /// The line that receives the translation (last line of the run).
        let anchor: UUID
        /// Fragment lines folded into the anchor (in order), excluding the anchor.
        let members: [UUID]
        /// Joined source text sent to the engine.
        let text: String
    }

    /// A line is a fragment when it is very short and does not end a sentence,
    /// or is at most two words regardless.
    static func isFragment(_ text: String, maxWords: Int = 2, softMaxWords: Int = 3) -> Bool {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).filter { !$0.isEmpty }
        if words.isEmpty { return true }
        if words.count <= maxWords { return true }
        if words.count < softMaxWords, !endsSentence(text) { return true }
        return false
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let ch = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!。？！…".contains(ch)
    }

    /// Group stable lines into translation runs. A fragment joins the following
    /// line when it has the same speaker and starts within `maxGap` seconds of the
    /// fragment's end; a trailing fragment with no successor stays its own run.
    /// `deferTrailing`: fragments at the END of the stable set are held back (no
    /// run emitted) so they can fold into the line that follows once it
    /// stabilizes; a fragment that is followed by a speaker change or a gap is
    /// emitted alone. Pass false at finalize to flush everything.
    /// Joined source cap: DNA turns get long-input repetition past ~200 chars and
    /// the T5 example slot is capped there too. Pending fragments that would push
    /// the run past this are flushed alone first.
    static let maxJoinedChars = 220

    /// Two lines may share a run when the speaker label agrees — or when either
    /// label is still undecided. P4: live 0.3.6 ran a single presenter as 10
    /// churning ids, and every churn between two fragments forced them apart
    /// into their own DNA turns (measured on the observed 07:20–07:25 pattern:
    /// 10 turns instead of 6 for two targets). The gap and joined-length limits
    /// still bound what a run may absorb, so the worst case of joining across a
    /// real but unsettled speaker change is one short sentence of context.
    static func sameVoice(_ a: Input, _ b: Input) -> Bool {
        if a.undecided || b.undecided { return true }
        return a.speaker == b.speaker
    }

    static func runs(_ lines: [Input], maxGap: Double = 3.0, deferTrailing: Bool = false) -> [Run] {
        var out: [Run] = []
        var pending: [Input] = []   // fragments waiting for an anchor
        func pendingChars() -> Int { pending.reduce(0) { $0 + $1.text.count + 1 } }
        func flush(anchor: Input?) {
            if let a = anchor {
                let parts = pending.map(\.text) + [a.text]
                out.append(Run(anchor: a.id, members: pending.map(\.id), text: parts.joined(separator: " ")))
            } else {
                for p in pending { out.append(Run(anchor: p.id, members: [], text: p.text)) }
            }
            pending.removeAll()
        }
        for line in lines {
            let joinable = pending.last.map { Self.sameVoice($0, line) && line.start - $0.end <= maxGap } ?? true
            if !joinable { flush(anchor: nil) }
            if pendingChars() + line.text.count > Self.maxJoinedChars { flush(anchor: nil) }
            if isFragment(line.text) {
                pending.append(line)
            } else {
                flush(anchor: line)
            }
        }
        if !deferTrailing { flush(anchor: nil) }
        return out
    }
}
