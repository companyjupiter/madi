// Segmenter.swift — pure SEG/OVERLAP windowing arithmetic, no audio/IO deps.
//
// Extracted from AudioCapture so the boundary math (segment length, overlap
// tail, global offset, drift) is unit-testable in isolation (verification
// Layer 2). The mic tap and the file-injection harness both push 16 kHz Int16
// frames and receive ready segments; only AudioCapture turns them into WAVs.
//
// Reproduces the old runner's ffmpeg segmentation exactly:
//   - each window is SEG seconds; the FIRST has no left context,
//   - every subsequent window is prepended with OVERLAP seconds of the prior
//     window's tail (so a word split across a boundary is recovered),
//   - the global offset of a segment is the start time of its FIRST sample,
//     i.e. (emitted_body_samples_so_far - overlap_len) / 16000.

import Foundation

struct Segmenter {
    let sampleRate: Int
    var segmentSeconds: Double
    var overlapSeconds: Double
    /// ASYMMETRIC FIRST WINDOW: the first segment closes after this many seconds
    /// (short → fast time-to-first-text), then every later window is the full
    /// `segmentSeconds` (full Whisper context, no accuracy loss after the first).
    /// Defaults to `segmentSeconds` (symmetric) when not specified.
    var firstSegmentSeconds: Double
    /// EARLY FLUSH (2026-07-05): close the window before `segmentSeconds` when
    /// the speaker has clearly finished — ≥ `earlyFlushSilenceSeconds` of
    /// trailing silence after ≥ `earlyFlushMinBodySeconds` of body that
    /// contained speech. A 10 s window whose utterance ends at 4 s used to sit
    /// ~5.5 s doing nothing before the text could even start decoding; in the
    /// clinic's short-turn rhythm this is most of the felt latency.
    /// Silence is judged per 10 ms hop against an ADAPTIVE threshold
    /// (max(200, 0.15 × loudest hop this window)) so far-field mics — whose
    /// SPEECH mean can be as low as ~220 (AMI measurements) — aren't chopped.
    /// 0 disables (bit-identical legacy windowing).
    var earlyFlushSilenceSeconds: Double = 0.7
    var earlyFlushMinBodySeconds: Double = 2.5

    private var pending: [Int16] = []      // not-yet-emitted samples of the current window
    private var overlapTail: [Int16] = []   // last OVERLAP seconds of the previous window
    private var emittedBody: Int = 0         // total NON-overlap samples emitted (offset clock)
    private var segmentsEmitted: Int = 0     // how many bodies cut so far (selects window size)

    // early-flush analyzer state (10 ms hop stream, reset-aware across cuts)
    private var hopRemainder: [Int16] = []   // partial hop carried between pushes
    private var trailingSilence: Int = 0     // consecutive silent samples at the stream tail
    private var windowHadSpeech = false      // any voiced hop since the last cut
    private var windowPeakMean: Double = 0   // loudest hop mean |x| seen (adaptive floor)

    init(sampleRate: Int = Int(WavWriter.sampleRate),
         segmentSeconds: Double = 10, overlapSeconds: Double = 3,
         firstSegmentSeconds: Double? = nil) {
        self.sampleRate = sampleRate
        self.segmentSeconds = segmentSeconds
        self.overlapSeconds = overlapSeconds
        self.firstSegmentSeconds = firstSegmentSeconds ?? segmentSeconds
    }

    var segSamples: Int { Int(segmentSeconds * Double(sampleRate)) }
    var firstSegSamples: Int { Int(firstSegmentSeconds * Double(sampleRate)) }
    var overlapSamples: Int { Int(overlapSeconds * Double(sampleRate)) }

    /// Body length the NEXT cut targets: the short first window, then the steady one.
    private var nextBodyLen: Int { segmentsEmitted == 0 ? firstSegSamples : segSamples }

    /// A segment ready to write: its global start offset (seconds) and samples
    /// (overlap tail + body).
    struct Segment: Equatable {
        let offset: Double
        let samples: [Int16]
        let bodyCount: Int   // samples excluding the prepended overlap (for assertions)
        /// Whether any voiced hop was seen in this window (W1 coverage watchdog:
        /// a segment WITH speech that yields zero words is a suspected miss).
        var hadSpeech: Bool = true
    }

    /// Push converted frames; returns any full segments that closed.
    mutating func push(_ frames: [Int16]) -> [Segment] {
        pending.append(contentsOf: frames)
        analyze(frames)
        var out: [Segment] = []
        while pending.count >= nextBodyLen { out.append(cut(bodyLen: nextBodyLen)) }
        // early flush: the speaker finished — don't sit out the rest of the window
        if out.isEmpty, earlyFlushSilenceSeconds > 0,
           windowHadSpeech,
           pending.count >= Int(earlyFlushMinBodySeconds * Double(sampleRate)),
           trailingSilence >= Int(earlyFlushSilenceSeconds * Double(sampleRate)),
           trailingSilence < pending.count {
            out.append(cut(bodyLen: pending.count))
        }
        return out
    }

    /// 10 ms-hop silence tracking with an adaptive threshold (see earlyFlush*).
    private mutating func analyze(_ frames: [Int16]) {
        guard earlyFlushSilenceSeconds > 0 else { return }
        let buf = hopRemainder + frames
        let hop = sampleRate / 100          // 10 ms
        var i = 0
        while i + hop <= buf.count {
            var sum = 0
            for s in buf[i..<i + hop] { sum += abs(Int(s)) }
            let mean = Double(sum) / Double(hop)
            if mean > windowPeakMean { windowPeakMean = mean }
            let threshold = max(200.0, 0.15 * windowPeakMean)
            if mean < threshold {
                trailingSilence += hop
            } else {
                trailingSilence = 0
                windowHadSpeech = true
            }
            i += hop
        }
        hopRemainder = Array(buf[i...])
    }

    /// The in-progress (not-yet-closed) window — overlap context + pending body.
    /// Same audio the NEXT segment will hold; decoding it gives a live preview
    /// before the window closes. `pendingCount` lets the caller throttle previews.
    var pendingCount: Int { pending.count }
    func previewWindow() -> (offset: Double, samples: [Int16]) {
        let offset = max(0, Double(emittedBody - overlapTail.count) / Double(sampleRate))
        return (offset, overlapTail + pending)
    }

    /// Flush the final partial window (called once at stop). Returns nil if empty.
    mutating func flush() -> Segment? {
        guard !pending.isEmpty else { return nil }
        return cut(bodyLen: pending.count)
    }

    private mutating func cut(bodyLen: Int) -> Segment {
        let body = Array(pending.prefix(bodyLen))
        pending.removeFirst(bodyLen)
        let samples = overlapTail + body
        // offset = start time of the FIRST sample of this segment (incl. overlap)
        let offset = max(0, Double(emittedBody - overlapTail.count) / Double(sampleRate))
        let seg = Segment(offset: offset, samples: samples, bodyCount: body.count,
                          hadSpeech: earlyFlushSilenceSeconds <= 0 || windowHadSpeech)
        emittedBody += body.count
        overlapTail = Array(body.suffix(overlapSamples))
        segmentsEmitted += 1
        // early-flush analyzer: the new window starts fresh — anything still
        // pending is (at most) the tail silence that triggered the cut.
        windowHadSpeech = trailingSilence < pending.count
        return seg
    }
}
