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
}
