// SessionController.swift — orchestrates the live transcription session:
// AudioCapture → EngineProcess → TranscriptStore. Owns the state machine the
// UI binds to. This is the "live_transcribe.sh" logic re-homed in Swift, minus
// ffmpeg (native capture) and minus awk (TranscriptStore).

import Foundation
import Observation
import CoreAudio
import AVFoundation

@Observable
@MainActor
final class SessionController: EngineProcessDelegate {
    enum Phase: Equatable {
        case idle, countingDown(Int), engineStarting, ready, recording, paused, processing, flushing, done
        case error(String)
    }

    private(set) var phase: Phase = .idle
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
    struct TranslationRef: Equatable { let id: UUID; let lang: String }
    private(set) var streamingTranslation: TranslationRef?
    /// Pending translation turns (queued + in-flight) — the "N줄 대기" status (D20).
    private(set) var translateQueueDepth = 0
    /// Max live translation queue depth (turns). Past this, fast speech sheds its
    /// OLDEST turns to `translateBacklog` and they're re-translated at stop.
    private static let liveTranslateCap = 30
    /// Lines the live queue shed (translation deferred to stop) — the "N줄은 종료
    /// 후 채움" HUD signal, and the backfill worklist finalize drains.
    private var backlogLineIDs: Set<UUID> = []
    private(set) var translateBacklog = 0
    /// Post-stop backfill in progress: lines still being re-translated after the
    /// live cap shed them. Drives the ".done · 채우는 중 N줄" HUD, and gates the
    /// 8GB summary engine (which evicts translate) until backfill drains.
    private var backfillPendingIDs: Set<UUID> = []
    private(set) var backfillRemaining = 0
    private var summaryDeferredForBackfill = false
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
        liveRailTimer = Timer.scheduledTimer(withTimeInterval: 18, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLiveRail() }
        }
    }

    /// One extraction pass: only while recording, only when ≥3 new lines landed and
    /// no pass is in flight (so the DNA3 GPU spike stays brief + non-overlapping).
    private func tickLiveRail() {
        guard phase == .recording, liveRailEnabled, Self.liveRailCapable else { return }
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
        s.extractActions(lines: attributedLines)
    }

    private func stopLiveRail() {
        liveRailTimer?.invalidate(); liveRailTimer = nil
        liveRailBusy = false; liveRailBusyTicks = 0
    }

    // file-mode progress (nil when not transcribing a file)
    private(set) var fileName: String = ""
    private(set) var chunksDone = 0
    private(set) var chunksTotal = 0

    var diarize = true
    var inputDeviceID: AudioDeviceID?          // nil = system default mic
    var availableInputs: [AudioInputDevice] { AudioDevices.inputs() }
    /// Capture source: 마이크 / 시스템 오디오(Teams·Slack·YouTube) / 마이크+시스템.
    /// Persisted; applied at the next record start.
    var audioSource: AudioSource = AudioSource(rawValue: UserDefaults.standard.string(forKey: "audioSource") ?? "mic") ?? .mic {
        didSet { UserDefaults.standard.set(audioSource.rawValue, forKey: "audioSource") }
    }
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

    /// Fixed speaker count for diarization (자동/1/2/3/4명 이상). Persisted; maps to
    /// the engine's DIAR_MAXK upper bound. 자동 and 4+ leave the cap at 8.
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
            // Apply the preset's diarization hint (map raw Int → SpeakerCount). A
            // preset, not a lock — the user can still adjust 화자 수 afterward.
            if let sc = SpeakerCount(rawValue: meetingMode.config.defaultSpeakerCountRaw) {
                speakerCount = sc
            }
        }
    }

    /// Live segment window (s) — the live FELT-latency knob. Text lands when a
    /// window closes, so a shorter window = snappier live text but less Whisper
    /// context (more boundary error). Default 10 = current accuracy (no
    /// regression); applied at the next record start. Persisted.
    var liveWindowSeconds: Double = (UserDefaults.standard.object(forKey: "liveWindowSeconds") as? Double) ?? 10 {
        didSet { UserDefaults.standard.set(liveWindowSeconds, forKey: "liveWindowSeconds") }
    }

    /// 2개 이상으로 번역할 때는 반응속도와 무관하게 "정확"(10초) 윈도를 강제한다.
    /// 짧은 윈도는 원문 경계 오류가 많은데, 그 오류가 모든 대상 언어 번역으로
    /// 전파되므로 — 다중 번역에서는 가장 긴 문맥의 원문 품질이 우선이다. UI도 이
    /// 규칙을 노출(2개+ 선택 시 반응속도 picker를 잠그고 "정확"으로 표시).
    /// 예외 (T4, 2026-07-03): {한국어, X} 양방향 쌍은 per-line 스크립트 라우팅이
    /// 라인당 실효 타깃을 1개로 줄이므로(KO줄→X만, X줄→KO만) 강제하지 않는다 —
    /// 클리닉 대면 통역이 정확히 이 형태다.
    var multiTranslateForcesAccurate: Bool {
        translateTargets.count >= 2 &&
            !(translateTargets.count == 2 && translateTargets.contains("Korean"))
    }
    var effectiveWindowSeconds: Double { multiTranslateForcesAccurate ? 10 : liveWindowSeconds }

    /// Streaming preview: a 2nd engine decodes the in-progress window every ~1.5s
    /// for instant interim text — NO accuracy cost (committed text is unchanged).
    /// Costs a 2nd resident model (~830 MB) only while recording. Persisted.
    var livePreviewEnabled: Bool = (UserDefaults.standard.object(forKey: "livePreviewEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(livePreviewEnabled, forKey: "livePreviewEnabled") }
    }
    /// Interim "진행 중" text (cleared when the window's committed words land).
    /// Fed by TWO provisional sources that overwrite each other (both cover the
    /// freshest audio; life of a «partial» is ~0.5 s with AUDIO_CTX decode):
    ///   «partial» lines — the closed segment's in-decode hypothesis (main
    ///                     engine, PARTIALS=1) — converges to the committed text
    ///   PreviewEngine   — the still-open window's text (~1 s cadence)
    private(set) var livePartial: String = "" {
        didSet {
            // NOTE: translations are NOT auto-cleared here — on window commit the
            // last interim translation stays on screen as a provisional caption
            // (T1 carryover) until the committed line's real translation lands.
            // Session reset/stop sites clear livePartialTranslations explicitly.
            if livePartial.isEmpty { interimInFlight = false }
            else if livePartial != oldValue { scheduleInterimTranslate() }
        }
    }
    /// Provisional translation of the in-progress interim text (lang → text), shown
    /// immediately so a caption doesn't wait ~10s for the window to close. Replaced
    /// by the authoritative per-line translation once the line commits.
    private(set) var livePartialTranslations: [String: String] = [:]
    private var interimInFlight = false
    private var interimSource = ""
    private var interimGen = 0
    private static let interimID = UUID()
    private let preview = PreviewEngine()

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
    /// {Korean, X}, so both sides transcribe+translate (langCandidatePair active).
    var isBidirectionalKoPair: Bool { translateTargets.count == 2 && translateTargets.contains("Korean") }

    private var translate: TranslateEngine?
    private var translatedHash: [UUID: Int] = [:]  // line id → translated text hash (re-queue on change)
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
    // Uses the SAME bundled DNA3.0-4B; the transcript never leaves the device.
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

    private var attributedLines: [String] {
        transcript.lines.map { "\(speakerNames[$0.speaker] ?? "화자\($0.speaker)"): \($0.text)" }
    }

    /// Spawn the DNA3 engine for meeting intelligence (summary + Q&A), kept resident
    /// so follow-up questions don't reload the 2.6 GB model. Frees the translate
    /// engine first (one model resident at a time; summary/Q&A are post-session).
    private func ensureSummaryEngine() -> SummaryEngine? {
        guard let eng = AssetManifest.translateEngineURL, AssetManifest.translateModelIsValid() else { return nil }
        if summaryEngine == nil {
            // One-model-resident is a MEMORY constraint, not a hard rule: on ≥16GB
            // (where the live action rail runs) two DNA3 instances + Whisper fit, so
            // KEEP the translate engine alive — otherwise the rail's 18s summary tick
            // would kill+reload translation every cycle, starving live captions.
            if !Self.liveRailCapable { translate?.stop(); translate = nil }
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

    /// Structured [요약]/[액션]/[결정] from the diarized transcript, on-device.
    func summarize() {
        guard !summarizing else { return }
        guard !transcript.lines.isEmpty else { return }
        switch phase { case .recording, .paused, .countingDown: return; default: break }
        guard let s = ensureSummaryEngine() else {
            meetingSummary = "요약 모델이 없습니다 — 설정 › 번역에서 모델을 먼저 받으세요."; return
        }
        summarizing = true; meetingSummary = nil
        s.summarize(lines: attributedLines, styleSuffix: meetingMode.config.summaryPromptSuffix)
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
        s.summarizeBySpeaker(lines: attributedLines, styleSuffix: meetingMode.config.summaryPromptSuffix)
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

    private func clearSummary() {
        calendar.clear()
        stopLiveRail(); liveRailItems = []         // new session → reset the live rail
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
    private func lineHash(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hashValue
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
            t.maxPending = Self.liveTranslateCap
            t.onDrop = { [weak self] id in
                guard let self else { return }
                if self.backlogLineIDs.insert(id).inserted { self.translateBacklog = self.backlogLineIDs.count }
            }
            t.onResult = { [weak self] id, lang, text, source in
                guard let self else { return }
                if id == Self.interimID {
                    self.interimInFlight = false
                    if !self.livePartial.isEmpty {
                        self.livePartialTranslations[lang] = text
                        // Cache this interim source's translations so the matching
                        // committed line can reuse them (O3). Keyed by interimSource —
                        // the exact text that was sent to translate() for this turn.
                        self.interimCache.put(self.interimSource, self.livePartialTranslations)
                    }
                    if self.livePartial != self.interimSource { self.scheduleInterimTranslate() }  // grew → refresh
                } else {
                    // A7: this turn finished streaming — drop the caret.
                    if self.streamingTranslation == TranslationRef(id: id, lang: lang) {
                        self.streamingTranslation = nil
                    }
                    // stale-guard (T2): the line may have GROWN after this turn was
                    // queued (merge). The hash gate already re-queued the new text —
                    // don't let the old turn overwrite the fresher translation.
                    if let line = self.transcript.lines.first(where: { $0.id == id }),
                       self.lineHash(line.text) != self.lineHash(source) { return }
                    self.transcript.setTranslation(id, lang: lang, text)
                    // Backfill progress: this shed line is filled — count it down.
                    // When backfill drains, run the 8GB summary that was deferred so
                    // it wouldn't evict the translate engine mid-backfill.
                    if self.backfillPendingIDs.remove(id) != nil {
                        self.backfillRemaining = self.backfillPendingIDs.count
                        if self.backfillRemaining == 0, self.summaryDeferredForBackfill {
                            self.summaryDeferredForBackfill = false
                            self.startPostSessionSummary()
                        }
                    }
                    // T1 carryover teardown: the real translation replaced the
                    // provisional interim caption for the freshest content.
                    if id == self.transcript.lines.last?.id, self.livePartial.isEmpty {
                        self.livePartialTranslations = [:]
                    }
                }
            }
            // streaming partial (T5): the reply types itself onto the screen
            // (~19 ms/token) instead of appearing whole ~0.5-0.9 s later.
            t.onPartial = { [weak self] id, lang, text in
                guard let self else { return }
                if id == Self.interimID {
                    if !self.livePartial.isEmpty { self.livePartialTranslations[lang] = text }
                } else if self.transcript.lines.contains(where: { $0.id == id }) {
                    self.streamingTranslation = TranslationRef(id: id, lang: lang)  // A7 caret
                    self.transcript.setTranslation(id, lang: lang, text)
                }
            }
            // queue depth (D20) — the engine reports queued + in-flight turns.
            t.onQueueChange = { [weak self] depth in self?.translateQueueDepth = depth }
            _ = t.start(engine: eng, model: AssetManifest.translateModelURL)
            translate = t
        }
        return translate
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
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, gen == self.interimGen, !self.interimInFlight, !self.livePartial.isEmpty else { return }
            guard let t = self.ensureTranslateEngine() else { return }
            let targets = self.routedTargets(for: self.livePartial)
            guard !targets.isEmpty else { return }
            self.interimInFlight = true
            self.interimSource = self.livePartial
            t.translate(self.livePartial, into: targets, id: Self.interimID)
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
        let lines = transcript.lines
        let upTo = includingLast ? lines.count : max(0, lines.count - 1)
        for i in 0..<upTo { translateLine(lines[i]) }
    }

    /// Queue one line (hash-gated, FAQ/O3-cached, direction-routed).
    private func translateLine(_ line: Line) {
        let h = lineHash(line.text)
        if translatedHash[line.id] == h { return }
        guard let t = ensureTranslateEngine() else { return }
        let targets = routedTargets(for: line.text)
        guard !targets.isEmpty else { return }
        translatedHash[line.id] = h
        // T8: session-invariant FAQ bank first — a recurring clinic phrase costs
        // 0 ms and no DNA3 turn. Conservative exact (normalized) match only.
        if let faq = faqStore.lookup(line.text) {
            var missing: [String] = []
            for tgt in targets {
                if let tr = faq[tgt] { transcript.setTranslation(line.id, lang: tgt, tr) }
                else { missing.append(tgt) }
            }
            if missing.isEmpty { return }
            t.translate(line.text, into: missing, id: line.id)
            return
        }
        // O3: if this line's text was already translated as interim, reuse the
        // cached translations and skip the DNA3 turn entirely. Only reuse the
        // targets we actually have cached; queue the engine for any that miss.
        if let cached = interimCache.get(line.text) {
            let missing = targets.filter { cached[$0] == nil }
            for tgt in targets where cached[tgt] != nil {
                transcript.setTranslation(line.id, lang: tgt, cached[tgt]!)
            }
            if missing.isEmpty { return }
            t.translate(line.text, into: missing, id: line.id)
            return
        }
        t.translate(line.text, into: targets, id: line.id)
    }

    /// T2 tail timeout: the LAST line never loses last-status in a monologue —
    /// translate it after 2 s without change (re-queues on growth via the hash
    /// gate; the stale-guard in onResult drops superseded turns).
    private func scheduleTailTranslate() {
        guard !translateTargets.isEmpty else { return }
        tailGen += 1
        let gen = tailGen
        let snapshot = transcript.lines.last.map { ($0.id, lineHash($0.text)) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, gen == self.tailGen,
                  let (id, h) = snapshot,
                  let line = self.transcript.lines.last, line.id == id,
                  self.lineHash(line.text) == h else { return }
            self.translateLine(line)
        }
    }

    /// Editor-feature toggles + thresholds (persisted). The UI binds to this; all
    /// editor exports/stats read from it.
    var editorSettings = EditorSettings.load() { didSet { editorSettings.save() } }

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
        s.summarize(lines: attributedLines, styleSuffix: meetingMode.config.summaryPromptSuffix)
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
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { speakerNames[id] = nil; pendingEnrollment.remove(id: id); autoRecognizedSpeakers.remove(id); return }
        speakerNames[id] = t
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
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let src = voiceprintsDir.appendingPathComponent(".last/spk\(id).vec")
        let dst = voiceprintsDir.appendingPathComponent("\(safe).vec")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    private var engine: EngineProcess?
    private let capture = AudioCapture()

    private var isError: Bool { if case .error = phase { return true }; return false }

    /// T12: derive the bidirectional language pair from the translate targets —
    /// a {Korean, X} target set IS the clinic conversation declaration (staff
    /// speaks KO, patient speaks X). No extra UI: the pair unlocks per-segment
    /// language re-probe in the engine so BOTH sides transcribe correctly.
    private var langCandidatePair: [Int] {
        guard translateTargets.count == 2, translateTargets.contains("Korean") else { return [] }
        let tok: [String: Int] = ["English": 50259, "Chinese": 50260, "Korean": 50264, "Japanese": 50266]
        let pair = translateTargets.compactMap { tok[$0] }
        return pair.count == 2 ? pair.sorted() : []
    }

    private func makeConfig() -> EngineProcess.Config {
        EngineProcess.Config(
            binaryURL: Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/transcribe"),
            modelURL: AssetManifest.modelURL,
            bpeURL: AssetManifest.bundledBPE,
            assetsDir: AssetManifest.bundledAssetsDir,
            diarize: diarize, osd: osd,
            languageTokenID: languageTokenID, maxSpeakers: speakerCount.maxSpeakers,
            vadProb: speakerCount.vadProb, voiceprintsDir: voiceprintsDir,
            streamWavRoots: [capture.segmentDirectory],
            langCandidates: langCandidatePair,
            anchorVoiceprints: !langCandidatePair.isEmpty && hasEnrolledVoiceprints)
    }

    /// Any enrolled .vec voiceprints on disk? (S1 anchor precondition)
    private var hasEnrolledVoiceprints: Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: voiceprintsDir.path) else { return false }
        return items.contains { $0.hasSuffix(".vec") }
    }

    // MARK: session lifecycle

    private var countdownTask: Task<Void, Never>?
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
        guard AssetManifest.modelIsValid() else {
            phase = .error("음성 인식 모델이 준비되지 않았어요. 설정(⌘,) → 모델에서 먼저 다운로드해주세요.")
            return
        }
        // Mic permission preflight — without this the TCC dialog fires deep in
        // capture.start() where a denial looks like an engine hang ("모델 로딩…").
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            phase = .error("마이크 권한이 꺼져 있어요. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 Madi를 허용해주세요.")
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.beginCountdown(from: n) }
                    else {
                        self.phase = .error("마이크 권한이 필요해요. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 Madi를 허용해주세요.")
                    }
                }
            }
            return
        default:
            break
        }
        beginCountdown(from: n)
    }

    private func beginCountdown(from n: Int) {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for k in stride(from: n, through: 1, by: -1) {
                phase = .countingDown(k)
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // 1s/tick — clock cadence
                if Task.isCancelled { return }
            }
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
        countdownTask?.cancel(); countdownTask = nil
        periodicSaveTask?.cancel(); periodicSaveTask = nil
        engineStartTimeoutTask?.cancel(); engineStartTimeoutTask = nil
        silenceWatchTask?.cancel(); silenceWatchTask = nil; micSilent = false
        meterLevel = 0; level = 0
        recordStartedAt = nil; recordEndedAt = nil; pausedAt = nil; pausedAccum = 0
        transcript.reset()
        speakerNames = [:]
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedHash.removeAll()
        interimCache.clear()
        clearSummary()
        fileName = ""; chunksDone = 0; chunksTotal = 0
        livePartial = ""; livePartialTranslations = [:]
        streamingTranslation = nil; translateQueueDepth = 0
        backlogLineIDs.removeAll(); translateBacklog = 0
        backfillPendingIDs.removeAll(); backfillRemaining = 0; summaryDeferredForBackfill = false
        segmentAudio.removeAll(); reconcileNote = nil; reconciling = false
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
        transcript.editWord(lineID, index: index, to: newText)
        if let old = oldText, old != newText, !newText.trimmingCharacters(in: .whitespaces).isEmpty {
            glossary.learn(wrong: old, right: newText); glossary.save()
        }
        guard !translateTargets.isEmpty, let t = ensureTranslateEngine() else { return }
        let targets = translateTargets.subtracting([sourceLangName].compactMap { $0 }).sorted()
        guard !targets.isEmpty, let line = transcript.lines.first(where: { $0.id == lineID }) else { return }
        translatedHash[lineID] = lineHash(line.text)
        t.translate(line.text, into: targets, id: lineID)
    }

    func editLine(_ id: UUID, to newText: String) {
        transcript.editLine(id, newText)
        // LEARN: the user just corrected this line — index any swapped tokens so
        // future mis-recognitions of the same term self-correct. Diff the ASR text
        // (joinedText of the current words) against the user's new text.
        if let line = transcript.lines.first(where: { $0.id == id }) {
            let asrText = line.words.map(\.text).joined(separator: " ")
            let pairs = PersonalVocabulary.diff(before: asrText, after: newText)
            if !pairs.isEmpty {
                for p in pairs { glossary.learn(wrong: p.wrong, right: p.right) }
                glossary.save()
            }
        }
        guard !translateTargets.isEmpty, let t = ensureTranslateEngine() else { return }
        let targets = translateTargets.subtracting([sourceLangName].compactMap { $0 }).sorted()
        guard !targets.isEmpty, let line = transcript.lines.first(where: { $0.id == id }) else { return }
        translatedHash[id] = lineHash(line.text)
        t.translate(line.text, into: targets, id: id)
    }

    func start() {
        guard AssetManifest.modelIsValid() else {
            phase = .error("음성 인식 모델이 준비되지 않았어요. 설정(⌘,) → 모델에서 먼저 다운로드해주세요."); return
        }
        transcript.reset()
        speakerNames = [:]
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedHash.removeAll()
        interimCache.clear()
        clearSummary()
        streamingTranslation = nil; translateQueueDepth = 0; lastCommitAt = Date()
        segmentAudio.removeAll(); reconcileNote = nil; reconciling = false
        // T11 prewarm: spawn the translate engine during the dead time between
        // pressing record and the first utterance (READY takes 1.4-3.5 s) so the
        // first caption's translation doesn't pay the cold start.
        _ = ensureTranslateEngine()
        // Prefill from the live calendar event. ContentView observes calendar.event.id
        // and calls ensurePrepBrief() on change, so we do NOT call it here too (that
        // double-ran the headless aggregation and raced two detached tasks).
        if Self.calendarPrepEnabled { Task { await calendar.loadCurrentEvent() } }
        startLiveRail()                              // throttled live action extraction (≥16GB + on)
        startLiveCoach()                             // throttled coach recompute (~1Hz while recording)
        phase = .engineStarting

        let e = EngineProcess(config: makeConfig())
        e.delegate = self
        engine = e

        capture.inputDeviceID = inputDeviceID  // bind chosen mic before start
        capture.source = audioSource           // mic / system / both
        capture.onError = { [weak self] msg in
            guard let self else { return }
            // surface a system-audio failure without killing a running mic+system mix
            if self.audioSource == .system { self.phase = .error(msg) }
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

        // streaming preview (interim text before a window closes). The preview
        // engine MUST run with a forced language — it decodes tiny ~1.5s clips
        // where auto-detect misfires (→ English). If the user picked a language,
        // start now; if auto, wait for the main engine's [lang] detection (see
        // .languageDetected below) so previews match the committed transcript.
        livePartial = ""; livePartialTranslations = [:]
        if livePreviewEnabled {
            preview.onText = { [weak self] t in self?.livePartial = t }
            capture.onPreview = { [weak self] url in self?.preview.feed(wav: url) }
            if let lang = languageTokenID { preview.start(config: makeConfig(), lang: lang) }
        } else {
            capture.onPreview = nil
        }

        do { try e.start() }
        catch { phase = .error("전사 엔진을 시작하지 못했어요: \(error.localizedDescription)") }

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
        transcript.reset()
        speakerNames = [:]
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedHash.removeAll()
        interimCache.clear()
        clearSummary()
        fileName = url.lastPathComponent
        sourceMediaURL = url        // arm click-to-play (original timeline matches)
        chunksDone = 0; chunksTotal = 0
        phase = .processing

        // Decode ANY container (m4a/mp3/aac/flac/wav…) to a normalized 16k PCM WAV
        // off the main actor first — the engine's file reader only accepts PCM WAV.
        DispatchQueue.global(qos: .userInitiated).async {
            let wav: URL
            do { wav = try AudioDecode.toWav16k(url) }
            catch {
                let name = url.lastPathComponent
                Task { @MainActor in
                    self.phase = .error("'\(name)' 을(를) 열 수 없습니다 — 지원하지 않는 형식이거나 손상된 파일입니다.")
                }
                return
            }
            Task { @MainActor in self.runFileEngine(wav) }
        }
    }

    private func runFileEngine(_ wav: URL) {
        guard phase == .processing else { return }   // user may have navigated away
        var cfg = makeConfig()
        cfg.fileURL = wav                  // native FILE mode (fast batched + offline diar)
        let e = EngineProcess(config: cfg)
        e.delegate = self
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
        do {
            try capture.start()
            recordStartedAt = Date(); recordEndedAt = nil; pausedAccum = 0; pausedAt = nil
            phase = .recording
            startPeriodicAutosave()
            startSilenceWatch()
        }
        catch { phase = .error("마이크를 시작하지 못했어요: \(error.localizedDescription)") }
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
        switch event {
        case .progressTotal(let n): chunksTotal = n
        case .progressChunk(let k): chunksDone = max(chunksDone, k)
        case .wordSectionBegin:
            livePartial = ""; transcript.ingest(event)  // committed → drop interim
            lastCommitAt = Date()                        // D19 commit-cadence ring
            translateStableLines()                       // translate now-stable prior lines
        case .languageDetected(let tok):
            // auto-detect locked → start the preview engine in THAT language
            // (no-op if already started / preview off)
            if livePreviewEnabled { preview.start(config: makeConfig(), lang: tok) }
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
                    }
                }
            }
            wordsSinceSegStart = 0
            segmentsInFlight = segQueue.count
        case .partial(_, let text):
            // in-decode hypothesis of the closed segment — better context than
            // the preview engine's text and converges to the committed line, so
            // it may overwrite; the next preview/commit supersedes it.
            if !text.isEmpty { livePartial = text }
        default: transcript.ingest(event)
        }
    }

    func engineDidFlush() { finalizeOnce() }

    func engine(didTerminate code: Int32) {
        // file mode exits 0 on its own after <<FLUSH_END>>; finalize if a late
        // exit beats the FLUSH_END line (finalizeOnce is idempotent).
        if code == 0 { finalizeOnce(); return }
        if phase != .done, phase != .flushing {
            preview.stop(); livePartial = ""; livePartialTranslations = [:]
            phase = .error("전사 엔진이 예기치 않게 종료되었어요 (코드 \(code)). 다시 시도해주세요.")
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
        if glossary.enabled {
            for line in transcript.lines where line.editedText == nil {
                if let corrected = PersonalVocabulary.correctedLineText(line, glossary) {
                    transcript.editLine(line.id, corrected)
                }
            }
        }
        engine?.terminate()
        // Drain mid-session names now that the engine has dumped its centroids
        // (.last/spk<id>.vec) on flush — THIS is the enrollment-timing fix.
        for p in pendingEnrollment.pending() { enrollVoiceprint(speaker: p.id, name: p.name) }
        pendingEnrollment.clear()
        engine = nil
        preview.stop(); livePartial = ""; livePartialTranslations = [:]   // tear down the 2nd engine + interim text
        phase = .done
        // Backfill: lines the live queue shed under load get re-translated now,
        // uncapped, so the on-screen transcript/scrollback is complete after stop
        // (the live captions themselves already moved on). backfillRemaining drives
        // the progress HUD; on 8GB the summary engine — which evicts translate —
        // waits for this to drain. (interimCache is still warm → O3 reuse.)
        if let t = translate, !backlogLineIDs.isEmpty {
            t.maxPending = 0
            backfillPendingIDs.removeAll()
            for line in transcript.lines where backlogLineIDs.contains(line.id) {
                // skip lines a late live turn already filled (no wasted turn)
                if line.translations.count >= routedTargets(for: line.text).count { continue }
                translatedHash[line.id] = nil
                backfillPendingIDs.insert(line.id)
                translateLine(line)
            }
            backfillRemaining = backfillPendingIDs.count
            backlogLineIDs.removeAll(); translateBacklog = 0
        }
        translateStableLines(includingLast: true)  // translate the final line(s) too
        interimCache.clear()   // O3: final lines just consulted the cache — now wipe it (session boundary)
        stopLiveRail()       // recording ended — keep the accumulated rail for review
        stopWatchdog()
        segQueue.removeAll(); segmentsInFlight = 0
        stopLiveCoach(); recomputeCoach()   // stop the 1Hz loop, snapshot the final transcript once
        calendar.matchToSpeakers(speakerNames)   // attendee ↔ speaker match + 결석 flag
        autoSaveMarkdown()   //회의/전사 완료 → .md 자동저장 (켜져 있을 때)
        // 8GB: ensureSummaryEngine() evicts the translate engine, discarding any
        // in-flight backfill turns (data loss). Defer the summary until backfill
        // drains (onResult restarts it). 16GB keeps both resident → run now.
        if backfillRemaining > 0, !Self.liveRailCapable {
            summaryDeferredForBackfill = true
        } else {
            startPostSessionSummary()
        }
        kickReconcile()   // opt-in: LLM reviews speaker/language after the session
    }

    /// Post-session AI title + summary. Split out so the 8GB backfill path can
    /// defer it until the translate engine is done (it would otherwise be evicted).
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
    /// ambiguous windows measured 0.22-0.32 on the clinic fixture.
    private static let uncertainMargin = 0.35

    /// W2/W1/B1 timers — armed while recording, torn down at finalize/reset.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWatchdog() }
        }
        if Self.liveRailCapable, aiReconcileEnabled {
            midReconcileTimer?.invalidate()
            midReconcileTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording, !self.reconciling else { return }
                    self.kickReconcile(mid: true)   // B1: correct the stable prefix continuously
                }
            }
        }
    }
    private func stopWatchdog() {
        watchdogTimer?.invalidate(); watchdogTimer = nil
        midReconcileTimer?.invalidate(); midReconcileTimer = nil
    }

    /// W2: the oldest fed segment has produced no <<SEG_END>> for 45 s — the
    /// engine is hung. Restart it and re-feed every pending segment (their wavs
    /// are retained, so no audio is lost).
    private var lastEngineActivityAt = Date()

    private func tickWatchdog() {
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
        engine?.delegate = nil   // 구엔진의 didTerminate(SIGTERM)가 세션을 error로 죽이지 않게 (watchdog-conc-1)
        engine?.terminate()
        transcript.markDiarNamespaceBroken()   // 새 엔진 화자 id는 0부터 — FLUSH 라벨 대체 금지 (app-state-6)
        let e = EngineProcess(config: makeConfig())
        e.delegate = self
        engine = e
        do { try e.start() } catch { phase = .error("엔진 재시작 실패: \(error.localizedDescription)"); return }
        for i in segQueue.indices { segQueue[i].fedAt = Date() }
        for job in segQueue { e.feed(offset: job.offset, wav: job.url) }
    }

    private var pendingFinalReconcile = false

    private func kickReconcile(mid: Bool = false) {
        // mid 응답 대기 중 final 킥이 스냅샷을 덮으면 mid 응답이 final로 오적용
        // 된다 (역검증 fusion-1/watchdog-conc-4) — in-flight면 final을 예약.
        if reconciling { if !mid { pendingFinalReconcile = true }; return }
        guard aiReconcileEnabled, transcript.lines.count >= 4,
              let s = ensureSummaryEngine() else { return }
        // B1 mid-session: only the STABLE prefix (the last 2 lines may still grow)
        let lines = mid ? Array(transcript.lines.dropLast(2)) : transcript.lines
        guard lines.count >= 4 else { return }
        reconciling = true
        if !mid { reconcileNote = nil }
        reconcileIsMid = mid
        reconcileSnapshot = lines.map(\.id)
        let uncertain = Set(lines.enumerated().compactMap { i, l in
            l.speakerMargin < Self.uncertainMargin ? i : nil
        })
        let numbered = TranscriptReconciler.promptInput(
            lines: lines.map { (speaker: $0.speaker, text: $0.text) },
            speakerName: { [weak self] in self?.speakerNames[$0] ?? "화자 \($0)" },
            uncertain: uncertain)
        s.reconcile(numbered: numbered)
    }

    /// Apply the parsed correction plan: speaker merges/relabels immediately
    /// (reversible in one step via transcript.revertSpeakerCorrections), then
    /// re-transcribe any wrong-language lines from their retained audio (Phase 2).
    private func applyReconcile(_ reply: String?) {
        reconciling = false
        let mid = reconcileIsMid
        guard let reply else { if !mid { reconcileNote = nil }; return }
        let snapshot = reconcileSnapshot
        let speakers = Set(transcript.lines.map(\.speaker))
        // S3 fusion gate: RELABEL is only accepted for acoustically-uncertain
        // lines (margin < threshold at snapshot indices, resolved to live lines).
        var allowed = Set<Int>()
        for (i, id) in snapshot.enumerated() {
            if let line = transcript.lines.first(where: { $0.id == id }),
               line.speakerMargin < Self.uncertainMargin { allowed.insert(i) }
        }
        let plan = TranscriptReconciler.parse(reply, speakers: speakers, lineCount: snapshot.count,
                                              relabelAllowed: allowed)
        guard !plan.isEmpty else { if !mid { reconcileNote = nil }; return }

        var merged = 0, relabeled = 0
        // mid-session: merges are deferred to the final pass (a wrong merge
        // mid-meeting is disruptive; relabels are line-local and gated).
        if !mid {
            for c in plan.merges { if case let .merge(from, into) = c { transcript.mergeSpeaker(from: from, into: into); merged += 1 } }
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
        reTranscribeLanguage(langFlags)

        var parts: [String] = []
        if merged > 0 { parts.append("화자 \(merged)건 병합") }
        if relabeled > 0 { parts.append("화자 \(relabeled)건 재지정") }
        if !langFlags.isEmpty { parts.append("언어 \(langFlags.count)줄 재전사") }
        if !parts.isEmpty {
            reconcileNote = (mid ? "AI 교정(진행 중): " : "AI 교정: ") + parts.joined(separator: " · ")
        } else if !mid {
            reconcileNote = nil
        }
        if merged > 0 || relabeled > 0 {
            calendar.matchToSpeakers(speakerNames)   // speaker set changed → rematch attendees
            recomputeCoach()
        }
        if pendingFinalReconcile {
            pendingFinalReconcile = false
            kickReconcile()
        }
    }

    /// Revert all AI speaker corrections in one step (UI "되돌리기").
    func revertReconcile() {
        transcript.revertSpeakerCorrections()
        reconcileNote = nil
        calendar.matchToSpeakers(speakerNames)
    }

    /// Phase 2: re-decode each wrong-language line's own audio clip with the
    /// correct language forced, then replace the line text. Uses the retained
    /// live-segment wavs (offset → covering segment); file-mode sessions have no
    /// per-segment audio, so they are flagged only (no re-transcription).
    /// Best-effort: a segment ≈ one utterance in the short-turn clinic case; a
    /// multi-line segment yields the whole window's text for the flagged line.
    private func reTranscribeLanguage(_ flags: [(id: UUID, lang: String)]) {
        guard !flags.isEmpty, !segmentAudio.isEmpty else { return }
        let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/transcribe")
        let model = AssetManifest.modelURL
        let bpe = AssetManifest.bundledBPE
        let assets = AssetManifest.bundledAssetsDir
        let segs = segmentAudio
        for f in flags {
            guard let line = transcript.lines.first(where: { $0.id == f.id }),
                  let tok = TranscriptReconciler.languageToken(f.lang),
                  let seg = (segs.last(where: { $0.offset <= line.start + 0.05 }) ?? segs.first),
                  FileManager.default.fileExists(atPath: seg.url.path) else { continue }
            let id = f.id
            Task.detached {
                guard let text = Self.runOneShotTranscribe(
                    bin: bin, model: model, wav: seg.url, bpe: bpe, assets: assets, langToken: tok),
                    !text.isEmpty else { return }
                await MainActor.run { [weak self] in self?.transcript.editLine(id, text) }
            }
        }
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

/// Fixed speaker-count choice for diarization. rawValue is persisted; `maxSpeakers`
/// is the engine DIAR_MAXK upper bound it maps to (자동/4+ → 8, else the exact N).
enum SpeakerCount: Int, CaseIterable, Identifiable {
    case auto = 0, one = 1, two = 2, three = 3, fourPlus = 4
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .auto:     return "자동"
        case .one:      return "1명"
        case .two:      return "2명"
        case .three:    return "3명"
        case .fourPlus: return "4명 이상"
        }
    }
    var maxSpeakers: Int {
        switch self {
        case .auto, .fourPlus: return 8   // no tight cap — let the engine detect
        case .one:             return 1
        case .two:             return 2
        case .three:           return 3
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
        case .auto, .one:        return 0.5
        case .two:               return 0.65
        case .three, .fourPlus:  return 0.8
        }
    }
}
