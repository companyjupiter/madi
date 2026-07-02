// SessionController.swift — orchestrates the live transcription session:
// AudioCapture → EngineProcess → TranscriptStore. Owns the state machine the
// UI binds to. This is the "live_transcribe.sh" logic re-homed in Swift, minus
// ffmpeg (native capture) and minus awk (TranscriptStore).

import Foundation
import Observation
import CoreAudio

@Observable
@MainActor
final class SessionController: EngineProcessDelegate {
    enum Phase: Equatable {
        case idle, countingDown(Int), engineStarting, ready, recording, paused, processing, flushing, done
        case error(String)
    }

    private(set) var phase: Phase = .idle
    var level: Float = 0
    let transcript = TranscriptStore()
    /// Local Calendar glue — prefills the meeting title/attendees and matches
    /// speakers to attendees after the session (read-only, on-device).
    let calendar = CalendarBridge()
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
    func toggleCaptionOverlay() {
        captionOverlayOn.toggle()
        if captionOverlayOn {
            captionOverlay.show(CaptionView(session: self) { [weak self] in self?.hideCaptionOverlay() })
        } else {
            captionOverlay.hide()
        }
    }
    private func hideCaptionOverlay() { captionOverlayOn = false; captionOverlay.hide() }

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
    var multiTranslateForcesAccurate: Bool { translateTargets.count >= 2 }
    var effectiveWindowSeconds: Double { multiTranslateForcesAccurate ? 10 : liveWindowSeconds }

