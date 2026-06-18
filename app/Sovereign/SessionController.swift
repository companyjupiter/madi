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
        case idle, engineStarting, ready, recording, paused, processing, flushing, done
        case error(String)
    }

    private(set) var phase: Phase = .idle
    var level: Float = 0
    let transcript = TranscriptStore()

    // file-mode progress (nil when not transcribing a file)
    private(set) var fileName: String = ""
    private(set) var chunksDone = 0
    private(set) var chunksTotal = 0

    var diarize = true
    var inputDeviceID: AudioDeviceID?          // nil = system default mic
    var availableInputs: [AudioInputDevice] { AudioDevices.inputs() }
    var osd = true
    // restored from the last launch (0 / unset = auto-detect)
    var languageTokenID: Int? = {
        let v = UserDefaults.standard.integer(forKey: "languageTokenID")
        return v > 0 ? v : nil
    }()
    var speakerNames: [Int: String] = [:]

    /// Live segment window (s) — the live FELT-latency knob. Text lands when a
    /// window closes, so a shorter window = snappier live text but less Whisper
    /// context (more boundary error). Default 10 = current accuracy (no
    /// regression); applied at the next record start. Persisted.
    var liveWindowSeconds: Double = (UserDefaults.standard.object(forKey: "liveWindowSeconds") as? Double) ?? 10 {
        didSet { UserDefaults.standard.set(liveWindowSeconds, forKey: "liveWindowSeconds") }
    }

    /// Streaming preview: a 2nd engine decodes the in-progress window every ~1.5s
    /// for instant interim text — NO accuracy cost (committed text is unchanged).
    /// Costs a 2nd resident model (~830 MB) only while recording. Persisted.
    var livePreviewEnabled: Bool = (UserDefaults.standard.object(forKey: "livePreviewEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(livePreviewEnabled, forKey: "livePreviewEnabled") }
    }
    /// Interim "진행 중" text (cleared when the window's committed words land).
    private(set) var livePartial: String = ""
    private let preview = PreviewEngine()

    /// Editor-feature toggles + thresholds (persisted). The UI binds to this; all
    /// editor exports/stats read from it.
    var editorSettings = EditorSettings.load() { didSet { editorSettings.save() } }

    // ── auto-save: write a .md when a session finishes (live stop or file done) ──
    var autoSaveEnabled: Bool = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoSaveEnabled, forKey: "autoSaveEnabled") }
    }
    var autoSaveFolder: URL = {
        if let p = UserDefaults.standard.string(forKey: "autoSaveFolder") { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }() {
        didSet { UserDefaults.standard.set(autoSaveFolder.path, forKey: "autoSaveFolder") }
    }
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
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HHmm"
            base = "회의 \(df.string(from: Date()))"
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
        } catch { /* non-fatal — manual export remains available */ }
    }

    /// Rename a speaker (applies to all their lines + exports). Empty clears it
    /// back to "Speaker N". Names are per-transcription (speaker ids don't carry
    /// across files), so they reset on each new session.
    func renameSpeaker(_ id: Int, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { speakerNames[id] = nil } else { speakerNames[id] = t }
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
            languageTokenID: languageTokenID, maxSpeakers: 8, voiceprintsDir: nil,
            streamWavRoots: [capture.segmentDirectory])
    }

    // MARK: session lifecycle

    func start() {
        guard AssetManifest.modelIsValid() else {
            phase = .error("model not ready"); return
        }
        transcript.reset()
        speakerNames = [:]
        lastAutoSaved = nil
        phase = .engineStarting

        let e = EngineProcess(config: makeConfig())
        e.delegate = self
        engine = e

        capture.inputDeviceID = inputDeviceID  // bind chosen mic before start
        // live FELT-latency knob — applied before the segmenter resets in capture.start()
        capture.segmentSeconds = liveWindowSeconds
        capture.firstSegmentSeconds = min(3, liveWindowSeconds)
        capture.overlapSeconds = min(3, max(1, liveWindowSeconds * 0.3))
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
        lastAutoSaved = nil
        fileName = url.lastPathComponent
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
        case .wordSectionBegin: livePartial = ""; transcript.ingest(event)  // committed → drop interim
        case .languageDetected(let tok):
            // auto-detect locked → start the preview engine in THAT language
            // (no-op if already started / preview off)
            if livePreviewEnabled { preview.start(config: makeConfig(), lang: tok) }
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
        engine?.terminate()
        engine = nil
        preview.stop(); livePartial = ""   // tear down the 2nd engine + interim text
        phase = .done
        autoSaveMarkdown()   //회의/전사 완료 → .md 자동저장 (켜져 있을 때)
    }

    // MARK: export

    func exportMarkdown(to url: URL) throws {
        try Exporters.markdown(transcript.lines, names: speakerNames)
            .write(to: url, atomically: true, encoding: .utf8)
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
        let c = EditorCuts.tighten(transcript.lines, editorSettings)
        return (c.count, c.reduce(0) { $0 + $1.duration })
    }
}
