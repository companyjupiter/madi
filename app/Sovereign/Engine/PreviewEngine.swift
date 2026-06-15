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
    private var queued: URL?       // a preview that arrived before the engine was ready
    private var building = ""      // words of the preview currently streaming in

    func start(config base: EngineProcess.Config) {
        guard engine == nil else { return }
        var c = base
        c.diarize = false; c.osd = false; c.voiceprintsDir = nil; c.fileURL = nil
        let e = EngineProcess(config: c)
        e.delegate = self
        engine = e
        try? e.start()
    }

    func feed(wav: URL) {
        guard let e = engine else { return }
        if ready { e.feed(offset: 0, wav: wav) } else { queued = wav }
    }

    func stop() {
        engine?.terminate()
        engine = nil; ready = false; building = ""; queued = nil
    }

    // MARK: EngineProcessDelegate
    func engineDidBecomeReady() {
        ready = true
        if let w = queued { queued = nil; engine?.feed(offset: 0, wav: w) }
    }
    func engine(didEmit event: EngineEvent) {
        switch event {
        case .wordSectionBegin:
            // a new preview's words are about to stream — publish the previous
            // preview's COMPLETE text now (flicker-free: never shows a half cue).
            if !building.isEmpty { onText?(building) }
            building = ""
        case .word(_, _, let text, _):
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if !building.isEmpty, t.first.map({ !",.!?…".contains($0) }) ?? true { building += " " }
            building += t
        default: break   // SPK/SEG_END/perf noise — ignored for previews
        }
    }
    func engineDidFlush() {}
    func engine(didTerminate code: Int32) { ready = false }
}
