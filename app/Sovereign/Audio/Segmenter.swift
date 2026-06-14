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

    private var pending: [Int16] = []      // not-yet-emitted samples of the current window
    private var overlapTail: [Int16] = []   // last OVERLAP seconds of the previous window
    private var emittedBody: Int = 0         // total NON-overlap samples emitted (offset clock)
    private var segmentsEmitted: Int = 0     // how many bodies cut so far (selects window size)

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
    }

    /// Push converted frames; returns any full segments that closed.
    mutating func push(_ frames: [Int16]) -> [Segment] {
        pending.append(contentsOf: frames)
        var out: [Segment] = []
        while pending.count >= nextBodyLen { out.append(cut(bodyLen: nextBodyLen)) }
        return out
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
        let seg = Segment(offset: offset, samples: samples, bodyCount: body.count)
        emittedBody += body.count
        overlapTail = Array(body.suffix(overlapSamples))
        segmentsEmitted += 1
        return seg
    }
}
