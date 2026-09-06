import Foundation

/// P6 (2026-09-05): which live-session features are wired into a recording.
///
/// Both flags here were switched off by a product decision, not by a bug, and the
/// code they gate is deliberately left in place for a later redesign. Keeping the
/// decision in one named place — rather than deleting call sites — is what makes
/// "is this feature reachable from a live session?" a question with an answer.
enum LiveFeatureWiring {
    /// Translate the in-progress hypothesis (the "interim"/preview lane) as well
    /// as committed lines.
    ///
    /// OFF. Transcription keeps its own preview — the gray live text is what makes
    /// the app feel immediate, and it costs nothing but Whisper decode. Translating
    /// that text is a different trade. Measured on the 0.3.7 live session: 238
    /// interim turns against 101 committed segments, i.e. the 4B spent more of its
    /// budget on text that was going to be replaced than on text that would stay.
    /// The user sees that as words appearing and then changing — the panel logged
    /// 2,546 erasures and 2,214 revision replacements in one session — and the
    /// committed lane pays for it twice, once in queue depth and once in the GPU
    /// the interim turns hold while a committed line waits.
    ///
    /// With this off, a line is translated once, when its text has stopped moving.
    /// The caption overlay falls back to the newest committed translation, which is
    /// the behaviour it already implements for the pre-first-translation window.
    static let interimTranslation = false

    /// The rolling live-summary pane (30 s tick, previous summary + new lines).
    ///
    /// OFF pending a redesign. The rolling-carry shape works — the P4 starvation
    /// valve got it updating again — but a summary built from a live transcript
    /// inherits every transcription defect in it, and the 40-minute session it was
    /// measured on produced three generic sentences. That is a design problem, not
    /// a scheduling one, so the feature is unwired until it is redesigned rather
    /// than left running and disappointing.
    ///
    /// The post-session summary is untouched: it runs on the finished transcript
    /// with the machine to itself, which is where a summary belongs today.
    static let liveSummary = false

    /// Translate the live tail line only once the transcription preview has
    /// gone quiet — i.e. the line is really finished, not merely unchanged for
    /// two seconds while the speaker breathes.
    ///
    /// ON. With interim translation off, the tail-timeout path was the last
    /// place a translation could land on text that was still moving: the caret
    /// typed a translation under a line whose gray continuation was still
    /// growing, and the next words then invalidated it (panel revisions). The
    /// 28-word cap already closes a monologue's lines on its own, so waiting for
    /// the preview to clear costs nothing on continuous speech and removes the
    /// one remaining "translation of unfinished text" the user could see.
    static let tailTranslationWaitsForPreview = true

    /// L1 (2026-09-06): when two adjacent lines come to share a speaker after
    /// the fact (SPKFIX / AI relabel) and the first one is mid-sentence, join
    /// them live instead of leaving the fragment rows until finalize.
    ///
    /// ON. Measured on the 0.3.9 live capture: 21 % of the speaker turns the
    /// live view opened a new row for were reverted by the recluster, each one
    /// a same-speaker sentence cut in two. `static var` (not `let`) only so the
    /// capture gate can measure the same replay with the join off.
    nonisolated(unsafe) static var joinSameSpeakerNeighbors = true
    /// X1 (2026-09-07): the P15 boundary ledger records a verdict only between
    /// two SETTLED words (past the merger's holdback). Off = every first
    /// adjacency is recorded, including the held word against its own
    /// re-decode — the 0.3.18 "same speaker split at every window edge".
    nonisolated(unsafe) static var settledLedger = true
    /// X4 (2026-09-07): a one-word row followed within 0.3 s by another speaker
    /// mid-sentence adopts that speaker (label-window edge). Off = the row
    /// stays a one-word turn under the previous label.
    nonisolated(unsafe) static var turnHeadAdoption = true

    /// Paint a committed line's translation token by token while the 4B is
    /// still generating (the "typewriter"), or only once the turn completes.
    ///
    /// OFF (2026-09-07, user decision after the 0.3.16 session): the streamed
    /// text is a preview of the translation, and a preview of a translation is
    /// not something the reader can use — it changes under them, and a runaway
    /// (T7) was painted live before it could be cut. The row shows its dots
    /// until the reply is complete and sanitized, then lands once.
    static let translationStreaming = false
}
