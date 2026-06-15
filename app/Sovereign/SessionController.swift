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
        case idle, engineStarting, ready, recording, processing, flushing, done
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
            languageTokenID: languageTokenID, maxSpeakers: 8, voiceprintsDir: nil)
    }

    // MARK: session lifecycle

    func start() {
        guard AssetManifest.modelIsValid() else {
            phase = .error("model not ready"); return
        }
        transcript.reset()
        speakerNames = [:]
        phase = .engineStarting

        let e = EngineProcess(config: makeConfig())
        e.delegate = self
        engine = e

        capture.inputDeviceID = inputDeviceID  // bind chosen mic before start
        capture.onSegment = { [weak self] offset, url in
            self?.engine?.feed(offset: offset, wav: url)
        }
        capture.onLevel = { [weak self] lvl in self?.level = lvl }

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

    func stop() {
        guard phase == .recording else { return }
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
        default: transcript.ingest(event)
        }
    }

    func engineDidFlush() { finalizeOnce() }

    func engine(didTerminate code: Int32) {
        // file mode exits 0 on its own after <<FLUSH_END>>; finalize if a late
        // exit beats the FLUSH_END line (finalizeOnce is idempotent).
        if code == 0 { finalizeOnce(); return }
        if phase != .done, phase != .flushing {
            phase = .error("engine exited (\(code))")
        }
    }

    private func finalizeOnce() {
        guard phase != .done else { return }
        transcript.finalize()
        engine?.terminate()
        engine = nil
        phase = .done
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
        try Exporters.json(transcript.lines, names: speakerNames)
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
