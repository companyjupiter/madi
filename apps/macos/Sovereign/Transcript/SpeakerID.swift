// SpeakerID.swift — the reserved "Unknown" speaker id and its display helper.
//
// In 화자 N명 고정 (fixed-K) mode the engine routes acoustically-distant windows
// that match none of the N fixed speakers to a single Unknown bucket, emitted as
// the reserved speaker id 255 (transcribe.zig DIAR_UNK_ID — kept verbatim in
// sync). The app renders that id as "미확인" everywhere and NEVER treats it as a
// nameable/enrollable person: it stays out of speakerNames, out of the LLM
// reconciler's speaker set, and its rename/enroll affordances are disabled.

import Foundation

enum SpeakerID {
    /// Reserved id for the single Unknown (미확인) bucket. Must match
    /// transcribe.zig `DIAR_UNK_ID` (255): positive (file mode uses spk<0 for
    /// non-speech), ≥16 (clears the engine OSD `g<16` guards), ≤255 (fits the
    /// live_ids u8 clamp).
    static let unknown = 255

    /// Human label for a speaker id. "미확인" for the Unknown bucket, else the
    /// enrolled/user name, else `fallback()` (each call site keeps its own
    /// numbering convention — "Speaker N", "화자 N", 0/1-indexed).
    static func display(_ id: Int, names: [Int: String], fallback: @autoclosure () -> String) -> String {
        if id == unknown { return "미확인" }
        return names[id] ?? fallback()
    }

    /// The label used in exports and as the round-trip token for the Unknown
    /// bucket. TranscriptArchive maps this token back to `unknown` on re-import.
    static let unknownLabel = "미확인"

    // ── still-deciding labels ────────────────────────────────────────────────
    // The engine emits an acoustic margin (best−second centroid cosine) with
    // every SPK window: confident ≈ 0.4-1.0, ambiguous windows measured
    // 0.22-0.32 on the clinic fixture. Below the threshold the label is one the
    // clustering is still merging/splitting its way through, and showing a
    // NUMBER for it is what the user experiences as the speaker count climbing.
    // Show that state as itself instead.

    /// Acoustic margin at or above which a label counts as settled. Single source
    /// of truth: SessionController's LLM-relabel gate reads this same constant, so
    /// "the AI may relabel it" and "we show it as still deciding" cannot drift.
    static let settledMargin = 0.35

    /// How long a label may stay undecided before the transcript commits to the
    /// provisional number anyway. A margin does not improve on its own once the
    /// engine's recluster / SPKFIX window has moved past that audio, so without a
    /// timeout a permanently-ambiguous line would read "화자분리중…" for the rest
    /// of the session — a spinner that never resolves is worse than a best guess.
    static let undecidedTimeout = 300.0

    /// Whether a label is still genuinely being decided: the margin is unsettled
    /// AND the audio is recent enough that a revision can still arrive. `age` is
    /// how far the line sits behind the newest audio, measured on the ENGINE's
    /// clock rather than wall-clock, so a re-opened transcript reads exactly as it
    /// did live and the behaviour is deterministic in tests.
    static func isDeciding(margin: Double, age: Double) -> Bool {
        margin < settledMargin && age < undecidedTimeout
    }

    /// Live/UI label for a speaker id, with the still-deciding state made visible.
    /// Priority: Unknown → an enrolled/user-given name (a named speaker is never
    /// shown as undecided) → 화자분리중 while `isDeciding` → the stable display
    /// number, which is also what an undecided label falls back to once
    /// `undecidedTimeout` has passed.
    ///
    /// `number` is the already-resolved display number — call sites keep their own
    /// numbering convention (see `display` above), so they decide what an
    /// un-numbered id falls back to rather than having it decided here.
    static func display(_ id: Int,
                        names: [Int: String],
                        number: Int,
                        margin: Double,
                        age: Double = 0,
                        diarizing: @autoclosure () -> String,
                        fallback: (Int) -> String) -> String {
        if id == unknown { return unknownLabel }
        if let n = names[id], !n.isEmpty { return n }
        if isDeciding(margin: margin, age: age) { return diarizing() }
        return fallback(number)
    }
}
