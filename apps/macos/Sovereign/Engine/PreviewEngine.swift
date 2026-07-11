// PreviewEngine.swift — a second, throwaway STREAM engine for live streaming
// preview. The main engine commits text only when a 10s window CLOSES; this one
// decodes the IN-PROGRESS window (fed every ~1.5s by AudioCapture) so the user
// sees interim "진행 중" text immediately — with NO accuracy cost, because the
// committed transcript still comes from the untouched main engine.
//
// Diarization/OSD are off (we only want text), language is forced to match.
// Its diar/offset state is garbage and ignored — we read only the words.

import Foundation

@MainActor
final class PreviewEngine: EngineProcessDelegate {
    /// Latest interim text (the just-completed preview of the in-progress window).
    var onText: ((String) -> Void)?

    private var engine: EngineProcess?
    private var ready = false
    private var admitted = true
    private var inFlight = false
    private var latest: URL?       // latest-only: supersedes stale pre-ready/busy previews
    private var building = ""      // words of the preview currently streaming in

    /// `lang` FORCES the preview language (token id). Critical: previews decode
    /// tiny ~1.5s clips where Whisper auto-detect misfires (often to English), so
    /// the caller passes the main engine's selected/detected language. Idempotent
    /// (no-op if already started).
    func start(config base: EngineProcess.Config, lang: Int?) {
        guard engine == nil else { return }
        var c = base
        c.diarize = false; c.osd = false; c.voiceprintsDir = nil; c.fileURL = nil
        c.encoderF16Cache = false
        if let l = lang { c.languageTokenID = l }
        let e = EngineProcess(config: c)
        e.delegate = self
        engine = e
        try? e.start()
    }

    func feed(wav: URL) {
        guard engine != nil else { return }
        latest = wav
        pump()
    }

    /// Main transcription and DNA captions have admission priority. While they
    /// are busy we retain only the newest preview; reopening the gate decodes
    /// that snapshot instead of replaying a stale FIFO.
    func setAdmitted(_ value: Bool) {
        admitted = value
        pump()
    }

    private func pump() {
        guard ready, admitted, !inFlight, let wav = latest, let engine else { return }
        latest = nil
        inFlight = true
        building = ""
        engine.feed(offset: 0, wav: wav)
    }

    func stop() {
        engine?.terminate()
        engine = nil; ready = false; admitted = true; inFlight = false
        building = ""; latest = nil
    }

    // MARK: EngineProcessDelegate
    func engineDidBecomeReady() {
        ready = true
        pump()
    }
    func engine(didEmit event: EngineEvent) {
        switch event {
        case .wordSectionBegin:
            break
        case .word(_, _, let text, _):
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if !building.isEmpty, t.first.map({ !",.!?…".contains($0) }) ?? true { building += " " }
            building += t
        case .segmentEnd:
            if !building.isEmpty { onText?(building) }
            building = ""
            inFlight = false
            pump()
        default: break
        }
    }
    func engineDidFlush() {}
    func engine(didTerminate code: Int32) { ready = false; inFlight = false }
}
