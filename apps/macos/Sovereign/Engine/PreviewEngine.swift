// PreviewEngine.swift — latest-only scheduling for the resident engine's
// throwaway PREVIEW lane. The main engine commits text only when a 10s window
// CLOSES; PREVIEW decodes the IN-PROGRESS window every ~1s so the user sees
// interim text without loading a second copy of the model.

import Foundation

@MainActor
final class PreviewEngine {
    /// The just-completed preview of the in-progress window: its words with
    /// window-relative times, and the window's start (session seconds) — so
    /// the caller can drop what the committed transcript already shows.
    var onWords: ((_ words: [PreviewTrim.TimedWord], _ windowStart: Double, _ forced: String) -> Void)?

    /// The submit closure returns the forced prefix it sent (S2 `%%FP`), so
    /// the words that come back can be stripped of exactly that echo.
    private var submit: ((URL, Double) -> String)?
    private var admitted = true
    private var inFlight = false
    private var latest: (URL, Double)?   // latest-only: supersedes stale pre-ready/busy previews
    private var building: [PreviewTrim.TimedWord] = []   // words of the preview currently streaming in
    private var buildingStart: Double = 0
    private var buildingForced = ""

    /// Auto-language sessions call this only after the committed lane has locked
    /// its language. Selected-language sessions can arm it immediately.
    func start(submit: @escaping (URL, Double) -> String) {
        guard self.submit == nil else { return }
        self.submit = submit
        pump()
    }

    func feed(wav: URL, offset: Double) {
        guard submit != nil else { return }
        latest = (wav, offset)
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
        guard admitted, !inFlight, let (wav, offset) = latest, let submit else { return }
        latest = nil
        inFlight = true
        building = []; buildingStart = offset
        buildingForced = submit(wav, offset)
    }

    func stop() {
        submit = nil; admitted = true; inFlight = false
        building = []; latest = nil
    }

    /// Returns true when the event belongs exclusively to the preview lane.
    func consume(_ event: EngineEvent) -> Bool {
        switch event {
        case .previewBegin:
            building = []
        case .previewWord(let t0, let t1, let text):
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            building.append(PreviewTrim.TimedWord(t0: t0, t1: t1, text: t))
        case .previewPartial:
            break
        case .previewEnd:
            if !building.isEmpty { onWords?(building, buildingStart, buildingForced) }
            building = []
            inFlight = false
            pump()
        default:
            return false
        }
        return true
    }
}