    /// Streaming preview: a 2nd engine decodes the in-progress window every ~1.5s
    /// for instant interim text — NO accuracy cost (committed text is unchanged).
    /// Costs a 2nd resident model (~830 MB) only while recording. Persisted.
    var livePreviewEnabled: Bool = (UserDefaults.standard.object(forKey: "livePreviewEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(livePreviewEnabled, forKey: "livePreviewEnabled") }
    }
    /// Interim "진행 중" text (cleared when the window's committed words land).
    private(set) var livePartial: String = "" {
        didSet {
            if livePartial.isEmpty { livePartialTranslations = [:]; interimInFlight = false }
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
    private var translate: TranslateEngine?
    private var translatedIDs: Set<UUID> = []
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
    /// a segment into its own language (50264=ko, 50259=en; others via the
    /// engine's [lang] detection if added later).
    private var sourceLangName: String? {
        switch languageTokenID { case 50264: return "Korean"; case 50259: return "English"; default: return nil }
    }

    /// Start the translate engine on demand (targets set + assets present).
    private func ensureTranslateEngine() -> TranslateEngine? {
        guard !translateTargets.isEmpty,
              let eng = AssetManifest.translateEngineURL,
              AssetManifest.translateModelIsValid() else { return nil }
        if translate == nil {
            let t = TranslateEngine()
            t.onResult = { [weak self] id, lang, text in
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
                    self.transcript.setTranslation(id, lang: lang, text)
                }
            }
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
            let targets = self.translateTargets.subtracting([self.sourceLangName].compactMap { $0 }).sorted()
            guard !targets.isEmpty else { return }
            self.interimInFlight = true
            self.interimSource = self.livePartial
            t.translate(self.livePartial, into: targets, id: Self.interimID)
        }
    }

    /// Translate every stable line (all but the last, which may still grow) that
    /// hasn't been translated yet, into all targets (minus the source language).
    /// `includingLast` at finalize. FIFO via the engine.
    private func translateStableLines(includingLast: Bool = false) {
        guard !translateTargets.isEmpty, let t = ensureTranslateEngine() else { return }
        let targets = translateTargets.subtracting([sourceLangName].compactMap { $0 }).sorted()
        guard !targets.isEmpty else { return }
        let lines = transcript.lines
        let upTo = includingLast ? lines.count : max(0, lines.count - 1)
        for i in 0..<upTo {
            let line = lines[i]
            if translatedIDs.contains(line.id) { continue }
            translatedIDs.insert(line.id)
            // O3: if this line's text was already translated as interim, reuse the
            // cached translations and skip the DNA3 turn entirely. Only reuse the
            // targets we actually have cached; queue the engine for any that miss.
            if let cached = interimCache.get(line.text) {
                let missing = targets.filter { cached[$0] == nil }
                for tgt in targets where cached[tgt] != nil {
                    transcript.setTranslation(line.id, lang: tgt, cached[tgt]!)
                }
                if missing.isEmpty { continue }
                t.translate(line.text, into: missing, id: line.id)
                continue
            }
            t.translate(line.text, into: targets, id: line.id)
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
    /// 개인정보 마스킹 — when on, exports run PIIRedactor over the rendered text so
    /// emails/전화/주민번호 become category tags before the file is written (the
    /// on-screen transcript is untouched). Default off; persisted.
    var piiRedactionEnabled: Bool = (UserDefaults.standard.object(forKey: "piiRedactionEnabled") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(piiRedactionEnabled, forKey: "piiRedactionEnabled") }
    }
    /// Resolved auto-save folder: persisted choice, else Documents, else home.
    /// Static so both `autoSaveFolder` and `workspace` can seed from it without
    /// a self-reference during stored-property init.
    static func defaultSaveFolder() -> URL {
        if let p = UserDefaults.standard.string(forKey: "autoSaveFolder") { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
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
            streamWavRoots: [capture.segmentDirectory])
    }

    // MARK: session lifecycle

    private var countdownTask: Task<Void, Never>?

    /// #4 — a brief 3·2·1 countdown before the mic opens, so the user can get
    /// ready; recording starts the instant it hits 0. Cancellable mid-count.
    func startCountdown(from n: Int = 3) {
        guard phase == .idle || phase == .done || isError else { return }
        guard AssetManifest.modelIsValid() else { phase = .error("model not ready"); return }
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            for k in stride(from: n, through: 1, by: -1) {
                phase = .countingDown(k)
                try? await Task.sleep(nanoseconds: 750_000_000)
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
        transcript.reset()
        speakerNames = [:]
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedIDs.removeAll()
        interimCache.clear()
        clearSummary()
        fileName = ""; chunksDone = 0; chunksTotal = 0
        livePartial = ""
        phase = .idle
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
        translatedIDs.insert(id)
        t.translate(line.text, into: targets, id: id)
    }

    func start() {
        guard AssetManifest.modelIsValid() else {
            phase = .error("model not ready"); return
        }
        transcript.reset()
        speakerNames = [:]
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedIDs.removeAll()
        interimCache.clear()
        clearSummary()
        // Prefill from the live calendar event. ContentView observes calendar.event.id
        // and calls ensurePrepBrief() on change, so we do NOT call it here too (that
        // double-ran the headless aggregation and raced two detached tasks).
        Task { await calendar.loadCurrentEvent() }
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
        capture.firstSegmentSeconds = min(3, win)
        capture.overlapSeconds = min(3, max(1, win * 0.3))
        capture.onSegment = { [weak self] offset, url in
            self?.engine?.feed(offset: offset, wav: url)
        }
        capture.onLevel = { [weak self] lvl in self?.level = lvl }

        // streaming preview (interim text before a window closes). The preview
        // engine MUST run with a forced language — it decodes tiny ~1.5s clips
        // where auto-detect misfires (→ English). If the user picked a language,
        // start now; if auto, wait for the main engine's [lang] detection (see
        // .languageDetected below) so previews match the committed transcript.
        livePartial = ""
        if livePreviewEnabled {
            preview.onText = { [weak self] t in self?.livePartial = t }
            capture.onPreview = { [weak self] url in self?.preview.feed(wav: url) }
            if let lang = languageTokenID { preview.start(config: makeConfig(), lang: lang) }
        } else {
            capture.onPreview = nil
        }

        do { try e.start() }
        catch { phase = .error("engine start failed: \(error.localizedDescription)") }
    }

    /// Drag-&-drop: transcribe an audio FILE through the same resident engine +
    /// pipeline as the mic (diarization, OSD, confidence, exports all reused).
    /// The file is fed off the main actor (FileFeeder) so a long file never
    /// freezes the UI. Ignored while a session is already busy.
    func transcribeFile(_ url: URL) {
        guard phase == .idle || phase == .done || isError else { return }
        guard AssetManifest.modelIsValid() else { phase = .error("model not ready"); return }
        transcript.reset()
        speakerNames = [:]
        autoRecognizedSpeakers.removeAll()
        pendingEnrollment.clear()
        lastAutoSaved = nil
        translatedIDs.removeAll()
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
        catch { phase = .error("engine start failed: \(error.localizedDescription)") }
    }

    /// Pause live capture — the mic stays warm; the paused span is dropped so the
    /// recording skips the break. No engine flush (the session continues).
    func pauseRecording() {
        guard phase == .recording else { return }
        capture.pause()
        phase = .paused
    }
    func resumeRecording() {
        guard phase == .paused else { return }
        capture.resume()
        phase = .recording
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
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
        phase = .ready
        do { try capture.start(); phase = .recording }
        catch { phase = .error("mic start failed: \(error.localizedDescription)") }
    }

    func engine(didEmit event: EngineEvent) {
        switch event {
        case .progressTotal(let n): chunksTotal = n
        case .progressChunk(let k): chunksDone = max(chunksDone, k)
        case .wordSectionBegin:
            livePartial = ""; transcript.ingest(event)  // committed → drop interim
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
        default: transcript.ingest(event)
        }
    }

    func engineDidFlush() { finalizeOnce() }

    func engine(didTerminate code: Int32) {
        // file mode exits 0 on its own after <<FLUSH_END>>; finalize if a late
        // exit beats the FLUSH_END line (finalizeOnce is idempotent).
        if code == 0 { finalizeOnce(); return }
        if phase != .done, phase != .flushing {
            preview.stop(); livePartial = ""
            phase = .error("engine exited (\(code))")
        }
    }

    private func finalizeOnce() {
        guard phase != .done else { return }
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
        preview.stop(); livePartial = ""   // tear down the 2nd engine + interim text
        phase = .done
        translateStableLines(includingLast: true)  // translate the final line(s) too
        interimCache.clear()   // O3: final lines just consulted the cache — now wipe it (session boundary)
        stopLiveRail()       // recording ended — keep the accumulated rail for review
        stopLiveCoach(); recomputeCoach()   // stop the 1Hz loop, snapshot the final transcript once
        calendar.matchToSpeakers(speakerNames)   // attendee ↔ speaker match + 결석 flag
        autoSaveMarkdown()   //회의/전사 완료 → .md 자동저장 (켜져 있을 때)
        // A.I 요약이 켜진 라이브 세션: DNA3가 이미 뜨므로 제목도 생성해 파일명을 AI 제목으로
        // 승격(rename)한다. 제목을 먼저 enqueue → 요약본 저장 전에 rename이 끝나 같은 베이스로 묶임.
        if autoSaveEnabled, autoSaveSummary, fileName.isEmpty, let s = ensureSummaryEngine() {
            s.generateTitle(lines: attributedLines)
        }
        if autoSaveSummary, autoSaveEnabled { autoSummarizeForSave() }   // 요약본 별개 저장
    }

    // MARK: export

    func exportMarkdown(to url: URL) throws {
        try applyPII(Exporters.markdown(transcript.lines, names: speakerNames, summary: meetingSummary))
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mask PII in an about-to-be-exported string when 개인정보 마스킹 is on. The
    /// live transcript is never mutated — redaction is export-only.
    private func applyPII(_ s: String) -> String { piiRedactionEnabled ? PIIRedactor.redact(s) : s }

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
        try applyPII(Exporters.srt(transcript.lines, names: speakerNames))
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportVTT(to url: URL) throws {
        try applyPII(Exporters.vtt(transcript.lines, names: speakerNames))
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportText(to url: URL) throws {
        try applyPII(Exporters.plainText(transcript.lines, names: speakerNames))
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportJSON(to url: URL) throws {
        try applyPII(Exporters.json(transcript.lines, names: speakerNames, settings: editorSettings))
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportCutList(to url: URL) throws {
        try applyPII(Exporters.cutListCSV(transcript.lines, settings: editorSettings))
            .write(to: url, atomically: true, encoding: .utf8)
    }
    func exportChapters(to url: URL) throws {
        try applyPII(Exporters.youtubeChapters(transcript.lines, settings: editorSettings))
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
