// PreviewEngine.swift — latest-only scheduling for the resident engine's
// throwaway PREVIEW lane. The main engine commits text only when a 10s window
// CLOSES; PREVIEW decodes the IN-PROGRESS window every ~1s so the user sees
// interim text without loading a second copy of the model.

import Foundation

@MainActor
final class PreviewEngine {
    /// Latest interim text (the just-completed preview of the in-progress window).
    var onText: ((String) -> Void)?

    private var submit: ((URL) -> Void)?
    private var admitted = true
    private var inFlight = false
    private var latest: URL?       // latest-only: supersedes stale pre-ready/busy previews
    private var building = ""      // words of the preview currently streaming in

    /// Auto-language sessions call this only after the committed lane has locked
    /// its language. Selected-language sessions can arm it immediately.
    func start(submit: @escaping (URL) -> Void) {
        guard self.submit == nil else { return }
        self.submit = submit
        pump()
    }

    func feed(wav: URL) {
        guard submit != nil else { return }
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
        guard admitted, !inFlight, let wav = latest, let submit else { return }
        latest = nil
        inFlight = true
        building = ""
        submit(wav)
    }

    func stop() {
        submit = nil; admitted = true; inFlight = false
        building = ""; latest = nil
    }

    /// Returns true when the event belongs exclusively to the preview lane.
    func consume(_ event: EngineEvent) -> Bool {
        switch event {
        case .previewBegin:
            building = ""
        case .previewWord(let text):
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if !building.isEmpty, t.first.map({ !",.!?…".contains($0) }) ?? true { building += " " }
            building += t
        case .previewPartial:
            break
        case .previewEnd:
            if !building.isEmpty { onText?(building) }
            building = ""
            inFlight = false
            pump()
        default:
            return false
        }
        return true
    }
}
