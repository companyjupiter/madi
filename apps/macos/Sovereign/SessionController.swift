// SessionController.swift — orchestrates the live transcription session:
// AudioCapture → EngineProcess → TranscriptStore. Owns the state machine the
// UI binds to. This is the "live_transcribe.sh" logic re-homed in Swift, minus
// ffmpeg (native capture) and minus awk (TranscriptStore).

import Foundation
import Observation
import CoreAudio
import CoreGraphics
import AVFoundation
import AppKit

@Observable
@MainActor
final class SessionController: EngineProcessDelegate {
    enum Phase: Equatable {
        case idle, countingDown(Int), engineStarting, ready, recording, paused, processing, flushing, done
        case error(String)
    }

    private(set) var phase: Phase = .idle

    /// Session-level AI pipeline state (Phase 4):
    /// idle → listening → transcribing → diarizing → translating → completed/error.
    /// One DERIVED state machine over the existing signals — the single source
    /// the status line (and any future badge) renders from, so every surface
    /// agrees on "what the AI is doing right now". Priority mirrors severity:
    /// reconcile > file transcription > translation backlog(shed) > live translation
    /// queue > live transcription > post-stop backfill.
    enum PipelineState: Equatable {
        case idle
        case listening                    // recording, no audio in flight
        case transcribing                 // recording, segments decoding
        case fileTranscribing(Int?)       // file mode, optional % done
        case diarizing                    // AI speaker/language reconcile pass
        case correcting(Int)              // N forced-language line decodes remain
        case translating(Int)             // N lines queued (live)
        case translatingBacklogged(Int)   // live queue shed N lines under load — filled at stop
        case completed
        case backfilling(Int)             // post-stop: N shed lines still being re-translated
        case error(String)
    }

    var pipeline: PipelineState {
        if case .error(let e) = phase { return .error(e) }
        if languageCorrectionsPending > 0 { return .correcting(languageCorrectionsPending) }
        if reconciling { return .diarizing }
        if case .processing = phase {
            return .fileTranscribing(chunksTotal > 0
                ? Int(Double(chunksDone) / Double(chunksTotal) * 100) : nil)
        }
        // P1: the status shows LINES, not turns (two targets doubled the number).
        if translateBacklog > 0 { return .translatingBacklogged(max(translateQueuedLines, min(translateQueueDepth, 1))) }
        if translateQueueDepth > 0 { return .translating(max(translateQueuedLines, 1)) }
        if phase == .recording {
            if micSilent { return .idle }        // the silence WARNING covers this
            return segmentsInFlight > 0 ? .transcribing : .listening
        }
        if phase == .done {
            if backfillRemaining > 0 { return .backfilling(backfillRemaining) }
            return .completed
        }
        return .idle
    }
    var level: Float = 0
    /// Peak-hold version of `level` for the live meter: instant attack, ~0.5s
    /// release. Because the UI samples only a few times a second, reading the raw
    /// `level` kept catching the quiet gaps between words (meter looked dead);
    /// holding the recent peak makes each sample land on real speech energy.
    private(set) var meterLevel: Float = 0
    private var lastMeterAt = Date()

    // Wall-clock recording timer for the 총 시간 readout — paused spans are
    // subtracted so it counts RECORDED time, matching what lands in the file.
    private(set) var recordStartedAt: Date? = nil
    private var recordEndedAt: Date? = nil
    private var pausedAt: Date? = nil
    private var pausedAccum: TimeInterval = 0
    var recordedSeconds: TimeInterval {
        guard let s = recordStartedAt else { return 0 }
        let end = recordEndedAt ?? Date()
        let inPause = pausedAt.map { end.timeIntervalSince($0) } ?? 0
        return max(0, end.timeIntervalSince(s) - pausedAccum - inPause)
    }
    let transcript = TranscriptStore()
    /// Local Calendar glue — prefills the meeting title/attendees and matches
    /// speakers to attendees after the session (read-only, on-device).
    let calendar = CalendarBridge()
    /// v1 release: calendar-driven prep brief OFF — cut for launch-scope focus,
    /// and so first-run never shows a calendar-permission dialog for an
    /// invisible feature. Guards the pipeline's single entry point in start().
    static let calendarPrepEnabled = false
    /// Click-to-play: seeks the original media to a line's moment. Only armed for
    /// file-transcribed sessions, where the source file + its timeline persist.
    let linePlayer = LinePlayer()
    /// The original media a file transcription came from (nil for live recordings
    /// and re-opened archives). Backs click-to-play.
    private(set) var sourceMediaURL: URL?

    /// Play the audio span of a transcript line (file-transcribed sessions only).
    func playLine(_ line: Line) {
        guard let url = sourceMediaURL else { return }
        linePlayer.toggle(url: url, line: line.id, from: line.start, to: line.end)
    }

    /// Always-on-top live-translation caption overlay (floats over the call app).
    private let captionOverlay = CaptionOverlayController()
    private(set) var captionOverlayOn = false
    /// Persisted caption sizing / patient-panel config (clinic display batch).
    var captionSettings = CaptionSettings.load() {
        didSet { captionSettings.save(); if captionOverlayOn { refreshCaptionOverlay() } }
    }
    func toggleCaptionOverlay() {
        captionOverlayOn.toggle()
        if captionOverlayOn { refreshCaptionOverlay() } else { captionOverlay.hide() }
    }
    private func refreshCaptionOverlay() {
        // staff caption (main screen) + optional large patient panel (external).
        captionOverlay.show(staff: CaptionView(session: self, audience: .staff) { [weak self] in self?.hideCaptionOverlay() },
                            patient: captionSettings.patientPanelEnabled ? CaptionView(session: self, audience: .patient) : nil,
                            settings: captionSettings)
    }
    private func hideCaptionOverlay() { captionOverlayOn = false; captionOverlay.hide() }

    // ── clinic display state exposed to the caption/transcript views ─────────
    /// The (line, language) whose translation is CURRENTLY streaming in — drives
    /// the typing caret (A7). Set on the first diverged partial, cleared on the
    /// final result. Struct so SwiftUI diffs it cheaply.
    // ── BETA feature gates (0.9.0-beta) ─────────────────────────────────────
    // Incomplete features are UNWIRED for the public beta rather than deleted:
    // their code stays (views, stores, engine flags) but nothing reaches it, so
    // re-enabling post-beta is a one-line flip once the feature is fixed.
    //
    // Voiceprints (사람 지문): enrollment can't be undone, cross-session matching
    // misidentifies speakers. OFF ⇒ no VOICEPRINTS/DIAR_ANCHOR to the engine (no
    // load, no centroid dump, no SPKNAME auto-naming), no .vec written on rename.
    // Renaming a speaker still works — it just stays local to the transcript.
    static let voiceprintsEnabled = false
    // Editor analysis (편집: 무음·필러·타이튼·리테이크·하이라이트·챕터 — all share
    // the one `EditorSettings.enabled` master gate). OFF ⇒ no cut/chapter analysis
    // and the editor Settings tab + its exports are hidden.
    static let editorFeaturesEnabled = false

    struct TranslationRef: Equatable { let id: UUID; let lang: String }
    private struct TranslationWorkKey: Hashable {
        let id: UUID
        let lang: String
        let sourceRevision: UInt64
    }
    private(set) var streamingTranslation: TranslationRef?
    /// Pending translation turns (queued + in-flight) — the "N줄 대기" status (D20).
    private(set) var translateQueueDepth = 0
    /// P1: distinct lines queued/in flight (the number the status line shows).
    private(set) var translateQueuedLines = 0
    /// P1 coalescing: anchor line id → joined source text sent to the engine, and
    /// the anchor's own text revision at dispatch (setTranslation's gate).
    private var coalescedSource: [UUID: String] = [:]
    private var coalescedRevision: [UUID: UInt64] = [:]
    /// P1 preview time-slice + STT telemetry.
    private var lastPreviewAdmitAt: Date = .distantPast
    private var previewAdmits = 0
    /// P6: the engine's own diagnostic lines, folded into counters for the log.
    private var engineDiag = EngineDiagnostics()
    private var previewLaneStartedAt: Date? = nil
    private var previewAgingTimer: Timer? = nil
    private var sttTurnarounds: [Double] = []
    /// Max live translation queue depth (turns). The 8 GB realtime profile keeps
    /// only a four-turn horizon; larger systems retain the legacy 30-turn buffer.
    /// Superseded revisions are coalesced before this cap and never backfilled.
    private static func liveTranslateCap(for variant: TranslateModelVariant) -> Int {
        variant == .realtime2B ? 4 : 30
    }
    /// Upper bound on a live PREVIEW (interim) string. A real ~10s recognition
    /// window holds well under this in any language; a value beyond it is a
    /// run-on-hallucination balloon, dropped so it never flashes on the caption
    /// or gets interim-translated (the clean committed line still lands).
    private static let maxLivePartialChars = 512
    /// Lines the live queue shed (translation deferred to stop) — the "N줄은 종료
    /// 후 채움" HUD signal, and the backfill worklist finalize drains.
    private var backlogKeys: Set<TranslationWorkKey> = []
    private(set) var translateBacklog = 0
    /// Post-stop backfill in progress: lines still being re-translated after the
    /// live cap shed them. Drives the ".done · 채우는 중 N줄" HUD, and gates the
    /// Shared DNA broker serves these ahead of post-session summary work.
    private var backfillPendingKeys: Set<TranslationWorkKey> = []
    private(set) var backfillRemaining = 0
    /// Wall-clock of the last committed line — the commit-cadence ring reads it
    /// against effectiveWindowSeconds to show progress toward the next commit (D19).
    private(set) var lastCommitAt = Date()
    /// The patient-facing caption language: explicit override, else the non-Korean
    /// side of the translate pair, else the first target.
    var patientCaptionLang: String? {
        if let o = captionSettings.patientLangOverride { return o }
        let nonKo = translateTargets.subtracting(["Korean"]).sorted()
        return nonKo.first ?? translateTargets.sorted().first
    }

