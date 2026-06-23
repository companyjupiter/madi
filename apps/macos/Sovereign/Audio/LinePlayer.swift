// LinePlayer.swift — click a transcript line, hear that moment. For file-
// transcribed sessions the original media (audio OR video) is still on disk and
// its timeline matches the transcript, so we seek an AVPlayer to the line's
// start and auto-stop at its end. Tapping the playing line stops it; tapping
// another switches. (Live recordings have no retained continuous audio yet —
// SessionController only offers this when a source media URL exists.)

import Foundation
import AVFoundation

@Observable
@MainActor
final class LinePlayer {
    /// The line currently playing (drives the play/pause icon), nil when idle.
    private(set) var currentLine: UUID?

    private var player: AVPlayer?
    private var endObserver: Any?

    /// Toggle playback of `url`'s [from, to] span, tagged by the line id.
    func toggle(url: URL, line lineID: UUID, from: Double, to: Double) {
        if currentLine == lineID { stop(); return }   // tap-again = stop
        stop()
        let p = AVPlayer(url: url)
        player = p
        currentLine = lineID

        let start = CMTime(seconds: max(0, from), preferredTimescale: 600)
        p.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // Ignore a stale seek completion if the user already switched lines.
            guard let self, self.currentLine == lineID else { return }
            p.play()
        }
        // Auto-stop at the line's end (min 0.3s so a zero-span line still plays a bit).
        let end = CMTime(seconds: max(from + 0.3, to), preferredTimescale: 600)
        endObserver = p.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
            self?.stop()
        }
    }

    func stop() {
        if let o = endObserver { player?.removeTimeObserver(o); endObserver = nil }
        player?.pause()
        player = nil
        currentLine = nil
    }
}
