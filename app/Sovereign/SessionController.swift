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
        case idle, engineStarting, ready, recording, flushing, done
        case error(String)
    }

    private(set) var phase: Phase = .idle
    var level: Float = 0
    let transcript = TranscriptStore()

    var diarize = true
    var inputDeviceID: AudioDeviceID?          // nil = system default mic
    var availableInputs: [AudioInputDevice] { AudioDevices.inputs() }
    var osd = true
    var languageTokenID: Int?
    var speakerNames: [Int: String] = [:]

    private var engine: EngineProcess?
    private let capture = AudioCapture()

    // MARK: session lifecycle

    func start() {
        guard AssetManifest.modelIsValid() else {
            phase = .error("model not ready"); return
        }
        transcript.reset()
        phase = .engineStarting

        let cfg = EngineProcess.Config(
            binaryURL: Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/transcribe"),
            modelURL: AssetManifest.modelURL,
            bpeURL: AssetManifest.bundledBPE,
            assetsDir: AssetManifest.bundledAssetsDir,
            diarize: diarize, osd: osd,
            languageTokenID: languageTokenID, maxSpeakers: 8, voiceprintsDir: nil)

        let e = EngineProcess(config: cfg)
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

    func stop() {
        guard phase == .recording else { return }
        phase = .flushing
        capture.stop()          // flush final tail segment(s) into the engine
        engine?.flush()         // → SPKFIX/SPKOV → <<FLUSH_END>>
    }

    // MARK: EngineProcessDelegate

    func engineDidBecomeReady() {
        phase = .ready
        do { try capture.start(); phase = .recording }
        catch { phase = .error("mic start failed: \(error.localizedDescription)") }
    }

    func engine(didEmit event: EngineEvent) {
        transcript.ingest(event)
    }

    func engineDidFlush() {
        transcript.finalize()
        engine?.terminate()
        engine = nil
        phase = .done
    }

    func engine(didTerminate code: Int32) {
        if phase != .done, phase != .flushing {
            phase = .error("engine exited (\(code))")
        }
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
}