    // ── live action rail scheduling ──
    /// Start the throttled extraction loop for a live recording (no-op unless the
    /// machine is ≥16 GB AND the toggle is on). Resets the rail for the new session.
    private func startLiveRail() {
        liveRailTimer?.invalidate(); liveRailTimer = nil
        guard Self.liveRailCapable, liveRailEnabled else { return }
        liveRailItems = []; liveRailLastCount = 0; liveRailBusy = false; liveRailBusyTicks = 0
        liveRailProgressAt = Date(); liveRailStarvedAdmits = 0
        liveRailTimer = Timer.scheduledTimer(withTimeInterval: 18, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLiveRail() }
        }
    }

    /// One extraction pass: only while recording, only when ≥3 new lines landed and
    /// no pass is in flight (so the DNA3 GPU spike stays brief + non-overlapping).
    private func tickLiveRail() {
        guard phase == .recording, liveRailEnabled, Self.liveRailCapable else { return }
        // P11: rail is periodic background analysis — it yields to the caption
        // lane. P4: but "yield" must not mean "never" — a caption lane that is
        // busy for the whole session starved this lane exactly like the summary
        // pane. Same valve, same broker ordering (rail sits below both captions).
        let railIdle = Date().timeIntervalSince(liveRailProgressAt)
        guard BackgroundLaneAdmission.admits(queueDepth: translateQueueDepth,
                                             backlog: translateBacklog,
                                             secondsSinceProgress: railIdle) else { return }
        if translateQueueDepth > 0 || translateBacklog > 0 { liveRailStarvedAdmits += 1 }
        if liveRailBusy {
            // No reply after ~2 ticks (≈36s) ⇒ the engine stalled/died — unwedge.
            liveRailBusyTicks += 1
            if liveRailBusyTicks >= 2 { liveRailBusy = false; liveRailBusyTicks = 0 }
            return
        }
        guard transcript.lines.count >= liveRailLastCount + 3 else { return }
        liveRailLastCount = transcript.lines.count
        guard let s = ensureSummaryEngine() else { return }
        liveRailBusy = true; liveRailBusyTicks = 0
        liveRailProgressAt = Date()
        s.extractActions(lines: attributedLines)
    }

    private func stopLiveRail() {
        liveRailTimer?.invalidate(); liveRailTimer = nil
        liveRailBusy = false; liveRailBusyTicks = 0
        // Invalidating the timer stops NEW extractions; anything already handed
        // to the broker still holds a .liveRail slot that outranks the
        // post-session summary lane. Drop it — the meeting is over.
        summaryEngine?.cancelQueued()
    }

    // ── live rolling summary (우측 요약 탭) ──
    // Forked from the live-rail scheduler above (per-feature fork, not shared) —
    // same no-degradation envelope, laxer cadence: LiveSummary.tickSeconds (30 s)
    // and minNewLines (6) vs the rail's 18 s / 3, and the LOWEST broker lane.

    /// Start the rolling-summary loop for a live recording. Same ≥16 GB gate as
    /// the rail: the machines it admits always run the 4B (12 GB model-tier
    /// boundary), the only model the live prompt was probed healthy on.
    private func startLiveSummary() {
        liveSummaryTimer?.invalidate(); liveSummaryTimer = nil
        guard LiveFeatureWiring.liveSummary else { return }
        guard Self.liveRailCapable, liveSummaryEnabled else { return }
        liveSummaryText = nil; liveSummaryUpdatedAt = nil
        liveSummaryLastCount = 0; liveSummaryWindowStart = 0
        liveSummaryBusy = false; liveSummaryBusyTicks = 0
        liveSummaryProgressAt = Date()          // P4: starvation clock starts here
        liveSummaryStarvedAdmits = 0; liveSummarySkippedTicks = 0
        liveSummaryTimer = Timer.scheduledTimer(withTimeInterval: LiveSummary.tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLiveSummary() }
        }
    }

    /// One rolling update: only while recording, only when the caption lane is
    /// idle (P11 — the broker's aging valve is the second line of defense), only
    /// when enough NEW lines landed, one request in flight. The request carries
    /// the previous summary + just the new lines (rolling carry), so old
    /// transcript text never re-enters the live loop.
    private func tickLiveSummary() {
        guard phase == .recording, liveSummaryEnabled, Self.liveRailCapable else { return }
        // P4: idle fast path + starvation valve. A permanently-busy caption lane
        // used to freeze this pane for the whole session (live 0.3.6 KO→EN·日:
        // no update between 00:01:24 and 00:10:23). See BackgroundLaneAdmission.
        let summaryIdle = Date().timeIntervalSince(liveSummaryProgressAt)
        guard BackgroundLaneAdmission.admits(queueDepth: translateQueueDepth,
                                             backlog: translateBacklog,
                                             secondsSinceProgress: summaryIdle) else {
            liveSummarySkippedTicks += 1
            return
        }
        if translateQueueDepth > 0 || translateBacklog > 0 { liveSummaryStarvedAdmits += 1 }
        if liveSummaryBusy {
            // Unwedge after ~4 ticks (≈120 s) — past the broker's 90 s aging
            // valve. But a long wait is usually a QUEUE (e.g. dozens of serial
            // mid-session reconcile parts share this .postSession lane), not a
            // dead engine — the request will still answer eventually. So on
            // unwedge, ROLL THE WATERMARK BACK to where that request's window
            // began: the retry re-sends the accumulated window, and since lane
            // replies arrive FIFO the retry's (superset) reply lands last —
            // nothing said in the stuck window can silently drop out of the
            // rolling summary (review finding).
            liveSummaryBusyTicks += 1
            if liveSummaryBusyTicks >= 4 {
                liveSummaryBusy = false; liveSummaryBusyTicks = 0
                liveSummaryLastCount = liveSummaryWindowStart
            }
            return
        }
        let total = transcript.lines.count
        // A mid-session recluster (P15) can SHRINK the line count — clamp the
        // watermark or `suffix(total - last)` goes negative (precondition crash).
        if liveSummaryLastCount > total { liveSummaryLastCount = total }
        guard total >= liveSummaryLastCount + LiveSummary.minNewLines else { return }
        guard let s = ensureSummaryEngine() else { return }
        // Slice BEFORE attributing — a 2-hour meeting shouldn't re-render every
        // line's speaker label per tick just to feed the newest handful.
        let newLines = transcript.lines.suffix(total - liveSummaryLastCount).map {
            "\(SpeakerID.display($0.speaker, names: speakerNames, fallback: "화자\($0.speaker)")): \($0.text)"
        }
        liveSummaryWindowStart = liveSummaryLastCount
        liveSummaryLastCount = total
        liveSummaryBusy = true; liveSummaryBusyTicks = 0
        liveSummaryProgressAt = Date()          // submitted — restart the starvation clock
        s.liveSummarize(carry: liveSummaryText, lines: newLines, template: summaryTemplate)
    }

    private func stopLiveSummary() {
        liveSummaryTimer?.invalidate(); liveSummaryTimer = nil
        liveSummaryBusy = false; liveSummaryBusyTicks = 0
        // The pane disappears with the recording; the post-session summary is
        // the authoritative replacement (full transcript, template sections).
    }

    // file-mode progress (nil when not transcribing a file)
    private(set) var fileName: String = ""
    private(set) var chunksDone = 0
    private(set) var chunksTotal = 0

    /// Whether to run speaker diarization at all. OFF ⇒ the engine skips the whole
    /// diar path (no ResNet34 embeddings, model not loaded) and attributes every
    /// line to a single speaker (see EngineProcess DIAR + transcribe.zig). Persisted.
    var diarize: Bool = {
        let d = UserDefaults.standard
        // Migration: the removed "1명" choice (fixedSpeakerCount == 1) meant a
        // single speaker — now expressed as diarization OFF. Apply once, only if
        // the new key has never been written.
        if d.object(forKey: "diarizeEnabled") == nil {
            return d.integer(forKey: "fixedSpeakerCount") != 1
        }
        return d.bool(forKey: "diarizeEnabled")
    }() {
        didSet { UserDefaults.standard.set(diarize, forKey: "diarizeEnabled") }
    }
    var inputDeviceID: AudioDeviceID?          // nil = system default mic
    var availableInputs: [AudioInputDevice] { AudioDevices.inputs() }

    /// Change the input mic. Live session (recording/paused) → hot-swaps the
    /// capture device in place; otherwise it just applies at the next start.
    func setInputDevice(_ id: AudioDeviceID?) {
        inputDeviceID = id
        switch phase {
        case .recording, .paused: capture.switchInput(to: id)
        default: break
        }
    }
    /// Capture source: 마이크 / 시스템 오디오(Teams·Slack·YouTube) / 마이크+시스템.
    /// Persisted; applied at the next record start.
    var audioSource: AudioSource = AudioSource(rawValue: UserDefaults.standard.string(forKey: "audioSource") ?? "mic") ?? .mic {
        didSet { UserDefaults.standard.set(audioSource.rawValue, forKey: "audioSource") }
    }
    private(set) var audioPermissionIssue: AudioPermissionIssue?
    var osd = true
    // restored from the last launch (0 / unset = auto-detect)
    var languageTokenID: Int? = {
        let v = UserDefaults.standard.integer(forKey: "languageTokenID")
        return v > 0 ? v : nil
    }()
    var speakerNames: [Int: String] = [:]

    /// Speaker ids auto-labeled this session because their voice matched an
    /// enrolled voiceprint (engine SPKNAME event) — vs. names the user typed.
    /// Session-scoped; drives the '✓ 음성 인식됨' affordance. Not persisted.
    var autoRecognizedSpeakers: Set<Int> = []
    /// Mid-session speaker names buffered for deferred voiceprint enrollment
    /// (the engine only dumps centroids AFTER flush — see finalizeOnce).
    private var pendingEnrollment = PendingEnrollmentStore()

    /// Personal vocabulary — domain terms/names the user has corrected over time.
    /// Loaded once at init; auto-correction is OFF until glossary.enabled is set.
    var glossary = Glossary.load()

    /// Fixed speaker count when diarization is ON (자동/2/3/4/5명 이상). Persisted; maps
    /// to the engine's DIAR_MAXK upper bound. 자동 and 5명 이상 leave the cap at 8.
    /// Ignored when `diarize` is off (the engine skips diar entirely). An old saved
    /// value of 1 (removed "1명") no longer maps → falls back to .auto (the migration
    /// on `diarize` turns that user's setting into diarization-off).
    var speakerCount: SpeakerCount = SpeakerCount(rawValue: UserDefaults.standard.integer(forKey: "fixedSpeakerCount")) ?? .auto {
        didSet { UserDefaults.standard.set(speakerCount.rawValue, forKey: "fixedSpeakerCount") }
    }

    /// Current meeting-shape preset. Persisted (rawValue key "meetingMode"; unknown
    /// or absent → .general, today's baseline). On change it auto-applies the
    /// preset's default diarization speaker count; summaryPromptSuffix is threaded
    /// into the summarize calls below.
    var meetingMode: MeetingMode = MeetingMode(rawValue: UserDefaults.standard.string(forKey: "meetingMode") ?? "") ?? .general {
        didSet {
            UserDefaults.standard.set(meetingMode.rawValue, forKey: "meetingMode")
            // Apply the preset's diarization hints (on/off + count). A preset, not a
            // lock — the user can still toggle 화자 분리 / adjust 화자 수 afterward.
            diarize = meetingMode.config.defaultDiarize
            if let sc = SpeakerCount(rawValue: meetingMode.config.defaultSpeakerCountRaw) {
                speakerCount = sc
            }
            // Re-derive the summary template (회의/강의/인터뷰) from the new shape.
            // The mode is the durable signal; a sheet override (PR-C) is per-session.
            summaryTemplate = meetingMode.defaultSummaryTemplate
        }
    }

    /// Summary template threaded into every summarize call — derived from
    /// `meetingMode`, overridable per session from the summary sheet.
    /// Not persisted on its own: the mode is the durable signal.
    ///
    /// Changing it INVALIDATES both cached summaries: each was shaped by the old
    /// template (which also drove the long-meeting fold), so keeping them would
    /// show 회의-shaped text under a 강의 label. Invalidation lives here — not in
    /// the view — so every path that re-derives the template (a meeting-mode
    /// change included) drops the stale text. Regeneration stays the caller's
    /// choice: only the sheet knows which view the user is looking at.
    var summaryTemplate: SummaryTemplate =
        (MeetingMode(rawValue: UserDefaults.standard.string(forKey: "meetingMode") ?? "") ?? .general)
            .defaultSummaryTemplate
    {
        didSet {
            guard summaryTemplate != oldValue else { return }
            meetingSummary = nil
            speakerSummary = nil
        }
    }

    /// Live segment window (s) — the live FELT-latency knob. Text lands when a
    /// window closes, so a shorter window = snappier live text but less Whisper
    /// context (more boundary error). Default 10 = current accuracy (no
    /// regression); applied at the next record start. Persisted.
    var liveWindowSeconds: Double = (UserDefaults.standard.object(forKey: "liveWindowSeconds") as? Double) ?? 10 {
        didSet { UserDefaults.standard.set(liveWindowSeconds, forKey: "liveWindowSeconds") }
    }

    /// 번역 꼬리 지연(초): the LAST line — which never loses last-line status in a
    /// monologue — is translated this long after it stops changing (scheduleTail-
    /// Translate). Separated from the STT window (liveWindowSeconds) so translation
    /// eagerness tunes INDEPENDENTLY: larger = fewer premature / re-translated last
    /// lines, smaller = snappier captions. Committed (non-last) lines translate the
    /// instant they lose last-status regardless of this value. Default 3 s — raised
    /// from the old hard-coded 2 s to curb premature last-line translation while
    /// tuning; adjustable in 설정 → 번역. Persisted.
    var translateTailSeconds: Double = (UserDefaults.standard.object(forKey: "translateTailSeconds") as? Double) ?? 3 {
        didSet { UserDefaults.standard.set(translateTailSeconds, forKey: "translateTailSeconds") }
    }

    /// 2개 이상으로 번역할 때는 반응속도 하한을 "보통"(7초)으로 둔다 — 5초만 막고
    /// 7·10초는 자유(2026-07-07 완화, 기존엔 10초 강제였음). 짧은 윈도는 원문
    /// 경계 오류가 많은데 그 오류가 모든 대상 언어 번역으로 전파되므로, 다중 번역
    /// 에서는 5초가 위험하다 — 다만 7초는 충분한 문맥이라 허용. UI도 이 규칙을
    /// 노출(2개+ 선택 시 5초를 고르면 7초로 스냅).
    /// 예외 (T4, 2026-07-03): {한국어, X} 양방향 쌍은 per-line 스크립트 라우팅이
    /// 라인당 실효 타깃을 1개로 줄이므로(KO줄→X만, X줄→KO만) 강제하지 않는다 —
    /// 클리닉 대면 통역이 정확히 이 형태다.
    var multiTranslateForcesAccurate: Bool {
        translateTargets.count >= 2 &&
            !(translateTargets.count == 2 && translateTargets.contains("Korean"))
    }
    /// Multi-target: floor the window at 7 s (short windows leak boundary errors
    /// into every language) but allow 7 or 10 — no longer pinned to 10.
    var effectiveWindowSeconds: Double {
        multiTranslateForcesAccurate ? max(7, liveWindowSeconds) : liveWindowSeconds
    }

    /// Streaming preview: the resident engine's throwaway lane decodes the open
    /// window every ~1s for instant interim text. Committed text stays unchanged,
    /// and no second model/process is loaded. Persisted.
    var livePreviewEnabled: Bool = (UserDefaults.standard.object(forKey: "livePreviewEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(livePreviewEnabled, forKey: "livePreviewEnabled") }
    }
    /// Interim "진행 중" text (cleared when the window's committed words land).
    /// Fed by TWO provisional sources that overwrite each other (both cover the
    /// freshest audio; life of a «partial» is ~0.5 s with AUDIO_CTX decode):
    ///   «partial» lines — the closed segment's in-decode hypothesis (main
    ///                     engine, PARTIALS=1) — converges to the committed text
    ///   PREVIEW lane    — the still-open window's text (~1 s cadence)
    private(set) var livePartial: String = "" {
        didSet {
            // NOTE: translations are NOT auto-cleared here — on window commit the
            // last interim translation stays on screen as a provisional caption
            // (T1 carryover) until the committed line's real translation lands.
            // Session reset/stop sites clear livePartialTranslations explicitly.
            if livePartial != oldValue {
                // P10-0: the window's responsiveness clock starts at the first
                // hypothesis character, not at the turn — that is what the user
                // experiences as "how long until I see a translation".
                if !livePartial.isEmpty {
                    TranslationStabilityMetrics.shared.markStart(.captionFirstPaint, key: "window")
                }
                // P8: LocalAgreement runs on EVERY hypothesis (here), not inside
                // the debounced task — agreement needs consecutive observations,
                // and the debounce drops most of them.
                committedInterimSource = interimSourceGate.commit(livePartial)
                TranslationStabilityMetrics.shared.sourceHeldChars +=
                    max(0, livePartial.count - committedInterimSource.count)
                // P12: completed sentences leave the re-translation loop — one
                // one-shot turn each, then frozen; turns only chase the OPEN
                // sentence from here on.
                let (fresh, current) = interimSentences.advance(source: committedInterimSource)
                currentInterimSentence = current
                let base = interimSentences.sentences.count - fresh.count
                for (i, sentence) in fresh.enumerated() {
                    requestSentenceFinal(sentence, index: base + i)
                }
                scheduleInterimTranslate()
            }
        }
    }
    /// Provisional translation of the in-progress interim text (lang → text), shown
    /// immediately so a caption doesn't wait ~10s for the window to close. Replaced
    /// by the authoritative per-line translation once the line commits.
    private(set) var livePartialTranslations: [String: String] = [:]
    /// P3: the EXACT hypothesis text `livePartialTranslations` were generated
    /// from. The caption pairs translation with this — never with the newer
    /// `livePartial` — so its two rows cannot contradict each other, and it can
    /// hold the pair across the commit gap instead of jumping to an older line.
    private(set) var livePartialSource: String = ""

    /// P9: display-side LocalAgreement — only words two consecutive MT results
    /// agree on reach the caption (append-only per language; measured NE 0.00
    /// across four language pairs). Supersedes the P1 StablePrefixFilter here:
    /// hold-then-accept still let deep MT rewordings through on the 2nd verdict,
    /// which was the residual churn after P8. Reset per window.
    private var interimDisplay = InterimDisplayAgreement()
    /// P2: the hypothesis the last ACCEPTED interim turn translated; the gate
    /// compares against this, not against what is displayed. Reset per window.
    private var lastInterimRequestedSource = ""
    /// P12: sentence scope — completed sentences translate ONCE and freeze;
    /// only the open sentence re-translates (measured: interim prefill −45%,
    /// coverage +11pt; the one visible refinement per sentence boundary stays
    /// inside the NE≤0.2 gate).
    private var interimSentences = InterimSentenceLedger()
    /// lang → per-completed-sentence frozen translations ("" until its one-shot
    /// result lands; slots fill in order because the engine is serial).
    private var frozenInterim: [String: [String]] = [:]
    /// The open sentence currently eligible for interim translation.
    private var currentInterimSentence = ""
    /// P8: LocalAgreement-2 over the hypothesis stream — the translator is fed
    /// only the word prefix two consecutive decodes agreed on (surface locked),
    /// so it never re-translates a source that changed meaning under it.
    private var interimSourceGate = InterimSourceGate()
    /// The stable source currently eligible for interim translation. Monotonic
    /// within a window; this — not `livePartial` — is what the caption's
    /// provisional translation corresponds to.
    private(set) var committedInterimSource = ""

    /// P6: every visible mutation of the caption's provisional translations goes
    /// through these three paths, so the stability meter observes all of them.
    /// livePartialSource moves only when the DISPLAYED text moves, so the caption
    /// always shows a (hypothesis, translation) pair from the same generation.
    private func updateInterimTranslation(lang: String, text: String, source: String) {
        let display = interimDisplay.feed(lang: lang, candidate: text)
        if !display.isEmpty {
            TranslationStabilityMetrics.shared.markEnd(.captionFirstPaint, key: "window")
            if let id = activeInterimID {
                TranslationStabilityMetrics.shared.markEnd(.turnTTFT, key: "\(id.uuidString)|\(lang)")
            }
        }
        if display != text { TranslationStabilityMetrics.shared.stabilizerHolds += 1 }
        guard !display.isEmpty else { return }
        currentInterimDisplay[lang] = display
        let composed = composedInterim(lang: lang)
        guard livePartialTranslations[lang] != composed else { return }
        TranslationStabilityMetrics.shared.recordShown(.caption, key: lang, text: composed)
        livePartialTranslations[lang] = composed
        livePartialSource = source
    }
    private func setInterimTranslations(_ translations: [String: String], source: String) {
        var display: [String: String] = [:]
        for (lang, text) in translations {
            let d = interimDisplay.feed(lang: lang, candidate: text)
            if !d.isEmpty {
                TranslationStabilityMetrics.shared.markEnd(.captionFirstPaint, key: "window")
                if let id = activeInterimID {
                    TranslationStabilityMetrics.shared.markEnd(.turnTTFT, key: "\(id.uuidString)|\(lang)")
                }
                currentInterimDisplay[lang] = d
            }
            if d != text { TranslationStabilityMetrics.shared.stabilizerHolds += 1 }
            // P9: before first agreement the gate returns "" — keep whatever the
            // caption already shows rather than blanking it. P12: compose the
            // frozen sentences in front of the open-sentence display.
            let composed = composedInterim(lang: lang)
            if composed.isEmpty, let existing = livePartialTranslations[lang] { display[lang] = existing }
            else if !composed.isEmpty { display[lang] = composed }
        }
        for lang in livePartialTranslations.keys where display[lang] == nil {
            TranslationStabilityMetrics.shared.recordShown(.caption, key: lang, text: nil)
            interimDisplay.remove(lang: lang)
            currentInterimDisplay[lang] = nil
        }
        for (lang, text) in display where livePartialTranslations[lang] != text {
            TranslationStabilityMetrics.shared.recordShown(.caption, key: lang, text: text)
        }
        if livePartialTranslations != display {
            livePartialTranslations = display
            livePartialSource = source
        }
    }
    /// Boundary teardown — the provisional text is superseded by the committed
    /// translation (or the session ended). A replacement by the final is not
    /// flicker, so the meter forgets without counting.
    private func clearInterimCaption() {
        TranslationStabilityMetrics.shared.closeCaption()
        interimDisplay.reset()
        lastInterimRequestedSource = ""
        interimSourceGate.reset()
        committedInterimSource = ""
        interimSentences.reset()
        frozenInterim = [:]; currentInterimDisplay = [:]; currentInterimSentence = ""
        livePartialTranslations = [:]
        livePartialSource = ""
    }
    private struct InterimRequest {
        let source: String
        var pending: Set<String>
        var translations: [String: String]
        /// P12: nil = open-sentence turn (display-gated); an index = one-shot
        /// translation of the completed sentence that freezes at that slot.
        var sentence: Int? = nil
    }
    private var interimRequests: [UUID: InterimRequest] = [:]
    private var activeInterimID: UUID?
    private var interimGen = 0
    private let preview = PreviewEngine()
    private var dnaBusy = false

    /// GPU admission order: committed Whisper > DNA caption > throwaway preview.
    /// PreviewEngine is a latest-only scheduler over the SAME resident process,
    /// so closing this gate never grows a stale queue or duplicates model memory.
    private func updatePreviewAdmission() {
        // P1: the PREVIEW lane used to be gated hard on `dnaBusy`; with a
        // translation backlog that never empties the live gray text never
        // appeared. Now a preview is admitted at least every `previewAgingSeconds`
        // even while DNA is busy (≈0.3 s of GPU per slice).
        let aged = Date().timeIntervalSince(lastPreviewAdmitAt) >= previewAgingSeconds
        preview.setAdmitted(segmentsInFlight == 0 && (!dnaBusy || aged))
    }
    private var previewAgingSeconds: Double { translateQueueDepth <= 6 ? 2 : 4 }

    /// P4: last time each background lane made progress (started, submitted, or
    /// landed a result) — the starvation clock BackgroundLaneAdmission reads.
    private var liveSummaryProgressAt = Date()
    private var liveRailProgressAt = Date()
    /// Ticks the summary lane skipped for caption backlog, and admissions the
    /// starvation valve granted (both lanes) — reported in the stability log.
    private var liveSummarySkippedTicks = 0
    private var liveSummaryStarvedAdmits = 0
    private var liveRailStarvedAdmits = 0

    /// STT/preview telemetry appended to the stability summary at stop.
    private func sttStatsTag() -> String {
        let s = sttTurnarounds.sorted()
        func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        let minutes = max(1.0 / 60.0, (previewLaneStartedAt.map { Date().timeIntervalSince($0) } ?? 0) / 60)
        return String(format: "stt n=%d p50=%.2fs p95=%.2fs max=%.2fs previews=%d/min=%.1f | bg summarySkipped=%d summaryStarvedAdmits=%d railStarvedAdmits=%d | %@",
                      s.count, pct(0.5), pct(0.95), s.last ?? 0, previewAdmits, Double(previewAdmits) / minutes,
                      liveSummarySkippedTicks, liveSummaryStarvedAdmits, liveRailStarvedAdmits, engineDiag.tag)
            // L1 (2026-09-06): live row structure — how many rows the session
            // ended with and how many same-speaker boundaries were re-decided
            // (joined) after a label fix. The autosave is a user setting and the
            // accessibility tree does not expose row text, so this line is the
            // only durable record of the LIVE structure once finalize regroups it.
            + String(format: " | rows=%d joins=%d spkfixRebuilds=%d runaway=%d hangs=%d",
                     transcript.lines.count, transcript.sameSpeakerJoins, transcript.speakerFixRebuilds,
                     translate?.runawayTruncations ?? 0, hangRecoveries)
    }

    /// Live translation TARGETS — a set of English language NAMES
    /// ("Korean"/"Chinese"/"Japanese"/"English"); empty = off. Each committed
    /// segment is translated into all targets at once (multi-target). Persisted.
    /// Only active when AssetManifest.translateAvailable (engine bundled + model).
    var translateTargets: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "translateTargets") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(translateTargets), forKey: "translateTargets")
            if translateTargets.isEmpty {
                translate?.stop(); translate = nil
                if captionOverlayOn { hideCaptionOverlay() }   // overlay is meaningless w/o targets
            }
        }
    }
    /// Display labels for the translation targets — shared by the Settings tab and
    /// the first-screen 자막·번역 picker so both stay in sync (no forked list).
    static let translateLangLabels: [(code: String, label: String)] =
        [("Korean", "한국어"), ("English", "English"), ("Japanese", "日本語"), ("Chinese", "中文")]
    /// View-safe derivation of "clinic bidirectional pair" — targets are exactly
    /// {Korean, X}. Drives the two-party clinic UI + the voiceprint-anchor trigger
    /// only. (Per-segment language re-probe is NO LONGER gated on this pair: the
    /// engine whitelist is now targets ∪ input language — see langCandidatePair.)
    var isBidirectionalKoPair: Bool { translateTargets.count == 2 && translateTargets.contains("Korean") }

    private var translate: TranslateEngine?
    private var translatedHash: [UUID: UInt64] = [:]  // line id → source revision (re-queue on change)
    private var tailGen = 0                        // tail-timeout generation (T2)
    /// T8: disk-persistent pre-translated clinic phrase bank (0 ms on hit).
    private let faqStore = FAQTranslationStore.load(
        from: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sovereign/faq_translations.json"))
    /// O3 — reuse interim translations for the matching committed line instead of
    /// re-queuing a fresh DNA3 turn. Cleared on every session boundary to prevent
    /// cross-meeting bleed.
    private var interimCache = InterimTranslationCache()

    // ── on-device meeting intelligence (post-session summary + action items) ──
    // Uses the SAME selected DNA3 process; the transcript never leaves the device.
    private var summaryEngine: SummaryEngine?
    private(set) var meetingSummary: String? = nil
    /// Smart auto-title — sanitized one-line meeting name (nil until generated).
    private(set) var meetingTitle: String? = nil
    private(set) var summarizing = false
    // speaker-aware breakdown (who said what / who owns which action)
    private(set) var speakerSummary: String? = nil
    private(set) var speakerSummarizing = false
    // transcript Q&A — "ask the meeting" (grounded in the transcript, on-device)
    private(set) var qaAnswer: String? = nil
    private(set) var qaAsking = false
    /// ⌘K command-palette visibility. Lives here (not a ContentView @State) so the
    /// app-scene menu command can toggle it: a scene `.commands` shortcut registers
    /// app-wide regardless of view layout/focus, unlike the old zero-size in-view
    /// button whose ⌘K never reached the responder chain (it silently no-op'd).
    var showCommandPalette = false

    /// ⌘F find-in-transcript bar visibility. Same rationale as showCommandPalette:
    /// the app-scene menu command (Edit → 전사문에서 찾기) flips it, so the shortcut
    /// registers reliably. The query/match state lives in ContentView.
    var showFindBar = false

    // ── AI reconcile (post-session diarization/language correction) ──────────
    /// Opt-in: after a session, let the on-device LLM read the dialogue and fix
    /// obvious speaker splits/mislabels and wrong-language lines. Off by default.
    var aiReconcileEnabled: Bool = (UserDefaults.standard.object(forKey: "aiReconcileEnabled") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(aiReconcileEnabled, forKey: "aiReconcileEnabled") }
    }
    private(set) var reconciling = false
    /// One-line summary of what the reconcile pass changed (nil = nothing / not run).
    private(set) var reconcileNote: String? = nil
    /// Retained per-segment audio (live mode) so a wrong-language line can be
    /// re-transcribed from its own clip. (offset seconds, wav url), in order.
    private var segmentAudio: [(offset: Double, url: URL)] = []

    // ── watchdog (W1 coverage / W2 hang / W3 HUD) ─────────────────────────────
    private struct SegJob { let offset: Double; let url: URL; let hadSpeech: Bool; var retried: Bool; var fedAt: Date }
    private var segQueue: [SegJob] = []          // fed to the engine, awaiting <<SEG_END>>
    /// Segments the engine is still transcribing (W3 HUD "전사 N").
    private(set) var segmentsInFlight = 0
    private var wordsSinceSegStart = 0           // words seen since the previous SEG_END
    /// Offsets (s) of segments that had speech but produced no words even after a
    /// retry — surfaced as "누락 의심" so the user knows something was missed.
    private(set) var coverageGaps: [Double] = []
    /// Engine hang recoveries this session (W2) — nonzero means the engine was
    /// restarted and pending segments were re-fed (no audio lost).
    private(set) var hangRecoveries = 0
    private var watchdogTimer: Timer?
    // B1: continuous mid-session reconcile (≥16GB, opt-in with AI 교정)
    private var midReconcileTimer: Timer?
    private var reconcileSnapshot: [UUID] = []   // prompt line order → line ids
    private var reconcileIsMid = false
    private var decodeRiskRanges: [(start: Double, end: Double)] = []
    private(set) var languageCorrectionsPending = 0
    private var reconcileSpeakerNamesBefore: [Int: String]?
    private var reconcileAutoNamesBefore: Set<Int>?

    private var attributedLines: [String] {
        transcript.lines.map { "\(SpeakerID.display($0.speaker, names: speakerNames, fallback: "화자\($0.speaker)")): \($0.text)" }
    }

    /// Attach meeting intelligence to the shared resident DNA3 broker. Translation,
    /// rail, summary and Q&A serialize onto one model/process at every RAM tier.
    private func ensureSummaryEngine() -> SummaryEngine? {
        guard let eng = AssetManifest.translateEngineURL, AssetManifest.translateModelIsValid() else { return nil }
        if summaryEngine == nil {
            let s = SummaryEngine()
            s.onResult = { [weak self] tag, text in
                guard let self else { return }
                switch tag {
                case "summary":
                    self.summarizing = false
                    self.meetingSummary = text ?? "요약 생성에 실패했습니다. 다시 시도하세요."
                    // Separate file (transcript stays summary-free) when 요약 is on.
                    if let text, self.autoSaveEnabled, self.autoSaveSummary {
                        self.autoSaveSummaryMarkdown(text)
                    }
                case "speakers":
                    self.speakerSummarizing = false
                    self.speakerSummary = text ?? "화자별 요약 생성에 실패했습니다."
                case "qa":
                    self.qaAsking = false
                    self.qaAnswer = text ?? "답변 생성에 실패했습니다."
                case "title":
                    // Smart auto-title: rename the already-saved .md to the AI name
                    // (the save itself was never deferred — no reliability regression).
                    if let t = TitleGenerator.sanitize(text ?? "") {
                        self.meetingTitle = t
                        self.renameAutoSavedToTitle(t)
                    }
                case "live-rail":
                    // Accumulate newly-extracted rail items (dedup by content id) so
                    // decisions persist as the recent-window extraction slides forward.
                    self.liveRailBusy = false; self.liveRailBusyTicks = 0
                    self.liveRailProgressAt = Date()
                    if let text {
                        var seen = Set(self.liveRailItems.map(\.id))
                        var added = false
                        for it in LiveActionRail.parse(text) where seen.insert(it.id).inserted {
                            self.liveRailItems.append(it); added = true
                        }
                        // New rail questions are a coach input → refresh once on append
                        // (cheap, ≤ once per 18s rail tick), not per word event.
                        if added { self.recomputeCoach() }
                    }
                case "live-summary":
                    // Rolling update landed (already sanitized engine-side).
                    // Empty/nil ⇒ keep the previous summary — a blank pane and a
                    // poisoned carry are both worse than a stale one.
                    self.liveSummaryBusy = false; self.liveSummaryBusyTicks = 0
                    self.liveSummaryProgressAt = Date()
                    if let text, !text.isEmpty {
                        self.liveSummaryText = text
                        self.liveSummaryUpdatedAt = Date()
                    }
                case "reconcile":
                    self.applyReconcile(text)
                default: break
                }
            }
            guard s.start(engine: eng, model: AssetManifest.translateModelURL) else { return nil }
            summaryEngine = s
        }
        return summaryEngine
    }

    /// Whether a summary/Q&A request can do anything right now: there is something
    /// to summarize and the session isn't still live. The methods below re-check
    /// this themselves (defense in depth at the engine boundary); the UI gates its
    /// 요약 affordances on it so a press can never open an empty sheet.
    var canSummarize: Bool {
        guard !transcript.lines.isEmpty else { return false }
        switch phase { case .recording, .paused, .countingDown: return false; default: return true }
    }

    /// Structured [요약]/[액션]/[결정] from the diarized transcript, on-device.
    func summarize() {
        guard !summarizing else { return }
        guard !transcript.lines.isEmpty else { return }
        switch phase { case .recording, .paused, .countingDown: return; default: break }
        guard let s = ensureSummaryEngine() else {
            meetingSummary = "요약 모델이 없습니다 — 설정 › 번역에서 모델을 먼저 받으세요."; return
        }
        summarizing = true; meetingSummary = nil
        s.summarize(lines: attributedLines, template: summaryTemplate,
                    styleSuffix: meetingMode.config.summaryPromptSuffix)
    }

    /// Per-speaker breakdown (who said what / who owns which action), on-device.
    func summarizeBySpeaker() {
        guard !speakerSummarizing else { return }
        guard !transcript.lines.isEmpty else { return }
        switch phase { case .recording, .paused, .countingDown: return; default: break }
        guard let s = ensureSummaryEngine() else {
            speakerSummary = "요약 모델이 없습니다 — 설정 › 번역에서 모델을 먼저 받으세요."; return
        }
        speakerSummarizing = true; speakerSummary = nil
        s.summarizeBySpeaker(lines: attributedLines, template: summaryTemplate,
                             styleSuffix: meetingMode.config.summaryPromptSuffix)
    }

    /// "Ask the meeting" — answer grounded only in the transcript, on-device.
    func askTranscript(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !transcript.lines.isEmpty else { return }
        switch phase { case .recording, .paused, .countingDown: return; default: break }
        guard let s = ensureSummaryEngine() else {
            qaAnswer = "요약 모델이 없습니다 — 설정 › 번역에서 모델을 먼저 받으세요."; return
        }
        qaAsking = true; qaAnswer = nil
        s.ask(q, lines: attributedLines)
    }

    /// "Ask the WORKSPACE" — answer grounded in question-relevant excerpts pulled
    /// from EVERY archived .md in the save folder (cross-meeting RAG), on-device.
    /// Reuses the same summaryEngine + "qa" result handler as askTranscript; only
    /// the retrieval scope differs (all meetings vs the open transcript).
    func askWorkspace(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        switch phase { case .recording, .paused, .countingDown: return; default: break }
        guard let s = ensureSummaryEngine() else {
            qaAnswer = "요약 모델이 없습니다 — 설정 › 번역에서 모델을 먼저 받으세요."; return
        }
        let mdFiles = workspaceTranscriptURLs()
        guard !mdFiles.isEmpty else { qaAnswer = "워크스페이스에 회의록이 없습니다."; return }
        // Budget the excerpts with headroom for the "[회의명] " prefixes so the
        // prefixed text fits the engine's ~800-char window without a second
        // retrieval pass dropping anything (askPreselected skips that re-filter).
        let excerpts = WorkspaceRetrieval.relevantExcerpts(q, mdFiles: mdFiles, budget: 650)
        guard !excerpts.isEmpty else { qaAnswer = "워크스페이스 회의록에서 관련 내용을 찾지 못했습니다."; return }
        qaAsking = true; qaAnswer = nil
        s.askPreselected(q, lines: excerpts.map { "[\($0.meeting)] \($0.text)" })
    }

    /// Build the People dashboard data: enrolled voiceprint names (basenames of
    /// voiceprintsDir/*.vec) aggregated over every transcript .md in the workspace.
    func peopleAnalytics() -> [Person] {
        let names: [String] = ((try? FileManager.default.contentsOfDirectory(
            at: voiceprintsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "vec" }
            .map { $0.deletingPathExtension().lastPathComponent }
        return PeopleAnalytics.aggregate(voiceprintNames: names, mdFiles: workspaceTranscriptURLs())
    }

    /// Workspace-level activity stats for the 통계 tab — a pure rollup over every
    /// saved transcript (summary siblings excluded). Computed on demand, like
    /// peopleAnalytics(); each meeting's date is its file modification time.
    func workspaceStats() -> WorkspaceStats {
        let fm = FileManager.default
        let meetings: [(date: Date, parsed: TranscriptArchive.Parsed)] = workspaceTranscriptURLs().compactMap { url in
            guard let parsed = TranscriptArchive.parse(url) else { return nil }
            let date = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()
            return (date, parsed)
        }
        return WorkspaceAnalytics.aggregate(meetings: meetings, now: Date())
    }

    /// Build the Open Loops data: every unresolved 결정/액션/질문 pulled from each
    /// archived meeting's summary block, aged by the .md creation date and flagged
    /// when a later meeting re-mentions it. Computed on demand (like peopleAnalytics()).
    func openLoopsAnalytics() -> [OpenLoopItem] {
        let mds = workspaceTranscriptURLs()
        let summaryByBase: [String: URL] = Dictionary(
            mds.map { ($0.deletingPathExtension().lastPathComponent, $0) },
            uniquingKeysWith: { a, _ in a })
        return OpenLoopsAggregator.aggregate(mdFiles: mds) { url in
            let base = url.deletingPathExtension().lastPathComponent
            guard let sib = summaryByBase["\(base) 요약"] else { return nil }
            return try? String(contentsOf: sib, encoding: .utf8)
        }
    }

    // Meeting Prep Brief — pre-record context snapshot for the detected calendar
    // event's attendees, built headless (pure retrieval, no LLM) from the workspace.
    var prepBriefData: PrepBriefData? = nil
    private(set) var loadingPrepBrief = false

    /// Build the Meeting Prep Brief for the currently-detected calendar event:
    /// surface prior decisions + open action items for its attendees from the
    /// workspace transcripts. Headless (pure retrieval, no engine).
    func ensurePrepBrief() {
        guard let ev = calendar.event else { prepBriefData = nil; return }
        loadingPrepBrief = true
        let title = ev.title
        let attendees = ev.attendees
        let mdFiles = workspaceTranscriptURLs()
        Task.detached(priority: .userInitiated) {
            let brief = MeetingPrepBrief.aggregate(title: title, attendees: attendees, mdFiles: mdFiles)
            await MainActor.run {
                self.prepBriefData = brief
                self.loadingPrepBrief = false
                self.updateCoachAgenda()   // agenda inputs changed → re-derive + recompute
            }
        }
    }

    /// Optional LLM-grounded prep context: ask the summary model the open
    /// decisions/actions for the event's attendees, grounded in workspace excerpts.
    func searchPrepContext() {
        guard let ev = calendar.event else { return }
        let q = MeetingPrepBrief.contextQuery(title: ev.title, attendees: ev.attendees)
        guard let s = ensureSummaryEngine() else {
            qaAnswer = "요약 모델이 없습니다 — 설정 › 번역에서 모델을 먼저 받으세요."; return
        }
        let mdFiles = workspaceTranscriptURLs()
        let excerpts = WorkspaceRetrieval.relevantExcerpts(q, mdFiles: mdFiles, budget: 650)
        guard !excerpts.isEmpty else { qaAnswer = "워크스페이스 회의록에서 관련 내용을 찾지 못했습니다."; return }
        qaAsking = true; qaAnswer = nil
        s.askPreselected(q, lines: excerpts.map { "[\($0.meeting)] \($0.text)" })
    }

    /// Every transcript .md leaf from the explorer tree (recursive).
    private func workspaceTranscriptURLs() -> [URL] {
        var out: [URL] = []
        func walk(_ nodes: [FileNode]) {
            for n in nodes {
                if let kids = n.children { walk(kids) }
                // Skip "<base> 요약.md" summary siblings — they aren't separate
                // meetings; including them double-counts every action/decision.
                else if n.isTranscript, !n.isSummaryFile { out.append(n.url) }
            }
        }
        walk(workspace.nodes)
        return out
    }

    /// New-session reset for everything summary-shaped. Called from `reset()`,
    /// `start()` and `transcribeFile()` — every session boundary — so the sheet's
    /// per-session template override expires here too.
    private func clearSummary() {
        // The sheet's override is documented as "this session only". Without this
        // it outlived the session that set it: pick 인터뷰 once, start a fresh
        // 일반-mode meeting, and its auto-saved .md came out in interview format.
        summaryTemplate = meetingMode.defaultSummaryTemplate
        calendar.clear()
        stopLiveRail(); liveRailItems = []         // new session → reset the live rail
        stopLiveSummary(); liveSummaryText = nil; liveSummaryUpdatedAt = nil
        stopLiveCoach(); coachAgenda = []; liveCoachState = .empty   // reset the coach too
        linePlayer.stop(); sourceMediaURL = nil   // new session → drop click-to-play audio
        summaryEngine?.stop(); summaryEngine = nil
        meetingSummary = nil; meetingTitle = nil; summarizing = false
        speakerSummary = nil; speakerSummarizing = false
        qaAnswer = nil; qaAsking = false
        prepBriefData = nil; loadingPrepBrief = false
    }

    /// English language name of the detected/selected source, to skip translating
    /// a segment into its own language (whisper token order: en=50259, zh=50260,
    /// ko=50264, ja=50266). Session-level FALLBACK — per-line script routing
    /// (TranslateRouting.scriptLang) takes precedence in routedTargets(for:).
    private var sourceLangName: String? {
        switch languageTokenID {
        case 50264: return "Korean"; case 50259: return "English"
        case 50266: return "Japanese"; case 50260: return "Chinese"
        default: return nil
        }
    }

    /// T4 direction routing: targets minus the TEXT's own language (Unicode
    /// script detection; falls back to the session source language). In the
    /// bidirectional clinic pair {Korean, Japanese}: a JA line → [Korean],
    /// a KO line → [Japanese] — one turn per line instead of K.
    private func routedTargets(for text: String) -> [String] {
        let src = TranslateRouting.scriptLang(of: text) ?? sourceLangName
        return translateTargets.subtracting([src].compactMap { $0 }).sorted()
    }
    /// Normalized per-session content hash for re-translate-on-change gating.
    private func lineHash(_ text: String) -> UInt64 {
        TextRevision.of(text)
    }

    /// Start the translate engine on demand (targets set + assets present).
    private func ensureTranslateEngine() -> TranslateEngine? {
        guard !translateTargets.isEmpty,
              let eng = AssetManifest.translateEngineURL,
              AssetManifest.translateModelIsValid() else { return nil }
        if translate == nil {
            let t = TranslateEngine()
            // caption display language first (T3): CaptionOverlay picks
            // sorted().first — make the engine serve that language first too.
            t.priorityLang = translateTargets.sorted().first
            // Live cap: keep the queue tracking the newest speech. Turns the engine
            // can't keep up with are shed and remembered for the stop-time backfill.
            t.maxPending = Self.liveTranslateCap(for: AssetManifest.translateModelVariant)
            t.onDiscard = { [weak self] id, lang, source in
                guard let self else { return }
                _ = self.finishInterimTurn(id: id, lang: lang, source: source, text: nil)
            }
            t.onDrop = { [weak self] id, lang, source in
                guard let self else { return }
                if self.finishInterimTurn(id: id, lang: lang, source: source, text: nil) { return }
                let key = TranslationWorkKey(id: id, lang: lang, sourceRevision: self.revisionFor(id: id, source: source))
                self.backlogKeys.insert(key)
                self.translateBacklog = Set(self.backlogKeys.map(\.id)).count
            }
            t.onResult = { [weak self] id, lang, text, source in
                guard let self else { return }
                if self.finishInterimTurn(id: id, lang: lang, source: source,
                                          text: text.isEmpty ? nil : text) { return }
                // A7: this turn finished streaming — drop the caret.
                if self.streamingTranslation == TranslationRef(id: id, lang: lang) {
                    self.streamingTranslation = nil
                }
                let revision = self.revisionFor(id: id, source: source)
                let completedKey = TranslationWorkKey(id: id, lang: lang, sourceRevision: revision)
                if !text.isEmpty {
                    if self.transcript.setTranslation(id, lang: lang, text, sourceRevision: revision) {
                        TranslationStabilityMetrics.shared.markEnd(.lineFirstTranslation,
                                                                   key: id.uuidString)
                    }
                } else {
                    // P0: the guard suppressed the final — roll back the already-
                    // streamed partial instead of leaving guard-invalid text on
                    // screen posing as a translation.
                    _ = self.transcript.suppressTranslation(id, lang: lang, sourceRevision: revision)
                }
                self.backlogKeys.remove(completedKey)
                self.translateBacklog = Set(self.backlogKeys.map(\.id)).count
                // Backfill is keyed per target+source generation; one language
                // completing can never falsely mark its siblings complete.
                self.backfillPendingKeys.remove(completedKey)
                self.backfillRemaining = self.backfillPendingKeys.count
                // T1 carryover teardown: the real translation replaced the
                // provisional interim caption for the freshest content.
                if id == self.transcript.lines.last?.id, self.livePartial.isEmpty {
                    self.clearInterimCaption()
                }
            }
            // streaming partial (T5): the reply types itself onto the screen
            // (~19 ms/token) instead of appearing whole ~0.5-0.9 s later.
            t.onPartial = { [weak self] id, lang, text, source in
                guard let self else { return }
                if let request = self.interimRequests[id] {
                    guard request.sentence == nil, id == self.activeInterimID,
                          request.source == source,
                          self.currentInterimSentence == source else { return }
                    self.updateInterimTranslation(lang: lang, text: text, source: source)
                } else if self.transcript.lines.contains(where: { $0.id == id }) {
                    guard LiveFeatureWiring.translationStreaming else { return }   // land once, complete
                    self.streamingTranslation = TranslationRef(id: id, lang: lang)  // A7 caret
                    if self.transcript.setTranslation(id, lang: lang, text,
                                                      sourceRevision: self.revisionFor(id: id, source: source)) {
                        TranslationStabilityMetrics.shared.markEnd(.lineFirstTranslation,
                                                                   key: id.uuidString)
                    }
                }
            }
            // queue depth (D20) — the engine reports queued + in-flight turns.
            t.onQueueChange = { [weak self] depth in
                guard let self else { return }
                self.translateQueueDepth = depth
                self.updatePreviewAdmission()
            }
            t.onLineDepthChange = { [weak self] n in self?.translateQueuedLines = n }
            t.interimGuarantee = InterimTuning.guaranteeSeconds   // P10-5 dial
            guard t.start(engine: eng, model: AssetManifest.translateModelURL) else { return nil }
            translate = t
        }
        return translate
    }

    /// Consume one target of an interim request. Each source snapshot owns a
    /// unique UUID and a per-language barrier, so A/B completions cannot share
    /// cache state or clear the in-flight guard early.
    @discardableResult
    private func finishInterimTurn(id: UUID, lang: String, source: String, text: String?) -> Bool {
        guard var request = interimRequests[id], request.source == source else { return false }
        request.pending.remove(lang)
        if let text, !text.isEmpty { request.translations[lang] = text }
        // P12: a sentence-final result freezes at its slot and recomposes the
        // caption; it also seeds the O3 cache under the SENTENCE key so the
        // committed lane can reuse it when this sentence commits as a line.
        if let slot = request.sentence {
            if let text, !text.isEmpty {
                var row = frozenInterim[lang] ?? []
                while row.count <= slot { row.append("") }
                row[slot] = text
                frozenInterim[lang] = row
                interimCache.put(source, [lang: text])
                recomposeInterimCaption(lang: lang, cause: .refinement)
            }
            if request.pending.isEmpty { interimRequests[id] = nil } else { interimRequests[id] = request }
            return true
        }
        let isActive = activeInterimID == id
        if isActive, currentInterimSentence == source {
            setInterimTranslations(request.translations, source: source)
            if !request.translations.isEmpty { interimCache.put(source, request.translations) }
        }
        if request.pending.isEmpty {
            interimRequests[id] = nil
            if isActive {
                activeInterimID = nil
                if !currentInterimSentence.isEmpty, currentInterimSentence != source {
                    scheduleInterimTranslate()
                }
            }
        } else {
            interimRequests[id] = request
        }
        return true
    }

    /// P12: one-shot translation of a sentence that just completed in the agreed
    /// source. Freezes at its slot; also seeds the O3 interim cache under the
    /// SENTENCE key — committed lines are sentence-per-line, so when this exact
    /// sentence commits, the committed lane gets its translation for free.
    private func requestSentenceFinal(_ sentence: String, index: Int) {
        // P13 no-erase handoff: the finished sentence's provisional rendering
        // MOVES into its frozen slot (composed text stays byte-identical, so
        // the handoff itself erases nothing on screen); the sentence-final
        // translation then replaces it in place as a tagged REFINEMENT. The
        // live NE 0.68 finding was exactly the old blank-then-final double hit.
        for (lang, cur) in currentInterimDisplay where !cur.isEmpty {
            var row = frozenInterim[lang] ?? []
            while row.count <= index { row.append("") }
            if row[index].isEmpty { row[index] = cur }
            frozenInterim[lang] = row
        }
        // The open-sentence display starts a new sentence — its agreement gate
        // must not judge the next sentence against the finished one.
        interimDisplay.reset()
        currentInterimDisplay = [:]
        guard !translateTargets.isEmpty, let t = ensureTranslateEngine() else { return }
        // O3 first: this sentence may already be in the cache (repeat phrase).
        if let cached = interimCache.get(sentence), !cached.isEmpty {
            for (lang, tr) in cached {
                var row = frozenInterim[lang] ?? []
                while row.count <= index { row.append("") }
                row[index] = tr
                frozenInterim[lang] = row
                recomposeInterimCaption(lang: lang, cause: .refinement)
            }
            return
        }
        guard LiveFeatureWiring.interimTranslation else { return }
        let targets = routedTargets(for: sentence)
        guard !targets.isEmpty else { return }
        let id = UUID()
        guard t.translate(sentence, into: targets, id: id, kind: .interim) else { return }
        TranslationStabilityMetrics.shared.interimTurnsRun += 1
        interimRequests[id] = InterimRequest(
            source: sentence, pending: Set(targets), translations: [:], sentence: index)
    }

    /// P12: the open sentence's display-gated text per language (the tail the
    /// composed caption ends with).
    private var currentInterimDisplay: [String: String] = [:]

    /// P12: the caption for `lang` = frozen sentence translations + the open
    /// sentence's display-gated text.
    private func composedInterim(lang: String) -> String {
        let head = (frozenInterim[lang] ?? []).filter { !$0.isEmpty }.joined(separator: " ")
        let cur = currentInterimDisplay[lang] ?? ""
        if head.isEmpty { return cur }
        return cur.isEmpty ? head : head + " " + cur
    }

    /// A frozen slot filled — republish the composed caption for that language.
    private func recomposeInterimCaption(
        lang: String, cause: TranslationStabilityMetrics.ShowCause = .stream) {
        let composed = composedInterim(lang: lang)
        guard !composed.isEmpty, livePartialTranslations[lang] != composed else { return }
        TranslationStabilityMetrics.shared.recordShown(.caption, key: lang, text: composed, cause: cause)
        livePartialTranslations[lang] = composed
        livePartialSource = committedInterimSource
    }

    /// Debounced (≈0.3s, one in flight) translation of the in-progress interim text
    /// so a PROVISIONAL caption appears right after you speak instead of waiting for
    /// the window to close. Best-effort + throwaway — the per-line translation wins.
    /// (600→300ms 2026-07-02: 체감 지연 −300ms; DNA3 턴 증가는 interimInFlight
    /// 단일-인플라이트 가드가 상한을 잡는다.)
    private func scheduleInterimTranslate() {
        guard !translateTargets.isEmpty else { return }
        interimGen += 1
        let gen = interimGen
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(InterimTuning.debounceMs)))
            guard let self, gen == self.interimGen, self.activeInterimID == nil,
                  !self.currentInterimSentence.isEmpty else { return }
            guard let t = self.ensureTranslateEngine() else { return }
            // P8+P12: translate the agreed OPEN SENTENCE — completed sentences
            // are frozen and never re-enter the loop.
            let source = self.currentInterimSentence
            // P2: don't spend a DNA turn on a hypothesis that adds almost
            // nothing since the last requested turn (emitter flap, +1 word
            // tails). The next growth re-arms; the committed translation
            // covers a gated-away tail at window close.
            guard InterimTranslateGate.worthTranslating(
                source: source, lastRequested: self.lastInterimRequestedSource,
                minDelta: InterimTuning.minDelta) else {
                TranslationStabilityMetrics.shared.interimTurnsSkipped += 1
                return
            }
            guard LiveFeatureWiring.interimTranslation else { return }
            let targets = self.routedTargets(for: source)
            guard !targets.isEmpty else { return }
            let id = UUID()
            // T1: the caption already holds an append-only, AGREED translation
            // prefix for this open sentence (P9 gate). Hand it to the engine as
            // forced assistant tokens: the turn prefills it in one batch and
            // decodes only the tail, instead of re-generating text the viewer is
            // looking at. Provisional (unagreed) text is never forced.
            let forced = Dictionary(uniqueKeysWithValues:
                targets.map { ($0, self.interimDisplay.committed(lang: $0)) })
            guard t.translate(source, into: targets, id: id, kind: .interim, forced: forced) else { return }
            for lang in targets {
                TranslationStabilityMetrics.shared.markStart(.turnTTFT, key: "\(id.uuidString)|\(lang)")
            }
            TranslationStabilityMetrics.shared.interimTurnsRun += 1
            self.lastInterimRequestedSource = source
            self.activeInterimID = id
            self.interimRequests[id] = InterimRequest(
                source: source, pending: Set(targets), translations: [:])
        }
    }

    /// Translate every stable line (all but the last, which may still grow) that
    /// hasn't been translated yet, into its routed targets. `includingLast` at
    /// finalize.
    ///
    /// T2 (2026-07-03): this is now called on EVERY .word ingest — a line queues
    /// the moment it loses last-line status instead of waiting for the NEXT
    /// window boundary (the old .wordSectionBegin-only trigger left committed
    /// lines untranslated for 10-20s+, or forever in a monologue). Idempotent
    /// via the (id → text-hash) gate; a line that grows later (merge) re-queues
    /// automatically because its hash changes.
    private func translateStableLines(includingLast: Bool = false) {
        guard !translateTargets.isEmpty else { return }
        var lines = transcript.lines
        var upTo = includingLast ? lines.count : max(0, lines.count - 1)
        // X1 (2026-09-07): a line that ENDS with the merger's held word is one
        // re-decode away from its text (the window-edge word is replaced at the
        // next segment boundary — "implications." → "implications"); while the
        // preview shows speech continuing, wait for that instead of translating
        // a text that will be revised (0.3.18 live: 37 of 110 rows translated
        // twice). A pause (preview cleared) releases it — see scheduleTailTranslate.
        if !includingLast, !livePartial.isEmpty, let held = transcript.heldWordID,
           let i = lines.prefix(upTo).lastIndex(where: { $0.words.last?.id == held }) {
            upTo = i
        }
        // P2 (2026-09-03): per word event only the last `stableScanWindow` lines
        // are visited. Live 0.3.5 at ~400 lines spent 18% of the main thread in
        // this function — hashing every line's joined text and re-running the
        // coalescer over the whole transcript on every word. A line is dispatched
        // the moment it loses last-line status (inside the window by
        // construction); frozen lines never change text; finalize
        // (includingLast) still walks everything.
        let from = includingLast ? 0 : max(0, upTo - Self.stableScanWindow)
        // Rewrite passes run FIRST, so a line is translated from its final text
        // instead of being retranslated after a later correction.
        // P0 (2026-09-03): this runs on EVERY word event; re-walking all lines
        // with the regex passes was a fixed main-actor cost that grew with the
        // session. A line is re-processed only when its text changed since the
        // last pass (merges/edits change the hash, so nothing is missed).
        for i in from..<upTo {
            let line = lines[i]
            let h = line.text.hashValue
            if stablePassHash[line.id] == h { continue }
            applyTextPasses(line)
            stablePassHash[line.id] = transcript.lines.first(where: { $0.id == line.id })?.text.hashValue ?? h
        }
        lines = transcript.lines   // a pass may have rewritten line text
        // P1: fragment lines fold into the next stable line of the same speaker and
        // translate with it (one turn per target instead of one per fragment).
        let stable = Array(lines[min(from, lines.count)..<min(upTo, lines.count)])
        // P4: pass the "still deciding" flag so a churning diarization cannot
        // split fragments off into their own turns (TranslationCoalescer.sameVoice).
        let newestEnd = lines.last?.end ?? 0
        let inputs = stable.map {
            TranslationCoalescer.Input(id: $0.id, speaker: $0.speaker, text: $0.text,
                                       start: $0.start, end: $0.end,
                                       undecided: SpeakerID.isDeciding(margin: $0.speakerMargin,
                                                                      age: max(0, newestEnd - $0.end)))
        }
        for run in TranslationCoalescer.runs(inputs, deferTrailing: !includingLast) {
            if run.members.isEmpty, let line = stable.first(where: { $0.id == run.anchor }) {
                translateLine(line)
            } else {
                translateRun(run, lines: stable)
            }
        }
    }
    /// line id → text hash at the last applyTextPasses run (see translateStableLines).
    private var stablePassHash: [UUID: Int] = [:]
    /// Lines visited per word event by translateStableLines (a fragment run is a
    /// handful of lines; the window only has to contain the line that just lost
    /// last-line status plus its pending fragments).
    private static let stableScanWindow = 32

    /// Lines the USER rewrote by hand. The system passes below must never
    /// overwrite a manual correction.
    private var userEditedLines: Set<UUID> = []

    /// Glossary correction + Korean spelled-number → digit formatting, as ONE
    /// pass so the second treatment sees the first one's output (running them as
    /// two loops meant a glossary-corrected line was skipped by the number pass,
    /// which guards on `editedText == nil`).
    ///
    /// Applied the moment a line stops being the live tail — the same gate that
    /// makes it eligible for translation — and again over everything at finalize.
    /// That timing is what makes live formatting safe: a number only converts
    /// with its counter attached (팔월 → 8월 needs the 월), and a line that is no
    /// longer growing cannot be cut mid-number, so there is no convert-then-
    /// rewrite churn. Because it runs before `translateLine`, the translation is
    /// produced from the formatted text rather than invalidated by it.
    private func applyTextPasses(_ line: Line) {
        guard !userEditedLines.contains(line.id) else { return }
        var text = line.text
        if glossary.enabled, let corrected = PersonalVocabulary.correctedLineText(line, glossary) {
            text = corrected
        }
        text = KoreanNumberFormatter.format(text)
        guard text != line.text else { return }
        _ = transcript.editLine(line.id, text)
    }

    /// The source revision a turn's result must match: for a coalesced run the
    /// engine echoes the JOINED text, but the anchor line's own revision gates
    /// setTranslation/suppressTranslation, so map it back.
    private func revisionFor(id: UUID, source: String) -> UInt64 {
        if coalescedSource[id] == source, let r = coalescedRevision[id] { return r }
        return lineHash(source)
    }

    /// P1: translate a fragment run as ONE turn per target on its anchor line;
    /// the fragment lines are marked suppressed (covered by the anchor's
    /// translation) instead of costing a turn each.
    private func translateRun(_ run: TranslationCoalescer.Run, lines: [Line]) {
        guard let anchor = lines.first(where: { $0.id == run.anchor }) else { return }
        let h = lineHash(run.text)
        let anchorRevision = lineHash(anchor.text)
        let routed = Set(routedTargets(for: run.text))
        for m in run.members {
            guard let ml = lines.first(where: { $0.id == m }) else { continue }
            let mh = lineHash(ml.text)
            if translatedHash[m] == mh { continue }
            translatedHash[m] = mh
            for lang in routed { _ = transcript.suppressTranslation(m, lang: lang) }
        }
        let existing = transcript.pruneTranslations(anchor.id, validTargets: routed, sourceRevision: anchorRevision)
        let missing = routed.subtracting(existing)
        guard !missing.isEmpty else { translatedHash[anchor.id] = h; return }
        if translatedHash[anchor.id] == h { return }
        guard let t = ensureTranslateEngine() else { return }
        TranslationStabilityMetrics.shared.markStart(.lineFirstTranslation, key: anchor.id.uuidString)
        translatedHash[anchor.id] = h
        coalescedSource[anchor.id] = run.text
        coalescedRevision[anchor.id] = anchorRevision
        t.translate(run.text, into: missing.sorted(), id: anchor.id)
    }

    /// Queue one line (hash-gated, FAQ/O3-cached, direction-routed).
    private func translateLine(_ line: Line, forceTargets: Set<String>? = nil) {
        let h = lineHash(line.text)
        let routed = Set(routedTargets(for: line.text))
        let requested = forceTargets.map { $0.intersection(routed) } ?? routed
        let existing = transcript.pruneTranslations(line.id, validTargets: routed, sourceRevision: h)
        let missing = requested.subtracting(existing)
        guard !missing.isEmpty else { translatedHash[line.id] = h; return }
        if forceTargets == nil, translatedHash[line.id] == h { return }
        guard let t = ensureTranslateEngine() else { return }
        // P10-0: committed-lane responsiveness — line queued → first translation
        // visible on that line (the transcript panel's felt latency).
        TranslationStabilityMetrics.shared.markStart(.lineFirstTranslation, key: line.id.uuidString)
        translatedHash[line.id] = h
        // T8: session-invariant FAQ bank first — a recurring clinic phrase costs
        // 0 ms and no DNA3 turn. Conservative exact (normalized) match only.
        if let faq = faqStore.lookup(line.text) {
            var unresolved: [String] = []
            for tgt in missing.sorted() {
                if let tr = faq[tgt] {
                    _ = transcript.setTranslation(line.id, lang: tgt, tr, sourceRevision: h)
                } else { unresolved.append(tgt) }
            }
            if unresolved.isEmpty { return }
            t.translate(line.text, into: unresolved, id: line.id)
            return
        }
        // O3: if this line's text was already translated as interim, reuse the
        // cached translations and skip the DNA3 turn entirely. Only reuse the
        // targets we actually have cached; queue the engine for any that miss.
        if let cached = interimCache.get(line.text) {
            let unresolved = missing.filter { cached[$0] == nil }.sorted()
            for tgt in missing where cached[tgt] != nil {
                _ = transcript.setTranslation(line.id, lang: tgt, cached[tgt]!, sourceRevision: h)
            }
            if unresolved.isEmpty { return }
            t.translate(line.text, into: unresolved, id: line.id)
            return
        }
        t.translate(line.text, into: missing.sorted(), id: line.id)
    }

    /// T2 tail timeout: the LAST line never loses last-status in a monologue —
    /// translate it after 2 s without change (re-queues on growth via the hash
    /// gate; the stale-guard in onResult drops superseded turns).
    private func scheduleTailTranslate() {
        guard !translateTargets.isEmpty else { return }
        tailGen += 1
        let gen = tailGen
        let delay = translateTailSeconds   // captured at schedule time (re-armed per word)
        let snapshot = transcript.lines.last.map { ($0.id, lineHash($0.text)) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, gen == self.tailGen,
                  let (id, h) = snapshot,
                  let line = self.transcript.lines.last, line.id == id,
                  self.lineHash(line.text) == h else { return }
            // P6: a live preview still attached to this line means the line is
            // not finished — its next words would invalidate the translation.
            // Re-arm and try again once the preview clears (pause / window close).
            if LiveFeatureWiring.tailTranslationWaitsForPreview, !self.livePartial.isEmpty {
                self.scheduleTailTranslate(); return
            }
            // X1: the preview is clear, so a held-ending line deferred by
            // translateStableLines is released together with the tail.
            self.translateStableLines()
            self.translateLine(line)
        }
    }

    /// Editor-feature toggles + thresholds (persisted). All editor exports/stats
    /// read from it. BETA: `enabled` is forced OFF at load (Self.editorFeaturesEnabled)
    /// so every consumer — tightenStat, cut/chapter analysis, the JSON export's
    /// editor annotations — sees the feature as off even if a previous build left
    /// `enabled: true` on disk. The Settings tab that used to bind here is removed.
    var editorSettings: EditorSettings = {
        var s = EditorSettings.load()
        if !SessionController.editorFeaturesEnabled { s.enabled = false }
        return s
    }() { didSet { editorSettings.save() } }

    // ── auto-save: write a .md when a session finishes (live stop or file done) ──
    var autoSaveEnabled: Bool = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: "autoSaveEnabled") }
    }
    // ── live action rail: real-time decisions/actions/questions during recording ──
    /// Hardware gate: the live rail runs the 2.6 GB DNA3 LLM concurrently with the
    /// Whisper engine, which only fits comfortably on ≥16 GB unified memory. On the
    /// 8 GB floor (M1 Air) the toggle is disabled — the post-session A.I 요약 covers it.
    static let liveRailCapable = ProcessInfo.processInfo.physicalMemory >= 16 * (1 << 30)
    var liveRailEnabled: Bool = (UserDefaults.standard.object(forKey: "liveRailEnabled") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(liveRailEnabled, forKey: "liveRailEnabled") }
    }

    // ── live rolling summary state (scheduler lives next to the rail's above) ──
    /// Default ON (unlike the rail): the 요약 tab only appears once a summary
    /// actually lands, so an idle default costs nothing on gated-out machines.
    var liveSummaryEnabled: Bool = (UserDefaults.standard.object(forKey: "liveSummaryEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(liveSummaryEnabled, forKey: "liveSummaryEnabled")
            if !liveSummaryEnabled { stopLiveSummary(); liveSummaryText = nil }
            else {
                // Re-arm in ANY active session phase (paused, counting down,
                // engine starting …) — the tick's own .recording guard keeps a
                // pre-recording timer idle. Gating on .recording alone killed
                // the loop for the rest of the session when the toggle was
                // flipped mid-pause (review finding).
                switch phase {
                case .idle, .done, .error: break   // start() arms the next session
                default: startLiveSummary()
                }
            }
        }
    }
    /// Sanitized rolling summary (flat bullets) — doubles as the next carry.
    private(set) var liveSummaryText: String? = nil
    private(set) var liveSummaryUpdatedAt: Date? = nil
    private(set) var liveSummaryBusy = false
    private var liveSummaryTimer: Timer?
    private var liveSummaryLastCount = 0
    private var liveSummaryWindowStart = 0   // in-flight request's window origin (unwedge rollback)
    private var liveSummaryBusyTicks = 0
    /// The right-side pane opens with the first landed summary ("양이 모이면
    /// 열리면서") and lives only through the recording.
    var liveSummaryPaneVisible: Bool {
        LiveFeatureWiring.liveSummary && liveSummaryText != nil && liveSummaryEnabled
    }

    /// Host-facing live coach / teleprompter toggle (agenda coverage + unanswered
    /// questions + pace). Pure on-device compute, no extra model — safe on any
    /// machine (unlike the live rail's 16GB gate). Persisted. Default OFF.
    var liveCoachEnabled: Bool = (UserDefaults.standard.object(forKey: "liveCoachEnabled") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(liveCoachEnabled, forKey: "liveCoachEnabled")
            if liveCoachEnabled { recomputeCoach() } else { stopLiveCoach() }
        }
    }

    /// Cached live-coach snapshot. The View renders THIS (a cheap struct read) instead
    /// of calling LiveCoach.compute() on every body render — body re-renders on every
    /// word event (40k+/hr) and the compute is O(transcript × keywords). We recompute
    /// only on a throttled cadence while recording (coachTimer, ~1Hz) plus on the
    /// discrete events that change its inputs (prepBrief load, rail append, finalize).
    private(set) var liveCoachState: LiveCoachState = .empty
    /// Derived agenda, cached — Retrieval.keywords over every prep item is non-trivial,
    /// and the agenda only changes when prepBriefData changes. Re-derived in
    /// updateCoachAgenda(), not on every recompute.
    private var coachAgenda: [CoachAgendaItem] = []
    private var liveCoachTimer: Timer?

    /// Re-derive the cached agenda from the current prep brief, then recompute state.
    /// Call when prepBriefData changes (the only input to agenda derivation).
    func updateCoachAgenda() {
        coachAgenda = prepBriefData.map { LiveCoach.agenda(from: $0) } ?? []
        recomputeCoach()
    }

    /// Recompute the cached coach snapshot from the current immutable inputs. Cheap
    /// relative to body-render frequency because it fires on a ~1Hz throttle while
    /// recording (or once per discrete input change), not per word event.
    func recomputeCoach() {
        guard liveCoachEnabled else { liveCoachState = .empty; return }
        liveCoachState = LiveCoach.compute(
            agenda: coachAgenda,
            spokenLines: transcript.lines.map(\.text),
            railQuestions: liveRailItems.filter { $0.kind == .question }.map(\.text),
            lines: transcript.lines)
    }

    /// Throttled recompute loop: while recording, refresh the coach at ~1Hz so the
    /// agenda-coverage / unanswered-question / pace readout tracks the live transcript
    /// without recomputing on every one of the 40k+ word events in an hour.
    private func startLiveCoach() {
        liveCoachTimer?.invalidate(); liveCoachTimer = nil
        guard liveCoachEnabled else { return }
        recomputeCoach()
        liveCoachTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeCoach() }
        }
    }

    private func stopLiveCoach() {
        liveCoachTimer?.invalidate(); liveCoachTimer = nil
        if !liveCoachEnabled { liveCoachState = .empty }
    }
    private(set) var liveRailItems: [RailItem] = []
    private(set) var liveRailBusy = false
    private var liveRailBusyTicks = 0          // stale-guard: reset busy if the engine never replies
    private var liveRailTimer: Timer?
    private var liveRailLastCount = 0

    /// "A.I 요약" — when on, a session finish also generates the on-device summary
    /// and saves it as a SEPARATE "<base> 요약.md" (never embedded in the transcript).
    /// Default off; persisted.
    var autoSaveSummary: Bool = (UserDefaults.standard.object(forKey: "autoSaveSummary") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(autoSaveSummary, forKey: "autoSaveSummary") }
    }
    /// Resolved auto-save folder: persisted choice, else Documents, else home.
    /// Static so both `autoSaveFolder` and `workspace` can seed from it without
    /// a self-reference during stored-property init.
    static func defaultSaveFolder() -> URL {
        if let p = UserDefaults.standard.string(forKey: "autoSaveFolder") { return URL(fileURLWithPath: p) }
        // Own subfolder, NOT ~/Documents root: the workspace explorer walks this
        // tree, and a user's iCloud-synced Documents is huge + full of evicted
        // placeholder files whose open() blocks on download (observed UI hangs).
        // App-written files in our own folder are always locally present.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = docs.appendingPathComponent("madi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var autoSaveFolder: URL = SessionController.defaultSaveFolder() {
        didSet {
            UserDefaults.standard.set(autoSaveFolder.path, forKey: "autoSaveFolder")
            workspace.setRoot(autoSaveFolder)   // explorer follows the save root
        }
    }
    /// The save folder as an IDE-style tree for the workspace explorer. Declared
    /// after `autoSaveFolder` so its didSet (which references this) only fires on
    /// post-init reassignment, never during init.
    let workspace = WorkspaceTree(root: SessionController.defaultSaveFolder())
    /// Last auto-saved file (UI confirmation); cleared when a new session starts.
    private(set) var lastAutoSaved: URL? = nil

    /// Write the transcript as Markdown into the auto-save folder. File-mode names
    /// after the source file; live recordings get a timestamped "회의" name. Never
    /// overwrites (appends " 2", " 3"…). Failures are non-fatal (manual export
    /// still works). Not sandboxed, so a plain path write is enough.
    private func autoSaveMarkdown() {
        guard autoSaveEnabled, !transcript.lines.isEmpty else { return }
        // Same session, already snapshotted → overwrite in place (periodic saves
        // + the final save all land in ONE file; reset() clears lastAutoSaved so
        // the next session gets a fresh name).
        if let existing = lastAutoSaved {
            try? FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Exporters.markdown(transcript.lines, names: speakerNames)
                .write(to: existing, atomically: true, encoding: .utf8)
            return
        }
        let base: String
        if fileName.isEmpty {
            base = TitleGenerator.fallbackTitle(date: Date())   // "회의 yyyy-MM-dd HHmm"
        } else {
            base = (fileName as NSString).deletingPathExtension
        }
        // The save folder can disappear under us (moved, renamed, iCloud
        // eviction) and write(to:) then fails silently in the catch below —
        // observed 2026-09-06: three live sessions produced no autosave at all
        // because ~/Documents/Madi no longer existed. Recreate it every time.
        try? FileManager.default.createDirectory(at: autoSaveFolder, withIntermediateDirectories: true)
        var url = autoSaveFolder.appendingPathComponent(base).appendingPathExtension("md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = autoSaveFolder.appendingPathComponent("\(base) \(n)").appendingPathExtension("md"); n += 1
        }
        do {
            try Exporters.markdown(transcript.lines, names: speakerNames)
                .write(to: url, atomically: true, encoding: .utf8)
            lastAutoSaved = url
            workspace.reload()   // surface the new .md in the explorer
        } catch { /* non-fatal — manual export remains available */ }
    }

    /// Crash insurance: snapshot the transcript every 30s while a session is
    /// accumulating lines (live recording OR file transcription), so a crash or
    /// force-quit mid-meeting loses at most the last half minute. finalizeOnce's
    /// save then overwrites the same file with the final text.
    private func startPeriodicAutosave() {
        periodicSaveTask?.cancel()
        periodicSaveTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                switch phase {
                case .recording, .paused, .processing: autoSaveMarkdown()
                default: return   // session left the accumulating states
                }
            }
        }
    }

    /// Write the AI summary as its OWN file next to the transcript: "<base> 요약.md".
    /// Base is taken from the just-saved transcript URL so the collision suffix
    /// matches (e.g. "회의 … 2.md" → "회의 … 2 요약.md", not "회의 … 요약 2.md").
    private func autoSaveSummaryMarkdown(_ summary: String) {
        guard autoSaveEnabled, let transcriptURL = lastAutoSaved else { return }
        let base = transcriptURL.deletingPathExtension().lastPathComponent
        var url = autoSaveFolder.appendingPathComponent("\(base) 요약").appendingPathExtension("md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = autoSaveFolder.appendingPathComponent("\(base) 요약 \(n)").appendingPathExtension("md"); n += 1
        }
        let body = "# \(base) — 회의 요약\n\n\(summary)\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            workspace.reload()   // surface the new 요약 .md in the explorer
        } catch { /* non-fatal */ }
    }

    /// Kick off summary generation at session end for the "A.I 요약" auto-save.
    /// Silent no-op if the summary model isn't installed (no error UI for a
    /// background save) — the result lands via the onResult "summary" handler.
    private func autoSummarizeForSave() {
        guard !transcript.lines.isEmpty, !summarizing, let s = ensureSummaryEngine() else { return }
        summarizing = true; meetingSummary = nil
        s.summarize(lines: attributedLines, template: summaryTemplate,
                    styleSuffix: meetingMode.config.summaryPromptSuffix)
    }

    /// Persistent per-speaker voiceprints. When you name a speaker, their centroid
    /// (dumped by the engine to <dir>/.last/spk<id>.vec at session end) is enrolled
    /// as <name>.vec; the next live session loads it and auto-labels that voice —
    /// "김부장" recognized across meetings, fully on-device. (live/stream only)
    let voiceprintsDir: URL = {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Madi/voiceprints", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Rename a speaker (applies to all their lines + exports). Empty clears it
    /// back to "Speaker N". Naming also ENROLLS the voiceprint so the voice is
    /// recognized in future sessions (if the engine dumped this session's centroid).
    func renameSpeaker(_ id: Int, to name: String) {
        // The Unknown bucket (미확인) is not a person: never name or enroll it.
        guard id != SpeakerID.unknown else { return }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { speakerNames[id] = nil; pendingEnrollment.remove(id: id); autoRecognizedSpeakers.remove(id); return }
        speakerNames[id] = t
        // BETA: voiceprints are unwired — naming a speaker labels THIS transcript
        // only, it never enrolls a voice (see Self.voiceprintsEnabled).
        guard Self.voiceprintsEnabled else { return }
        // BUFFER, don't enroll now: the engine dumps this session's centroid to
        // .last/spk<id>.vec only after flush, so an immediate copy finds no source
        // and silently no-ops. finalizeOnce() drains this after engine flush.
        pendingEnrollment.add(id: id, name: t)
        // Still attempt an immediate enroll: in a re-opened/finished session a
        // centroid may already exist, and enrollVoiceprint() is a safe no-op when
        // it doesn't. The deferred drain covers the live-recording case.
        enrollVoiceprint(speaker: id, name: t)
    }

    /// Copy this session's speaker centroid (.last/spk<id>.vec) to <name>.vec so the
    /// next live session recognizes the voice. No-op if no centroid was dumped
    /// (e.g. file-mode transcription, or the speaker never stabilized).
    private func enrollVoiceprint(speaker id: Int, name: String) {
        guard Self.voiceprintsEnabled else { return }   // BETA: unwired
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let src = voiceprintsDir.appendingPathComponent(".last/spk\(id).vec")
        let dst = voiceprintsDir.appendingPathComponent("\(safe).vec")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    private var engine: EngineProcess?
    var debugMemTask: Task<Void, Never>? = nil   // debug bundle memory sampler
    private let capture = AudioCapture()

    private var isError: Bool { if case .error = phase { return true }; return false }
    private var recordingStartAdmission: RecordingStartAdmission.State {
        switch phase {
        case .idle: return .idle
        case .done: return .done
        case .error: return .error
        case .countingDown(let value): return .countdown(value)
        default: return .busy
        }
    }

    /// T12: per-segment language re-probe whitelist = TRANSLATE TARGETS ∪ INPUT
    /// LANGUAGE. The old "exactly {Korean, X}" pair NEVER included the spoken
    /// (input) language when it wasn't a target — with {中,韓} targets an EN
    /// speaker was force-labeled KO/ZH every segment and transcribed as Korean
    /// hallucinations ("일요일…", 2026-07-13 폭파). The engine additionally always
    /// keeps its session-detected language in the probe, so 자동 input works too.
    /// Any 2..4 distinct languages activate the re-probe; <2 = plain lock/auto.
    private var langCandidatePair: [Int] {
        let tok: [String: Int] = ["English": 50259, "Chinese": 50260, "Korean": 50264, "Japanese": 50266]
        var set = Set(translateTargets.compactMap { tok[$0] })
        if let input = languageTokenID { set.insert(input) }
        return set.count >= 2 ? set.sorted() : []
    }

    /// The original clinic bidirectional declaration ({Korean, X} targets) —
    /// kept as the S1 voiceprint-ANCHOR trigger only, so widening the language
    /// whitelist above doesn't silently change diarization behavior.
    private var isBidirectionalClinicPair: Bool {
        translateTargets.count == 2 && translateTargets.contains("Korean")
    }

    func makeConfig() -> EngineProcess.Config {   // internal: SessionController+Debug reads it for the manifest
        EngineProcess.Config(
            binaryURL: Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/transcribe"),
            modelURL: AssetManifest.modelURL,
            bpeURL: AssetManifest.bundledBPE,
            assetsDir: AssetManifest.bundledAssetsDir,
            diarize: diarize, osd: osd,
            languageTokenID: languageTokenID, maxSpeakers: speakerCount.maxSpeakers,
            fixedK: speakerCount.fixedK,
            // BETA: nil ⇒ engine gets no VOICEPRINTS dir → no enrolled-voice load,
            // no per-speaker centroid dump, no SPKNAME auto-naming (the 오인식 source).
            vadProb: speakerCount.vadProb,
            voiceprintsDir: Self.voiceprintsEnabled ? voiceprintsDir : nil,
            streamWavRoots: [capture.segmentDirectory],
            langCandidates: langCandidatePair,
            anchorVoiceprints: Self.voiceprintsEnabled && isBidirectionalClinicPair && hasEnrolledVoiceprints,
            encoderF16Cache: ProcessInfo.processInfo.physicalMemory >= 24 * (1 << 30),
            // S4: the user's confirmed corrections bias the DECODER, not just the
            // post-hoc text. Same opt-in gate as substitution — a mismatched
            // glossary measurably hurts (docs/ENGINE_EVAL.md S4).
            biasTerms: PersonalVocabulary.biasTerms(glossary))
    }

    /// Any enrolled .vec voiceprints on disk? (S1 anchor precondition)
    private var hasEnrolledVoiceprints: Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: voiceprintsDir.path) else { return false }
        return items.contains { $0.hasSuffix(".vec") }
    }

    // MARK: session lifecycle

    private var countdownTask: Task<Void, Never>?
    private var captureStartTask: Task<Void, Never>?
    // Safety net: if the engine never reports ready (rare crash/hang), surface a
    // Korean error instead of an infinite "모델 로딩…" spinner.
    private var engineStartTimeoutTask: Task<Void, Never>?
    // Crash insurance: while a session accumulates lines, snapshot the .md every
    // 30s so a crash/force-quit mid-meeting loses at most the last half minute.
    private var periodicSaveTask: Task<Void, Never>?
    // Dead-mic alarm: recording but no audible input (RMS ≤ 0.02) for 15s —
    // drives the warning banner so a muted/wrong mic doesn't eat a whole meeting.
    private(set) var micSilent = false
    private var lastAudibleAt = Date()
    private var silenceWatchTask: Task<Void, Never>?

    /// #4 — a brief 3·2·1 countdown before the mic opens, so the user can get
    /// ready; recording starts the instant it hits 0. Cancellable mid-count.
    func startCountdown(from n: Int = 3) {
        guard phase == .idle || phase == .done || isError else { return }
        audioPermissionIssue = nil
        guard AssetManifest.modelIsValid() else {
            phase = .error("음성 인식 모델이 준비되지 않았어요. 설정(⌘,) → 모델에서 먼저 다운로드해주세요.")
            return
        }
        preflightMicrophonePermission(from: n)
    }

    /// All permission UI happens before 3·2·1. A countdown is a promise that
    /// capture is ready to start, never a prelude to a surprise TCC dialog.
    private func preflightMicrophonePermission(from n: Int) {
        guard AudioPermissionPolicy.requires(.microphone, for: audioSource) else {
            preflightSystemAudioPermission(from: n)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            showMicrophonePermissionError()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.preflightSystemAudioPermission(from: n) }
                    else { self.showMicrophonePermissionError() }
                }
            }
            return
        default:
            break
        }
        preflightSystemAudioPermission(from: n)
    }

    private func preflightSystemAudioPermission(from n: Int) {
        guard AudioPermissionPolicy.requires(.systemAudio, for: audioSource) else {
            beginCountdown(from: n)
            return
        }
        if CGPreflightScreenCaptureAccess() {
            beginCountdown(from: n)
            return
        }

        // The system prompt now appears before the countdown. Apple requires a
        // relaunch after first approval before ScreenCaptureKit can capture.
        if CGRequestScreenCaptureAccess() {
            audioPermissionIssue = .systemAudioRestartRequired
            phase = .error(permissionText(
                "시스템 오디오 권한을 허용했어요. 적용을 위해 Madi를 한 번 다시 시작해주세요.",
                "System audio access is allowed. Restart Madi once to apply it.",
                "システムオーディオのアクセスを許可しました。適用するため Madi を再起動してください。"))
        } else {
            showSystemAudioPermissionError()
        }
    }

    private func showMicrophonePermissionError() {
        audioPermissionIssue = .microphoneDenied
        phase = .error(permissionText(
            "녹음 전에 마이크 권한이 필요해요. 시스템 설정에서 Madi를 허용한 뒤 다시 시도해주세요.",
            "Madi needs microphone access before recording. Allow it in System Settings, then try again.",
            "録音前にマイクへのアクセスが必要です。システム設定で Madi を許可してから、もう一度お試しください。"))
    }

    private func showSystemAudioPermissionError() {
        audioPermissionIssue = .systemAudioDenied
        phase = .error(permissionText(
            "녹음 전에 시스템 오디오 권한이 필요해요. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 Madi를 허용한 뒤 다시 시작해주세요.",
            "Madi needs system audio access before recording. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then restart Madi.",
            "録音前にシステムオーディオへのアクセスが必要です。システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオで Madi を許可してから再起動してください。"))
    }

    private func permissionText(_ ko: String, _ en: String, _ ja: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "uiLanguage") ?? UILanguage.ko.rawValue
        return (UILanguage(rawValue: raw) ?? .ko)(ko, en, ja)
    }

    func openAudioPermissionSettings() {
        let pane = audioPermissionIssue == .microphoneDenied
            ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func relaunchAfterPermissionGrant() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func beginCountdown(from n: Int) {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for k in stride(from: n, through: 1, by: -1) {
                phase = .countingDown(k)
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // 1s/tick — clock cadence
                if Task.isCancelled { return }
            }
            countdownTask = nil
            start()
        }
    }
    func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil
        phase = .idle
    }

    /// #3 — clear the current transcript and return to idle WITHOUT the
    /// stop→start dance. Only when not actively capturing.
    func reset() {
        guard phase == .done || phase == .idle || isError else { return }
        terminateTranscriptionEngines()
        countdownTask?.cancel(); countdownTask = nil
        captureStartTask?.cancel(); captureStartTask = nil
        capture.abort()
        audioPermissionIssue = nil
        periodicSaveTask?.cancel(); periodicSaveTask = nil
        silenceWatchTask?.cancel(); silenceWatchTask = nil; micSilent = false
        meterLevel = 0; level = 0
        recordStartedAt = nil; recordEndedAt = nil; pausedAt = nil; pausedAccum = 0
        transcript.reset()
        speakerNames = [:]
        userEditedLines.removeAll()
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedHash.removeAll(); stablePassHash.removeAll(); coalescedSource.removeAll(); coalescedRevision.removeAll(); sttTurnarounds.removeAll(); translateQueuedLines = 0; engineDiag = EngineDiagnostics()
        interimCache.clear()
        clearSummary()
        fileName = ""; chunksDone = 0; chunksTotal = 0
        livePartial = ""; clearInterimCaption()
        TranslationStabilityMetrics.shared.reset()
        streamingTranslation = nil; translateQueueDepth = 0
        backlogKeys.removeAll(); translateBacklog = 0
        backfillPendingKeys.removeAll(); backfillRemaining = 0
        interimRequests.removeAll(); activeInterimID = nil
        segmentAudio.removeAll(); decodeRiskRanges.removeAll(); reconcileNote = nil; reconciling = false; languageCorrectionsPending = 0
        reconcileSpeakerNamesBefore = nil; reconcileAutoNamesBefore = nil
        stopWatchdog(); segQueue.removeAll(); segmentsInFlight = 0; coverageGaps.removeAll(); hangRecoveries = 0
        phase = .idle
    }

    /// X button on the loaded-file chip (Figma node 30:118): drop the staged/
    /// in-flight file and return to idle. Unlike reset(), this also tears down
    /// an in-progress file transcription (phase .processing/.flushing) — the
    /// user explicitly asked to cancel, not just clear a finished result.
    func cancelFile() {
        guard sourceMediaURL != nil else { return }
        if phase == .processing || phase == .flushing {
            engine?.terminate(); engine = nil
        }
        if phase != .done && phase != .idle && !isError { phase = .done }
        reset()
    }

    /// Re-open an archived transcript .md (clicked in the workspace explorer)
    /// into the view. Static read of a finished meeting — replaces the current
    /// transcript; only allowed when idle/done/error so it never interrupts a
    /// live capture. No-op if the file isn't a parseable transcript.
    func openArchived(_ url: URL) {
        guard phase == .idle || phase == .done || isError else { return }
        guard let parsed = TranscriptArchive.parse(url) else { return }
        reset()
        speakerNames = parsed.names
        autoRecognizedSpeakers.removeAll()
        transcript.load(parsed.lines)
        fileName = url.lastPathComponent
        phase = .done
    }

    /// #2 — commit an inline edit to a (committed) line and, if live translation
    /// is on, re-translate the edited text so the translation tracks the edit.
    /// Review flow: replace one low-confidence word. Learns the swap for future
    /// auto-correction and re-translates the line if live translation is on.
    func editWord(_ lineID: UUID, index: Int, to newText: String) {
        let oldText = transcript.lines.first(where: { $0.id == lineID })
            .flatMap { index >= 0 && index < $0.words.count ? $0.words[index].text : nil }
        guard transcript.editWord(lineID, index: index, to: newText) else { return }
        if let old = oldText, old != newText, !newText.trimmingCharacters(in: .whitespaces).isEmpty {
            for pair in PersonalVocabulary.diff(before: old, after: newText) {
                glossary.learn(wrong: pair.wrong, right: pair.right)
            }
            glossary.save()
        }
        translatedHash[lineID] = nil
        if let line = transcript.lines.first(where: { $0.id == lineID }) { translateLine(line) }
    }

    func editLine(_ id: UUID, to newText: String) {
        // Remember it as the user's, so the glossary/number passes leave it alone.
        userEditedLines.insert(id)
        _ = applyTextCorrection(id, to: newText, expectedRevision: nil, learn: true)
    }

    /// Single correction transaction for manual edits, vocabulary fixes and AI
    /// re-decodes: revision guard → source mutation → stale translation purge →
    /// direction-routed retranslation. No caller may bypass these invariants.
    @discardableResult
    private func applyTextCorrection(_ id: UUID, to newText: String,
                                     expectedRevision: UInt64?, learn: Bool) -> Bool {
        guard let before = transcript.lines.first(where: { $0.id == id }) else { return false }
        guard transcript.editLine(id, newText, expectedRevision: expectedRevision) else { return false }
        if learn {
            let pairs = PersonalVocabulary.diff(before: before.text, after: newText)
            if !pairs.isEmpty {
                for p in pairs { glossary.learn(wrong: p.wrong, right: p.right) }
                glossary.save()
            }
        }
        translatedHash[id] = nil
        if let line = transcript.lines.first(where: { $0.id == id }) { translateLine(line) }
        return true
    }

    /// User correction of model translation. Source provenance remains bound to
    /// the current source revision and round-trips through Markdown/JSON.
    func editTranslation(_ id: UUID, lang: String, to newText: String) {
        _ = transcript.editTranslation(id, lang: lang, newText)
    }

    func start() {
        // The countdown intentionally calls start() while phase is still
        // .countingDown(1). Reject every other busy phase, but admit that exact
        // terminal tick; otherwise the UI remains frozen on “1” forever.
        guard RecordingStartAdmission.allows(recordingStartAdmission) else { return }
        guard AssetManifest.modelIsValid() else {
            phase = .error("음성 인식 모델이 준비되지 않았어요. 설정(⌘,) → 모델에서 먼저 다운로드해주세요."); return
        }
        // A failed capture can leave a fully resident engine behind while phase
        // moves to .error. Retrying used to overwrite `engine` and orphan that
        // process (including its Metal allocations). Always retire any previous
        // main/preview pair before installing the next session's processes.
        terminateTranscriptionEngines()
        captureStartTask?.cancel(); captureStartTask = nil
        capture.abort()
        audioPermissionIssue = nil
        transcript.reset()
        debugSessionStart()   // debug bundle (docs/DEBUG_MODE.md)
        speakerNames = [:]
        userEditedLines.removeAll()
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedHash.removeAll(); stablePassHash.removeAll(); coalescedSource.removeAll(); coalescedRevision.removeAll(); sttTurnarounds.removeAll(); translateQueuedLines = 0; engineDiag = EngineDiagnostics()
        interimCache.clear()
        backlogKeys.removeAll(); translateBacklog = 0
        backfillPendingKeys.removeAll(); backfillRemaining = 0
        interimRequests.removeAll(); activeInterimID = nil
        clearSummary()
        DNAEngineBroker.shared.onBusyChange = { [weak self] busy in
            guard let self else { return }
            self.dnaBusy = busy
            self.updatePreviewAdmission()
        }
        streamingTranslation = nil; translateQueueDepth = 0; lastCommitAt = Date()
        segmentAudio.removeAll(); decodeRiskRanges.removeAll(); reconcileNote = nil; reconciling = false; languageCorrectionsPending = 0
        reconcileSpeakerNamesBefore = nil; reconcileAutoNamesBefore = nil
        // T11 prewarm: spawn the translate engine during the dead time between
        // pressing record and the first utterance (READY takes 1.4-3.5 s) so the
        // first caption's translation doesn't pay the cold start.
        _ = ensureTranslateEngine()
        // Live-summary prewarm: with translation OFF the line above spawns
        // nothing (targets gate), and the summary's first tick would cold-launch
        // the 4B mid-recording — model load competing with Whisper decode. Same
        // dead time, same resident broker; a no-op when translation already
        // warmed it or the gate/model rules the feature out.
        if translateTargets.isEmpty, Self.liveRailCapable,
           liveSummaryEnabled, LiveFeatureWiring.liveSummary {
            _ = ensureSummaryEngine()
        }
        // Prefill from the live calendar event. ContentView observes calendar.event.id
        // and calls ensurePrepBrief() on change, so we do NOT call it here too (that
        // double-ran the headless aggregation and raced two detached tasks).
        if Self.calendarPrepEnabled { Task { await calendar.loadCurrentEvent() } }
        startLiveRail()                              // throttled live action extraction (≥16GB + on)
        startLiveSummary()                           // rolling 요약 tab (≥16GB + on, lowest lane)
        startLiveCoach()                             // throttled coach recompute (~1Hz while recording)
        phase = .engineStarting

        LiveFeatureWiring.speakerIslandAbsorption = LiveFeatureWiring.islandAbsorption(for: languageTokenID)
        LiveFeatureWiring.weakLabelContinuation = LiveFeatureWiring.weakLabelContinuation(for: languageTokenID)
        let e = EngineProcess(config: makeConfig())
        e.delegate = self
        e.onDiagnosticLine = { [weak self] line in self?.engineDiag.ingest(line) }
        engine = e

        capture.inputDeviceID = inputDeviceID  // bind chosen mic before start
        capture.source = audioSource           // mic / system / both
        capture.onError = { [weak self] msg in
            guard let self else { return }
            guard AudioPermissionPolicy.requires(.systemAudio, for: self.audioSource) else { return }
            self.capture.abort()
            self.terminateTranscriptionEngines()
            if !CGPreflightScreenCaptureAccess() {
                self.showSystemAudioPermissionError()
            } else {
                self.phase = .error(self.permissionText(
                    "시스템 오디오 연결이 중단됐어요. (\(msg))",
                    "The system audio connection stopped. (\(msg))",
                    "システムオーディオの接続が停止しました。(\(msg))"))
            }
        }
        // live FELT-latency knob — applied before the segmenter resets in capture.start()
        let win = effectiveWindowSeconds   // 2개+ 번역 시 정확(10초) 강제
        capture.segmentSeconds = win
        capture.firstSegmentSeconds = min(1.5, win) // AudioCapture 기본과 동기 (AUDIO_CTX=auto로 짧은 창 디코드 ~0.3s)
        capture.overlapSeconds = min(3, max(1, win * 0.3))
        capture.onSegment = { [weak self] offset, url, hadSpeech in
            guard let self else { return }
            self.segmentAudio.append((offset, url))   // retain for AI re-transcription
            self.segQueue.append(SegJob(offset: offset, url: url, hadSpeech: hadSpeech, retried: false, fedAt: Date()))
            self.segmentsInFlight = self.segQueue.count
            self.updatePreviewAdmission()
            self.engine?.feed(offset: offset, wav: url)
        }
        capture.onLevel = { [weak self] lvl in
            guard let self else { return }
            self.level = lvl
            if lvl > 0.02 { self.lastAudibleAt = Date() }
            // Peak-hold: jump up instantly, decay over ~0.5s (frame-rate free).
            let now = Date()
            let dt = now.timeIntervalSince(self.lastMeterAt)
            self.lastMeterAt = now
            let release = Float(exp(-dt / 0.5))
            self.meterLevel = max(lvl, self.meterLevel * release)
        }
        segQueue.removeAll(); segmentsInFlight = 0; wordsSinceSegStart = 0
        coverageGaps.removeAll(); hangRecoveries = 0
        startWatchdog()

        // Streaming preview reuses the main resident process. Tiny clips must
        // never auto-detect independently: with a selected language arm now; in
        // auto mode wait for the committed lane's [lang] lock below.
        livePartial = ""; clearInterimCaption()
        TranslationStabilityMetrics.shared.reset()   // P6: per-session ledger
        registerTerminateFlush()                     // ⌘Q must never eat the numbers
        if livePreviewEnabled {
            preview.onWords = { [weak self] words, _, forced in
                guard let self else { return }
                // PreviewTrim (2026-09-10): the preview window opens 1.5 s before
                // the displayed text ends, so its first words repeated the last
                // shown ones in another spelling ("…별이 파편이 사방" then
                // "별 파편이 사방으로 …" in gray) at every window boundary. The
                // shown words inside the window are the forced prefix, so the
                // preview echoes them verbatim and only the new tail is shown.
                let t = PreviewTrim.visibleTail(words: words, forced: forced)
                guard t.count <= Self.maxLivePartialChars else { return }
                if !t.isEmpty { self.livePartial = t }
            }
            capture.onPreview = { [weak self] url, offset in self?.preview.feed(wav: url, offset: offset) }
            if languageTokenID != nil { startPreviewLane() }
        } else {
            capture.onPreview = nil
        }

        do { try e.start() }
        catch {
            terminateTranscriptionEngines()
            phase = .error("전사 엔진을 시작하지 못했어요: \(error.localizedDescription)")
        }

        engineStartTimeoutTask?.cancel()
        engineStartTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if Task.isCancelled { return }
            if case .engineStarting = phase {
                engine?.terminate(); engine = nil
                preview.stop(); livePartial = ""
                phase = .error("엔진 시작이 너무 오래 걸려요. 다시 시도해주세요 — 계속되면 앱을 재시작해주세요.")
            }
        }
    }

    /// Drag-&-drop: transcribe an audio FILE through the same resident engine +
    /// pipeline as the mic (diarization, OSD, confidence, exports all reused).
    /// The file is fed off the main actor (FileFeeder) so a long file never
    /// freezes the UI. Ignored while a session is already busy.
    func transcribeFile(_ url: URL) {
        guard phase == .idle || phase == .done || isError else { return }
        guard AssetManifest.modelIsValid() else {
            phase = .error("음성 인식 모델이 준비되지 않았어요. 설정(⌘,) → 모델에서 먼저 다운로드해주세요."); return
        }
        terminateTranscriptionEngines()
        transcript.reset()
        speakerNames = [:]
        userEditedLines.removeAll()
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedHash.removeAll(); stablePassHash.removeAll(); coalescedSource.removeAll(); coalescedRevision.removeAll(); sttTurnarounds.removeAll(); translateQueuedLines = 0; engineDiag = EngineDiagnostics()
        interimCache.clear()
        clearSummary()
        fileName = url.lastPathComponent
        sourceMediaURL = url        // arm click-to-play (original timeline matches)
        chunksDone = 0; chunksTotal = 0
        phase = .processing
        debugSessionStart()   // file sessions get a debug bundle too (the byshu-01 cascade had none to read)

        // Decode ANY container (m4a/mp3/aac/flac/wav…) to a normalized 16k PCM WAV
        // off the main actor first — the engine's file reader only accepts PCM WAV.
        DispatchQueue.global(qos: .userInitiated).async {
            let wav: URL
            do { wav = try AudioDecode.toWav16k(url) }
            catch {
                let name = url.lastPathComponent
                Task { @MainActor in
                    let why = AudioDecode.reason(error) ?? "지원하지 않는 형식이거나 손상된 파일입니다"
                    self.phase = .error("'\(name)' 을(를) 열 수 없습니다 — \(why).")
                }
                return
            }
            Task { @MainActor in self.runFileEngine(wav) }
        }
    }

    private func runFileEngine(_ wav: URL) {
        LiveFeatureWiring.speakerIslandAbsorption = LiveFeatureWiring.islandAbsorption(for: languageTokenID)
        LiveFeatureWiring.weakLabelContinuation = LiveFeatureWiring.weakLabelContinuation(for: languageTokenID)
        guard phase == .processing else { return }   // user may have navigated away
        var cfg = makeConfig()
        cfg.fileURL = wav                  // native FILE mode (fast batched + offline diar)
        let e = EngineProcess(config: cfg)
        e.delegate = self
        e.onDiagnosticLine = { [weak self] line in self?.engineDiag.ingest(line) }
        engine = e
        do { try e.start() }
        catch { phase = .error("전사 엔진을 시작하지 못했어요: \(error.localizedDescription)") }
        startPeriodicAutosave()   // file transcription accumulates lines too
    }

    /// Pause live capture — the mic stays warm; the paused span is dropped so the
    /// recording skips the break. No engine flush (the session continues).
    func pauseRecording() {
        guard phase == .recording else { return }
        capture.pause()
        pausedAt = Date()
        phase = .paused
    }
    func resumeRecording() {
        guard phase == .paused else { return }
        capture.resume()
        if let p = pausedAt { pausedAccum += Date().timeIntervalSince(p); pausedAt = nil }
        phase = .recording
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        recordEndedAt = Date()   // freeze the 총 시간 readout at the stop moment
        phase = .flushing
        capture.stop()          // flush final tail segment(s) into the engine
        engine?.flush()         // → SPKFIX/SPKOV → <<FLUSH_END>>
        // NOTE: do NOT clear interimCache here. finalizeOnce() runs later (post-flush
        // via engineDidFlush) and reuses the cached interim translations for the final
        // committed lines, then clears. Clearing here would defeat that final-line reuse.
    }

    // MARK: EngineProcessDelegate

    // live mic path only (file mode never emits `[stream] ready`)
    func engineDidBecomeReady() {
        engineStartTimeoutTask?.cancel(); engineStartTimeoutTask = nil
        // W2 재시작 엔진의 ready는 무시 — capture.start() 재진입은 installTap
        // 중복 크래시 + 세그먼터 타임라인/파일 리셋을 일으킨다 (역검증
        // app-state-1/watchdog-conc-0). 캡처는 최초 기동에서만 시작.
        guard phase == .engineStarting || phase == .ready else { return }
        phase = .ready
        captureStartTask?.cancel()
        captureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start()
                guard !Task.isCancelled, self.phase == .ready else {
                    self.capture.abort()
                    return
                }
                self.recordStartedAt = Date(); self.recordEndedAt = nil
                self.pausedAccum = 0; self.pausedAt = nil
                self.phase = .recording
                self.startPeriodicAutosave()
                self.startSilenceWatch()
            } catch {
                guard !Task.isCancelled else { return }
                self.capture.abort()
                self.terminateTranscriptionEngines()
                if AudioPermissionPolicy.requires(.systemAudio, for: self.audioSource),
                   !CGPreflightScreenCaptureAccess() {
                    self.showSystemAudioPermissionError()
                } else {
                    self.phase = .error(self.permissionText(
                        "오디오 입력을 시작하지 못했어요: \(error.localizedDescription)",
                        "Could not start audio input: \(error.localizedDescription)",
                        "オーディオ入力を開始できませんでした: \(error.localizedDescription)"))
                }
            }
            self.captureStartTask = nil
        }
    }

    /// Poll every 3s while recording: 15s+ without audible input flips micSilent
    /// (the banner). Paused spans don't count — the meter is forced to 0 there.
    private func startSilenceWatch() {
        lastAudibleAt = Date()
        micSilent = false
        silenceWatchTask?.cancel()
        silenceWatchTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                switch phase {
                case .recording:
                    let silent = Date().timeIntervalSince(lastAudibleAt) > 15
                    if silent != micSilent { micSilent = silent }
                case .paused:
                    lastAudibleAt = Date()
                    if micSilent { micSilent = false }
                default:
                    if micSilent { micSilent = false }
                    return
                }
            }
        }
    }

    func engine(didEmit event: EngineEvent) {
        lastEngineActivityAt = Date()   // W2 하트비트 (모든 엔진 이벤트 = 진행 증거)
        if preview.consume(event) { return }
        switch event {
        case .progressTotal(let n): chunksTotal = n
        case .progressChunk(let k): chunksDone = max(chunksDone, k)
        case .wordSectionBegin:
            livePartial = ""; transcript.ingest(event)  // committed → drop interim
            // P1: window boundary — the carryover pair stays visible (P3), but the
            // NEXT window's first candidate must replace it freely, not be judged
            // as a "divergence" from the finished sentence.
            interimDisplay.reset()            // P9: display agreement per window
            TranslationStabilityMetrics.shared.cancel(.captionFirstPaint, key: "window")
            lastInterimRequestedSource = ""   // P2: new window, gate starts fresh
            interimSourceGate.reset()         // P8: agreement restarts per window
            committedInterimSource = ""
            interimSentences.reset()          // P12: sentence scope per window
            frozenInterim = [:]; currentInterimDisplay = [:]; currentInterimSentence = ""
            lastCommitAt = Date()                        // D19 commit-cadence ring
            translateStableLines()                       // translate now-stable prior lines
        case .languageDetected(let tok):
            // Auto-detection belongs to the committed lane. PREVIEW now reuses
            // that same in-process language state (no tiny-clip re-probe).
            _ = tok
            if livePreviewEnabled { startPreviewLane() }
        case .speakerName(let id, let name):
            // a live speaker matched an enrolled voiceprint → auto-label (the user
            // can still override). Cross-session speaker re-identification.
            speakerNames[id] = name
            autoRecognizedSpeakers.insert(id)
        case .word(let t0, let t1, let text, let conf):
            // APPLY (live): correct a low-confidence recognized word against the
            // personal glossary before it enters the transcript. String-level —
            // no Word exists yet, so no id/translation to disturb.
            let fixed = PersonalVocabulary.correctIncomingText(text, conf: conf, glossary)
            transcript.ingest(fixed == text ? event : .word(t0: t0, t1: t1, text: fixed, conf: conf))
            wordsSinceSegStart += 1                      // W1 coverage signal
            // T2: queue a line the moment it stops being the last line (idempotent
            // via the hash gate) + arm the tail timeout for the last line itself.
            translateStableLines()
            scheduleTailTranslate()
        case .segmentEnd:
            // W1: one stream job finished. A segment that HAD speech but produced
            // zero words is a suspected miss — retry it once from its retained
            // wav; if it stays empty, surface a 누락 의심 marker.
            if !segQueue.isEmpty {
                let job = segQueue.removeFirst()
                sttTurnarounds.append(Date().timeIntervalSince(job.fedAt))
                if job.hadSpeech, wordsSinceSegStart == 0 {
                    // 백로그가 있으면 재시도는 무의미: 뒤 세그먼트가 먼저 커밋해
                    // WordMerger 워터마크가 이 구간을 지나가 복구 단어가 전량
                    // 폐기된다 (역검증 watchdog-conc-2). 그 경우 즉시 갭 기록.
                    if !job.retried, segQueue.isEmpty {
                        var retry = job; retry.retried = true; retry.fedAt = Date()
                        segQueue.append(retry)
                        engine?.feed(offset: job.offset, wav: job.url)
                    } else {
                        coverageGaps.append(job.offset)
                        debugWatchdog("w1-gap", ["offset": job.offset, "retried": job.retried, "queue": segQueue.count])
                    }
                }
            }
            wordsSinceSegStart = 0
            segmentsInFlight = segQueue.count
            updatePreviewAdmission()
        case .partial(let t0, let text):
            // in-decode hypothesis of the closed segment — better context than
            // the open-window PREVIEW text and converges to the committed line, so
            // it may overwrite; the next preview/commit supersedes it.
            // Defense-in-depth for the "폭파" (run-on hallucination): the engine now
            // freezes a runaway «partial», but drop any preview far longer than a
            // real ~10s window could hold (any language ≪ 512 chars) so a balloon
            // from any future/other emitter never reaches the caption + interim
            // translation. The clean rescue-committed line still lands normally.
            // PreviewTrim: the closed segment starts 1.5 s inside shown audio —
            // drop as many leading words as the transcript already shows there.
            let shown = PreviewTrim.trimByCount(text, dropping: transcript.displayedWords(since: t0).count)
            if !shown.isEmpty, shown.count <= Self.maxLivePartialChars { livePartial = shown }
        default: transcript.ingest(event)
        }
    }

    /// Structured decode evidence is authoritative for language-review targeting;
    /// stdout remains the rendering contract. Rescue, drop, or avg_logprob below
    /// the engine's −1.0 rescue threshold marks overlapping transcript lines ◇.
    func engine(didEmitStructured event: StructuredEvent) {
        guard case .segment(let info) = event else { return }
        if info.dropped || info.fallback != "none" || info.avgLogprob < -1.0 {
            decodeRiskRanges.append((start: info.t0, end: info.t1))
        }
    }

    func engineDidFlush() { finalizeOnce() }

    func engine(didTerminate code: Int32) {
        debugWatchdog("engine-exit", ["code": Int(code), "phase": "\(phase)"])
        // file mode exits 0 on its own after <<FLUSH_END>>; finalize if a late
        // exit beats the FLUSH_END line (finalizeOnce is idempotent).
        if code == 0 { finalizeOnce(); return }
        if phase != .done, phase != .flushing {
            preview.stop(); livePartial = ""; clearInterimCaption()
            engine = nil
            phase = .error("전사 엔진이 예기치 않게 종료되었어요 (코드 \(code)). 다시 시도해주세요.")
        }
    }

    /// Hard teardown for retry/reset/error paths. `EngineProcess.stop()` only
    /// requests FLUSH; these paths must release the process immediately because
    /// there may be no live session left to deliver <<FLUSH_END>>.
    private func terminateTranscriptionEngines() {
        engineStartTimeoutTask?.cancel(); engineStartTimeoutTask = nil
        captureStartTask?.cancel(); captureStartTask = nil
        engine?.delegate = nil
        engine?.terminate()
        engine = nil
        preview.stop()
    }

    private func startPreviewLane() {
        previewLaneStartedAt = Date(); previewAdmits = 0
        preview.start { [weak self] wav, windowStart in
            guard let self else { return "" }
            self.lastPreviewAdmitAt = Date(); self.previewAdmits += 1
            // S2: the P8 gate's AGREED prefix of this window's hypothesis rides
            // along; the engine forces it and decodes only the tail. PreviewTrim:
            // the words the transcript already SHOWS inside the window come
            // first, so the preview's echo of the overlap region is exactly the
            // black text and the gate's prefix extends it.
            let shown = self.transcript.displayedWords(since: windowStart).map(\.text)
            let forced = PreviewTrim.forcedPrefix(committed: shown, gate: self.interimSourceGate.committedText)
            DebugLog.shared?.emit("preview", "feed", ["windowStart": windowStart, "shownInWindow": shown.count,
                                                      "forcedChars": forced.count])
            self.engine?.feedPreview(wav: wav, forced: forced)
            return forced
        }
    }

    private func finalizeOnce() {
        guard phase != .done else { return }
        periodicSaveTask?.cancel(); periodicSaveTask = nil
        engineStartTimeoutTask?.cancel(); engineStartTimeoutTask = nil
        silenceWatchTask?.cancel(); silenceWatchTask = nil; micSilent = false
        meterLevel = 0; level = 0
        transcript.finalize()
        // APPLY (final): cement corrections on the committed lines. correctedLineText
        // is non-destructive — it returns the corrected display string, applied via
        // the existing line-id-keyed edit overlay so Word ids + async translations
        // (keyed by line.id) survive. Skips lines the user already edited.
        // Sweep every line, including the last one (which was still the live tail
        // and so never met the stable-line gate) and anything a late glossary rule
        // now covers.
        for line in transcript.lines { applyTextPasses(line) }
        engine?.terminate()
        // Drain mid-session names now that the engine has dumped its centroids
        // (.last/spk<id>.vec) on flush — THIS is the enrollment-timing fix.
        for p in pendingEnrollment.pending() { enrollVoiceprint(speaker: p.id, name: p.name) }
        pendingEnrollment.clear()
        engine = nil
        preview.stop(); livePartial = ""; clearInterimCaption()   // disarm PREVIEW lane + interim text
        phase = .done
        // Backfill: lines the live queue shed under load get re-translated now,
        // uncapped, so the on-screen transcript/scrollback is complete after stop
        // (the live captions themselves already moved on). backfillRemaining drives
        // the progress HUD; on 8GB the summary engine — which evicts translate —
        // waits for this to drain. (interimCache is still warm → O3 reuse.)
        // The stop-time flush below queues every remaining line at once, and
        // the live shed rule (secondary targets dropped past 6 queued turns)
        // has no deadline to protect any more: 0.3.26 Korean 11 min shed the
        // Japanese of 25 tail rows at stop and nothing backfilled them (the
        // idle backfill runs only while recording). No shedding after stop.
        translate?.maxPending = 0
        translate?.shedSecondaryTargetsAt = 0
        if let t = translate, !backlogKeys.isEmpty {
            backfillPendingKeys = Set(backlogKeys.filter { key in
                guard let line = transcript.lines.first(where: { $0.id == key.id }) else { return false }
                return lineHash(line.text) == key.sourceRevision
                    && routedTargets(for: line.text).contains(key.lang)
                    && line.translations[key.lang] == nil
            })
            let grouped = Dictionary(grouping: backfillPendingKeys, by: \.id)
            for (id, keys) in grouped {
                guard let line = transcript.lines.first(where: { $0.id == id }) else { continue }
                translatedHash[line.id] = nil
                translateLine(line, forceTargets: Set(keys.map(\.lang)))
                // FAQ/interim caches resolve synchronously and do not produce a
                // completion callback, so close those exact work keys here.
                let valid = transcript.validTranslationLanguages(id, sourceRevision: lineHash(line.text))
                for key in keys where valid.contains(key.lang) { backfillPendingKeys.remove(key) }
            }
            backfillRemaining = backfillPendingKeys.count
            backlogKeys.removeAll(); translateBacklog = 0
        }
        translateStableLines(includingLast: true)  // translate the final line(s) too
        interimCache.clear()   // O3: final lines just consulted the cache — now wipe it (session boundary)
        // P6: print the ledger NOW (a ⌘Q inside the 10s window swallowed two
        // real sessions' numbers), and again after the stop-time backfill has
        // had time to drain. NE < 0.2 is the target band.
        let finalTag = "@final " + sttStatsTag()
        TranslationStabilityMetrics.shared.flushSummary(finalTag)
        debugSessionEnd(tag: finalTag)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            TranslationStabilityMetrics.shared.flushSummary("@settled")
        }
        stopLiveRail()       // recording ended — keep the accumulated rail for review
        stopLiveSummary()    // pane closes with the recording; 정식 요약 takes over
        stopWatchdog()
        segQueue.removeAll(); segmentsInFlight = 0
        stopLiveCoach(); recomputeCoach()   // stop the 1Hz loop, snapshot the final transcript once
        calendar.matchToSpeakers(speakerNames)   // attendee ↔ speaker match + 결석 flag
        autoSaveMarkdown()   //회의/전사 완료 → .md 자동저장 (켜져 있을 때)
        // Broker priority keeps backfill captions ahead of post-session work,
        // without a second process or an 8GB-specific reload/deferral path.
        // Summary must read the corrected transcript. Keep the immediate Markdown
        // durability save above, then defer summary/title until reconcile (and any
        // bounded language re-decodes) completes.
        if !kickReconcile() { startPostSessionSummary() }
    }

    /// Post-session AI title + summary. Broker priority keeps it below captions.
    private func startPostSessionSummary() {
        // DNA3가 이미 뜨므로 제목도 생성해 파일명을 AI 제목으로 승격(rename).
        if autoSaveEnabled, autoSaveSummary, fileName.isEmpty, let s = ensureSummaryEngine() {
            s.generateTitle(lines: attributedLines)
        }
        if autoSaveSummary, autoSaveEnabled { autoSummarizeForSave() }   // 요약본 별개 저장
    }

    // MARK: AI reconcile (post-session)

    /// Kick off the post-session LLM correction pass (if enabled + model present +
    /// enough dialogue to reason about). Runs after finalize when the recording
    /// engine is gone, so the DNA3 model has the machine to itself.
    /// Acoustic margin below which a line counts as "uncertain" — the ONLY lines
    /// the LLM may relabel (S3 fusion). Engine margins: confident ≈ 0.4-1.0,
    /// ambiguous windows measured 0.22-0.32 on the clinic fixture. Shared with the
    /// UI's "화자분리중…" label so the two cannot disagree about what is settled.
    private static let uncertainMargin = SpeakerID.settledMargin

    /// P6: a quit at ANY moment flushes the ledger to stdout — measurement must
    /// not depend on the user's stop/quit timing.
    private var terminateFlushRegistered = false
    private func registerTerminateFlush() {
        guard !terminateFlushRegistered else { return }
        terminateFlushRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                TranslationStabilityMetrics.shared.flushSummary("@terminate")
            }
        }
    }

    /// W2/W1/B1 timers — armed while recording, torn down at finalize/reset.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWatchdog() }
        }
        // P1: re-evaluate preview admission once a second so the aged slice fires
        // while DNA stays busy (nothing else re-triggers it during a steady backlog).
        previewAgingTimer?.invalidate()
        previewAgingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording, self.dnaBusy else { return }
                self.updatePreviewAdmission()
            }
        }
        if Self.liveRailCapable, aiReconcileEnabled {
            midReconcileTimer?.invalidate()
            // 45 → 120 s (2026-09-10): each reconcile part is a 4B turn the
            // caption lane cannot preempt; at 45 s the parts ran nearly back to
            // back and committed-caption latency went p90 3.7 s / max 14.7 s
            // (0.3.23 Korean live) against ~1 s without them.
            midReconcileTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording, !self.reconciling else { return }
                    // P11: reconcile spawns one-shot whisper processes AND long
                    // DNA turns — both contend with live captions. Wait for a
                    // quiet moment; the next 45s tick retries.
                    guard self.translateQueueDepth == 0, self.translateBacklog == 0,
                          self.segmentsInFlight == 0 else { return }
                    self.kickReconcile(mid: true)   // B1: correct the stable prefix continuously
                }
            }
        }
    }
    private func stopWatchdog() {
        watchdogTimer?.invalidate(); watchdogTimer = nil
        previewAgingTimer?.invalidate(); previewAgingTimer = nil
        midReconcileTimer?.invalidate(); midReconcileTimer = nil
    }

    /// W2: the oldest fed segment has produced no <<SEG_END>> for 45 s — the
    /// engine is hung. Restart it and re-feed every pending segment (their wavs
    /// are retained, so no audio is lost).
    private var lastEngineActivityAt = Date()

    /// Idle backfill (2026-09-11): a line the live queue shed used to wait for
    /// stop — one early shed left "번역이 밀렸어요 · 정지 후 채워요" on screen for
    /// the whole session (0.3.25 Korean, 2 targets, 1 shed at 0:49). When the
    /// caption lane is quiet the shed lines are re-translated one at a time,
    /// under the same key contract the stop-time drain uses; the completion
    /// path removes the key and the banner clears by itself.
    private func idleBackfillTick() {
        guard phase == .recording, let t = translate, !backlogKeys.isEmpty,
              translateQueueDepth == 0, segmentsInFlight == 0 else { return }
        let live = backlogKeys.filter { key in
            guard let line = transcript.lines.first(where: { $0.id == key.id }) else { return false }
            return lineHash(line.text) == key.sourceRevision
                && routedTargets(for: line.text).contains(key.lang)
                && line.translations[key.lang] == nil
        }
        let stale = backlogKeys.subtracting(live)
        if !stale.isEmpty {            // the row grew or was joined since the shed: nothing to fill
            backlogKeys.subtract(stale); translateBacklog = Set(backlogKeys.map(\.id)).count
        }
        guard let first = live.min(by: { $0.id.uuidString < $1.id.uuidString }),
              let line = transcript.lines.first(where: { $0.id == first.id }) else { return }
        let langs = Set(live.filter { $0.id == first.id }.map(\.lang))
        translatedHash[line.id] = nil
        DebugLog.shared?.emit("translate", "backfill", ["id": line.id.uuidString, "langs": langs.sorted(), "remaining": backlogKeys.count])
        _ = t   // the engine is owned by translateLine
        translateLine(line, forceTargets: langs)
    }

    private func tickWatchdog() {
        idleBackfillTick()
        // A8: 정지 직후(.flushing)는 부하가 가장 큰 순간 — 여기서 행이면
        // FLUSH_END가 영영 안 와 세션이 '정리 중'에 갇힌다. 활동 없이 45s면
        // 라이브 라벨로 강제 마감 (역검증 watchdog-conc-5).
        if phase == .flushing {
            if Date().timeIntervalSince(lastEngineActivityAt) > 45 {
                engine?.delegate = nil
                engine?.terminate()
                transcript.markDiarNamespaceBroken()
                engineDidFlush()
            }
            return
        }
        guard phase == .recording || phase == .paused, let oldest = segQueue.first else { return }
        // A6: 진행(엔진 활동) 기준 — 큐가 밀렸어도 SEG_END/단어가 나오고 있으면
        // 건강한 엔진이다. 큐 대기시간으로 재면 백로그에서 오재시작·연쇄 발산
        // (역검증 app-state-5).
        let lastProgress = max(oldest.fedAt, lastEngineActivityAt)
        guard Date().timeIntervalSince(lastProgress) > 45 else { return }
        hangRecoveries += 1
        debugWatchdog("w2-restart", ["queue": segQueue.count, "oldestFedAgo": Date().timeIntervalSince(oldest.fedAt),
                                     "lastActivityAgo": Date().timeIntervalSince(lastEngineActivityAt),
                                     "recoveries": hangRecoveries, "phase": "\(phase)"])
        engine?.delegate = nil   // 구엔진의 didTerminate(SIGTERM)가 세션을 error로 죽이지 않게 (watchdog-conc-1)
        engine?.terminate()
        transcript.markDiarNamespaceBroken()   // 새 엔진 화자 id는 0부터 — FLUSH 라벨 대체 금지 (app-state-6)
        LiveFeatureWiring.speakerIslandAbsorption = LiveFeatureWiring.islandAbsorption(for: languageTokenID)
        LiveFeatureWiring.weakLabelContinuation = LiveFeatureWiring.weakLabelContinuation(for: languageTokenID)
        let e = EngineProcess(config: makeConfig())
        e.delegate = self
        e.onDiagnosticLine = { [weak self] line in self?.engineDiag.ingest(line) }
        engine = e
        do { try e.start() } catch { phase = .error("엔진 재시작 실패: \(error.localizedDescription)"); return }
        for i in segQueue.indices { segQueue[i].fedAt = Date() }
        for job in segQueue { e.feed(offset: job.offset, wav: job.url) }
    }

    private var pendingFinalReconcile = false

    @discardableResult
    private func kickReconcile(mid: Bool = false) -> Bool {
        // mid 응답 대기 중 final 킥이 스냅샷을 덮으면 mid 응답이 final로 오적용
        // 된다 (역검증 fusion-1/watchdog-conc-4) — in-flight면 final을 예약.
        if reconciling { if !mid { pendingFinalReconcile = true }; return true }
        guard aiReconcileEnabled, transcript.lines.count >= 4,
              let s = ensureSummaryEngine() else { return false }
        // B1 mid-session: only the STABLE prefix (the last 2 lines may still grow)
        let lines = mid ? Array(transcript.lines.dropLast(2)) : transcript.lines
        guard lines.count >= 4 else { return false }
        reconciling = true
        if !mid { reconcileNote = nil }
        reconcileIsMid = mid
        reconcileSnapshot = lines.map(\.id)
        let uncertain = Set(lines.enumerated().compactMap { i, l in
            l.speakerMargin < Self.uncertainMargin ? i : nil
        })
        let languageRisk = Set(lines.enumerated().compactMap { i, line in
            decodeRiskRanges.contains(where: { $0.end > line.start && $0.start < line.end }) ? i : nil
        })
        let numbered = TranscriptReconciler.promptInput(
            lines: lines.map { (speaker: $0.speaker, text: $0.text) },
            speakerName: { [weak self] in SpeakerID.display($0, names: self?.speakerNames ?? [:], fallback: "화자 \($0)") },
            uncertain: uncertain, languageRisk: languageRisk)
        s.reconcile(numbered: numbered)
        return true
    }

    /// Apply the parsed correction plan: speaker merges/relabels immediately
    /// (reversible in one step via transcript.revertSpeakerCorrections), then
    /// re-transcribe any wrong-language lines from their retained audio (Phase 2).
    private func applyReconcile(_ reply: String?) {
        reconciling = false
        let mid = reconcileIsMid
        guard let reply else {
            if !mid { reconcileNote = nil }
            completeReconcileCycle(mid: mid)
            return
        }
        let snapshot = reconcileSnapshot
        // Exclude the Unknown bucket: the on-device LLM reconciler must never
        // MERGE/RELABEL 미확인 into (or out of) a real speaker — its guard is
        // set-membership on the numeric id, not the display name.
        let speakers = Set(transcript.lines.map(\.speaker)).subtracting([SpeakerID.unknown])
        // S3 fusion gate: RELABEL is only accepted for acoustically-uncertain
        // lines (margin < threshold at snapshot indices, resolved to live lines).
        var allowed = Set<Int>()
        for (i, id) in snapshot.enumerated() {
            if let line = transcript.lines.first(where: { $0.id == id }),
               line.speakerMargin < Self.uncertainMargin { allowed.insert(i) }
        }
        let plan = TranscriptReconciler.parse(reply, speakers: speakers, lineCount: snapshot.count,
                                              relabelAllowed: allowed)
        guard !plan.isEmpty else {
            if !mid { reconcileNote = nil }
            completeReconcileCycle(mid: mid)
            return
        }

        var merged = 0, relabeled = 0
        // mid-session: merges are deferred to the final pass (a wrong merge
        // mid-meeting is disruptive; relabels are line-local and gated).
        if !mid {
            for c in plan.merges {
                if case let .merge(from, into) = c, mergeSpeakerIdentity(from: from, into: into) {
                    merged += 1
                }
            }
        }
        for c in plan.relabels {
            if case let .relabel(line, sp) = c, line < snapshot.count {
                transcript.relabelSpeaker(lineID: snapshot[line], to: sp); relabeled += 1
            }
        }
        // Phase 2: re-transcribe wrong-language lines from their own audio clips.
        let langFlags: [(id: UUID, lang: String)] = plan.languageFlags.compactMap { c in
            if case let .language(line, lang) = c, line < snapshot.count {
                return (snapshot[line], lang)
            }
            return nil
        }
        var parts: [String] = []
        if merged > 0 { parts.append("화자 \(merged)건 병합") }
        if relabeled > 0 { parts.append("화자 \(relabeled)건 재지정") }
        var languageAsync = false
        if !langFlags.isEmpty {
            languageAsync = reTranscribeLanguage(langFlags, completedParts: parts, mid: mid)
        } else if !parts.isEmpty {
            reconcileNote = (mid ? "AI 교정(진행 중): " : "AI 교정: ") + parts.joined(separator: " · ")
        } else if !mid {
            reconcileNote = nil
        }
        if merged > 0 || relabeled > 0 {
            calendar.matchToSpeakers(speakerNames)   // speaker set changed → rematch attendees
            recomputeCoach()
        }
        if !languageAsync { completeReconcileCycle(mid: mid) }
    }

    private func completeReconcileCycle(mid: Bool) {
        if !mid { autoSaveMarkdown() }
        if pendingFinalReconcile {
            pendingFinalReconcile = false
            _ = kickReconcile()
        } else if !mid {
            startPostSessionSummary()
        }
    }

    /// Merge transcript labels and every attached identity surface as one
    /// transaction. Distinct explicit names are counter-evidence, so that merge
    /// is rejected instead of silently destroying a person's identity.
    private func mergeSpeakerIdentity(from: Int, into: Int) -> Bool {
        let fromName = speakerNames[from]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let intoName = speakerNames[into]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromName, !fromName.isEmpty, let intoName, !intoName.isEmpty,
           fromName.caseInsensitiveCompare(intoName) != .orderedSame { return false }
        if reconcileSpeakerNamesBefore == nil {
            reconcileSpeakerNamesBefore = speakerNames
            reconcileAutoNamesBefore = autoRecognizedSpeakers
        }
        transcript.mergeSpeaker(from: from, into: into)
        let survivingName = (intoName?.isEmpty == false ? intoName : fromName)
        speakerNames[from] = nil
        if let survivingName, !survivingName.isEmpty {
            speakerNames[into] = survivingName
            pendingEnrollment.remove(id: from)
            pendingEnrollment.add(id: into, name: survivingName)
            enrollVoiceprint(speaker: into, name: survivingName)
        }
        if autoRecognizedSpeakers.contains(from) { autoRecognizedSpeakers.insert(into) }
        autoRecognizedSpeakers.remove(from)
        return true
    }

    /// Revert all AI speaker corrections in one step (UI "되돌리기").
    func revertReconcile() {
        transcript.revertSpeakerCorrections()
        if let names = reconcileSpeakerNamesBefore { speakerNames = names }
        if let auto = reconcileAutoNamesBefore { autoRecognizedSpeakers = auto }
        reconcileSpeakerNamesBefore = nil; reconcileAutoNamesBefore = nil
        reconcileNote = nil
        calendar.matchToSpeakers(speakerNames)
    }

    /// Phase 2: re-decode each wrong-language line's own audio clip with the
    /// correct language forced, then replace the line text. Uses the retained
    /// live-segment wavs (offset → covering segment); file-mode sessions have no
    /// per-segment audio, so they are flagged only (no re-transcription).
    /// Best-effort: a segment ≈ one utterance in the short-turn clinic case; a
    /// multi-line segment yields the whole window's text for the flagged line.
    @discardableResult
    private func reTranscribeLanguage(_ flags: [(id: UUID, lang: String)],
                                      completedParts: [String], mid: Bool) -> Bool {
        guard !flags.isEmpty else { return false }
        let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/transcribe")
        let model = AssetManifest.modelURL
        let bpe = AssetManifest.bundledBPE
        let assets = AssetManifest.bundledAssetsDir
        let segs = segmentAudio
        struct Job: Sendable {
            let id: UUID; let langToken: Int; let source: URL
            let relativeStart: Double; let relativeEnd: Double; let expectedRevision: UInt64
        }
        var jobs: [Job] = []
        for f in flags {
            guard let line = transcript.lines.first(where: { $0.id == f.id }),
                  let tok = TranscriptReconciler.languageToken(f.lang),
                  let seg = (segs.last(where: { $0.offset <= line.start + 0.05 }) ?? segs.first),
                  FileManager.default.fileExists(atPath: seg.url.path) else { continue }
            jobs.append(Job(id: f.id, langToken: tok, source: seg.url,
                            relativeStart: max(0, line.start - seg.offset),
                            relativeEnd: max(line.start - seg.offset + 0.08, line.end - seg.offset),
                            expectedRevision: lineHash(line.text)))
        }
        let unavailable = flags.count - jobs.count
        guard !jobs.isEmpty else {
            let failed = unavailable > 0 ? unavailable : flags.count
            reconcileNote = (mid ? "AI 교정(진행 중): " : "AI 교정: ")
                + (completedParts + ["언어 \(failed)건 검증만(보존 오디오 없음)"]).joined(separator: " · ")
            return false
        }
        languageCorrectionsPending = jobs.count
        reconcileNote = (mid ? "AI 교정(진행 중): " : "AI 교정: ")
            + (completedParts + ["언어 0/\(jobs.count)줄 교정 중"]).joined(separator: " · ")
        Task.detached { [weak self] in
            var applied = 0
            var failed = unavailable
            for (index, job) in jobs.enumerated() {
                var clip: URL?
                do {
                    clip = try WavWriter.crop16kMonoPCM(source: job.source,
                                                        start: job.relativeStart, end: job.relativeEnd)
                } catch {
                    failed += 1
                }
                var didApply = false
                if let clip {
                    let text = Self.runOneShotTranscribe(
                        bin: bin, model: model, wav: clip, bpe: bpe, assets: assets,
                        langToken: job.langToken)
                    try? FileManager.default.removeItem(at: clip)
                    if let text, !text.isEmpty {
                        didApply = await MainActor.run { [weak self] in
                            self?.applyTextCorrection(job.id, to: text,
                                                      expectedRevision: job.expectedRevision, learn: false) ?? false
                        }
                    }
                    if didApply { applied += 1 } else { failed += 1 }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.languageCorrectionsPending = jobs.count - index - 1
                    self.reconcileNote = (mid ? "AI 교정(진행 중): " : "AI 교정: ")
                        + (completedParts + ["언어 \(index + 1)/\(jobs.count)줄 처리"]).joined(separator: " · ")
                }
            }
            let appliedCount = applied
            let failedCount = failed
            await MainActor.run { [weak self] in
                self?.finishLanguageCorrections(applied: appliedCount, failed: failedCount,
                                                completedParts: completedParts, mid: mid)
            }
        }
        return true
    }

    private func finishLanguageCorrections(applied: Int, failed: Int,
                                           completedParts: [String], mid: Bool) {
        languageCorrectionsPending = 0
        var parts = completedParts
        if applied > 0 { parts.append("언어 \(applied)건 교정") }
        if failed > 0 { parts.append("언어 \(failed)건 원문 유지") }
        reconcileNote = parts.isEmpty ? nil
            : (mid ? "AI 교정(진행 중): " : "AI 교정: ") + parts.joined(separator: " · ")
        autoSaveMarkdown()
        recomputeCoach()
        completeReconcileCycle(mid: mid)
    }

    /// Run the bundled `transcribe` binary once on a single wav in plain FILE
    /// mode with a forced language, and return the transcription text. Runs off
    /// the main actor (blocking Process I/O).
    nonisolated private static func runOneShotTranscribe(
        bin: URL, model: URL, wav: URL, bpe: URL, assets: URL, langToken: Int) -> String? {
        let p = Process()
        p.executableURL = bin
        p.arguments = [model.path, wav.path, bpe.path]
        p.currentDirectoryURL = assets
        var env = ProcessInfo.processInfo.environment
        env["DIAR"] = "0"; env["AUDIO_CTX"] = "auto"; env["WHISPER_LANG_ID"] = String(langToken)
        env.removeValue(forKey: "STREAM"); env.removeValue(forKey: "APP_FILE")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        // Plain file mode prints "=== TRANSCRIPTION (...) ===" then the text lines.
        let lines = s.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("=== TRANSCRIPTION") }) else { return nil }
        var text = ""
        for l in lines[(start + 1)...] {
            if l.hasPrefix("===") || l.hasPrefix("[") { break }   // next section / perf line
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if text.isEmpty { continue } else { break } }
            text += (text.isEmpty ? "" : " ") + t
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: export

    func exportMarkdown(to url: URL) throws {
        try Exporters.markdown(transcript.lines, names: speakerNames, summary: meetingSummary)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Smart auto-title: rename the just-saved transcript .md (and its companion
    /// summary file, if already written) to the AI-generated title. The save was
    /// already done synchronously with the timestamp name, so a failed/late title
    /// never loses data — this only upgrades the filename. Collision-safe.
    private func renameAutoSavedToTitle(_ title: String) {
        let fm = FileManager.default
        guard let src = lastAutoSaved, fm.fileExists(atPath: src.path) else { return }
        let oldBase = src.deletingPathExtension().lastPathComponent
        var dst = autoSaveFolder.appendingPathComponent(title).appendingPathExtension("md")
        var n = 2
        while fm.fileExists(atPath: dst.path) {
            dst = autoSaveFolder.appendingPathComponent("\(title) \(n)").appendingPathExtension("md"); n += 1
        }
        do {
            try fm.moveItem(at: src, to: dst)
            lastAutoSaved = dst
            // Move the companion "<oldBase> 요약.md" too, if it landed already.
            let oldSummary = autoSaveFolder.appendingPathComponent("\(oldBase) 요약").appendingPathExtension("md")
            if fm.fileExists(atPath: oldSummary.path) {
                let newBase = dst.deletingPathExtension().lastPathComponent
                try? fm.moveItem(at: oldSummary,
                                 to: autoSaveFolder.appendingPathComponent("\(newBase) 요약").appendingPathExtension("md"))
            }
            workspace.reload()
        } catch { /* non-fatal — the timestamp-named file is intact */ }
    }

    /// Render the meeting summary as a self-contained, presentation-style HTML deck
    /// and save it as summary-<date>-<n>.html in the auto-save folder. Returns the
    /// saved URL (nil if there's no summary yet or the write failed).
    func exportSummaryDeck() -> URL? {
        guard let summary = meetingSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let title = fileName.isEmpty ? "회의 요약" : (fileName as NSString).deletingPathExtension
        let df = DateFormatter(); df.dateFormat = "yyyy년 M월 d일"
        let html = SummaryDeck.html(summary: summary, speakerSummary: speakerSummary,
                                    title: title, dateText: df.string(from: Date()))
        let url = autoSaveFolder.appendingPathComponent(SummaryDeck.filename(in: autoSaveFolder, date: Date()))
        do { try html.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
    func exportSRT(to url: URL) throws {
        try Exporters.srt(transcript.lines, names: speakerNames)
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportVTT(to url: URL) throws {
        try Exporters.vtt(transcript.lines, names: speakerNames)
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportText(to url: URL) throws {
        try Exporters.plainText(transcript.lines, names: speakerNames)
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportJSON(to url: URL) throws {
        try Exporters.json(transcript.lines, names: speakerNames, settings: editorSettings)
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportCutList(to url: URL) throws {
        try Exporters.cutListCSV(transcript.lines, settings: editorSettings)
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportChapters(to url: URL) throws {
        try Exporters.youtubeChapters(transcript.lines, settings: editorSettings)
            .write(to: url, atomically: true, encoding: .utf8)
    }
    /// (cut count, removable seconds) for the tighten stat — honors the toggles.
    var tightenStat: (cuts: Int, seconds: Double) {
        guard editorSettings.enabled else { return (0, 0) }   // editor off → no cuts
        let c = EditorCuts.tighten(transcript.lines, editorSettings)
        return (c.count, c.reduce(0) { $0 + $1.duration })
    }
}

/// Fixed speaker-count choice, used only WHEN diarization is on (session.diarize).
/// "No diarization" is the separate `diarize` toggle, not a case here — turning it
/// off skips the whole diar engine path (see EngineProcess DIAR + transcribe.zig).
/// rawValue is persisted. Note the redesign (2026-07): the old `.one` (1명) is gone
/// — a single speaker is now "diarization off"; `.four` is EXACTLY 4 and `.fivePlus`
/// (5명 이상) is the open-ended auto-K bucket that `.fourPlus` used to be.
enum SpeakerCount: Int, CaseIterable, Identifiable {
    case auto = 0, two = 2, three = 3, four = 4, fivePlus = 5
    var id: Int { rawValue }
    var label: String { label(.ko) }
    func label(_ lang: UILanguage) -> String {
        switch self {
        case .auto:     return lang("자동", "Auto", "自動")
        case .two:      return lang("2명", "2", "2名")
        case .three:    return lang("3명", "3", "3名")
        case .four:     return lang("4명", "4", "4名")
        case .fivePlus: return lang("5명 이상", "5+", "5名以上")
        }
    }
    var maxSpeakers: Int {
        switch self {
        case .auto, .fivePlus: return 8   // no tight cap — let the engine detect
        case .two:             return 2
        case .three:           return 3
        case .four:            return 4
        }
    }
    /// FIXED speaker count passed to the engine as DIAR_K. nil ⇒ auto-K
    /// (silhouette). A concrete N ⇒ cluster to EXACTLY N speakers + at most one
    /// "Unknown" bucket for acoustically-distant windows. 자동/5명 이상 stay auto;
    /// 2/3/4명 are hard-fixed (fixes "화자 고정해도 자동 분리").
    var fixedK: Int? {
        switch self {
        case .auto, .fivePlus: return nil
        case .two:             return 2
        case .three:           return 3
        case .four:            return 4
        }
    }
    /// Per-speaker-count Silero speech-gate (VAD_PROB) default — each bucket's
    /// outlier-robust DER optimum from the 2026-06-25 sweep (bench/VAD_TUNING.md).
    /// More speakers ⇒ more cross-talk/backchannel false-speech ⇒ a stricter gate
    /// trims FA. Gains over a flat 0.5 are small (≤~0.1pp, within noise on clean
    /// close-mic audio); the mapping just sits each setting on its measured min.
    /// auto = unknown count ⇒ the safe global 0.5. (Has no effect on far-field,
    /// which is heterogeneous — see VAD_TUNING.md.)
    var vadProb: Double {
        switch self {
        case .auto:                     return 0.5
        case .two:                      return 0.65
        case .three, .four, .fivePlus:  return 0.8
        }
    }
}
