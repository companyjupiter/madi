// EnergyArc.swift — pure, deterministic compute of meeting "energy" over time.
//
// Bins the meeting timespan into N buckets and scores each bucket by how
// "alive" the room was: speaking density (fraction of the bucket spent with
// someone talking) + overlap activity (interruptions land harder) − silence.
// Result is normalized to 0...1 across the meeting for a sparkline.
//
// Foundation-only by design (NO SwiftUI) so it can join SovereignCore for
// XCTest. Stateless static API, fully deterministic for a given [Line].

import Foundation

enum EnergyArc {
    struct Snapshot {
        var values: [Double]
        var speakerMix: [[(speaker: Int, share: Double)]]
        var spanStart: Double
        var spanEnd: Double

        static let empty = Snapshot(values: [], speakerMix: [], spanStart: 0, spanEnd: 0)
    }

    /// Per-bucket energy in 0...1 over the meeting timespan.
    ///
    /// - Parameters:
    ///   - lines: diarized transcript lines (uses each line's start/end and
    ///            overlapSpeakers; empty/degenerate input → []).
    ///   - buckets: number of time bins to emit (clamped to ≥ 1).
    ///   - spanEnd: optional live "now" (same clock as line offsets). During a
    ///              recording this extends the span past the last committed line
    ///              so the graph grows in real time — ongoing silence shows as a
    ///              low tail instead of the graph freezing at the last commit.
    /// - Returns: `buckets` values in 0...1, or [] when there is no usable span.
    static func compute(lines: [Line], buckets: Int = 30, spanEnd: Double? = nil) -> [Double] {
        snapshot(lines: lines, buckets: buckets, spanEnd: spanEnd).values
    }

    /// Energy values + speaker mix computed from the same bucket pass.
    ///
    /// Long live sessions render this graph repeatedly while the transcript is
    /// still growing. Keeping `compute()` and `speakerShares()` as separate full
    /// scans doubled that UI-side work; `snapshot()` is the shared primitive used
    /// by the app, while the two older APIs remain as compatibility wrappers for
    /// tests and pure-logic callers.
    static func snapshot(lines: [Line], buckets: Int = 30, spanEnd: Double? = nil) -> Snapshot {
        let n = max(1, buckets)
        guard !lines.isEmpty else {
            return Snapshot(values: [], speakerMix: [], spanStart: 0, spanEnd: max(0, spanEnd ?? 0))
        }

        // Meeting span from the earliest onset to the latest offset (or live now).
        var t0 = Double.greatestFiniteMagnitude
        var t1 = 0.0
        for l in lines {
            t0 = min(t0, l.start)
            t1 = max(t1, l.end)
        }
        t1 = max(t1, spanEnd ?? 0)
        let span = t1 - t0
        guard span > 0 else { return Snapshot(values: [], speakerMix: [], spanStart: t0, spanEnd: t1) }

        let bucketDur = span / Double(n)
        guard bucketDur > 0 else { return Snapshot(values: [], speakerMix: [], spanStart: t0, spanEnd: t1) }

        // Raw energy accumulators per bucket.
        var speech = [Double](repeating: 0, count: n)   // seconds of speech in bucket
        var overlap = [Double](repeating: 0, count: n)  // overlap-weighted speech events
        var turns = [Double](repeating: 0, count: n)    // rapid speaker hand-offs (back-and-forth)
        var words = [Double](repeating: 0, count: n)    // word onsets (speech-rate signal)
        var speakerSeconds = [[Int: Double]](repeating: [:], count: n)

        // Turn-taking energy: a speaker change with only a short gap is lively
        // discussion; the SAME density of continuous monologue is not — so a
        // continuously-busy meeting still shows flow (rapid exchange vs. one
        // person holding the floor). Counting only sub-2s hand-offs also means a
        // lone line after a long silence adds no energy (keeps "silence → 0").
        for i in 1..<lines.count {
            guard lines[i].speaker != lines[i - 1].speaker else { continue }
            guard lines[i].start - lines[i - 1].end < 2.0 else { continue }
            let b = min(max(Int((lines[i].start - t0) / bucketDur), 0), n - 1)
            turns[b] += 1
        }

        for l in lines {
            let s = max(t0, l.start)
            let e = min(t1, l.end)
            guard e > s else { continue }
            // Overlap weight: each concurrent extra speaker adds a flat boost.
            let ovBoost = Double(l.overlapSpeakers.count)

            // Speech-rate signal: word onsets per bucket. Density alone is
            // binary (talking → 1, silence → 0), which rendered the graph as
            // all-or-nothing columns; the words-per-second rate varies WITHIN
            // continuous speech (fast argument vs. slow reading), giving the
            // midtones the sparkline was missing.
            for w in l.words where w.t0 >= t0 && w.t0 < t1 {
                let b = min(max(Int((w.t0 - t0) / bucketDur), 0), n - 1)
                words[b] += 1
            }

            // Distribute this line's duration across the buckets it spans.
            var lo = Int((s - t0) / bucketDur)
            var hi = Int((e - t0) / bucketDur)
            lo = min(max(lo, 0), n - 1)
            hi = min(max(hi, 0), n - 1)
            for b in lo...hi {
                let bStart = t0 + Double(b) * bucketDur
                let bEnd = bStart + bucketDur
                let covered = min(e, bEnd) - max(s, bStart)
                if covered > 0 {
                    speech[b] += covered
                    overlap[b] += covered * ovBoost
                    speakerSeconds[b][l.speaker, default: 0] += covered
                }
            }
        }

        // Per-bucket raw score: speaking density + speech rate + rapid
        // turn-taking + overlap. Silence is implicit — little speech, low score.
        // Density's weight is deliberately below ½: it saturates the moment
        // anyone talks, so letting it dominate made every speech bucket
        // identical. Rate/turns/overlap carry the variation.
        var raw = [Double](repeating: 0, count: n)
        for b in 0..<n {
            let density = min(1.0, speech[b] / bucketDur)             // 0 = silent
            let rate = min(1.0, (words[b] / bucketDur) / 3.5)         // ~3.5 wps = full
            let turnNorm = min(1.0, turns[b] / 2.0)                   // 2+ hand-offs = full
            let ov = bucketDur > 0 ? min(1.0, overlap[b] / bucketDur) : 0
            raw[b] = 0.40 * density + 0.25 * rate + 0.22 * turnNorm + 0.13 * ov
        }

        // Normalize by the busiest bucket, then lift the midtones (γ 0.75):
        // an ordinary talking bucket should read as a mid column, not as
        // either a floor dot or a full spike. Preserves 0→0, peak→1, order.
        let values: [Double]
        let peak = raw.max() ?? 0
        if peak > 0 {
            values = raw.map { pow(min(1.0, max(0.0, $0 / peak)), 0.75) }
        } else {
            values = raw   // all-silent → all zeros
        }

        let mix: [[(speaker: Int, share: Double)]] = speakerSeconds.map { dict in
            let top = dict.sorted { $0.value > $1.value }.prefix(2)
            let total = top.reduce(0) { $0 + $1.value }
            guard total > 0 else { return [] as [(speaker: Int, share: Double)] }
            return top.map { (speaker: $0.key, share: $0.value / total) }
        }
        return Snapshot(values: values, speakerMix: mix, spanStart: t0, spanEnd: t1)
    }

    /// Per-bucket speaker mix for the dot-color dithering: who spoke in each
    /// time bin, as (speaker, share) pairs. Same span/bucket math as compute()
    /// so column i of the energy sparkline and mix[i] describe the SAME slice
    /// of the meeting. Trimmed to the top-2 speakers per bucket (a 3rd color in
    /// a ~10-dot column is noise) and renormalized to sum 1; a silent bucket
    /// yields [].
    static func speakerShares(lines: [Line], buckets: Int = 30,
                              spanEnd: Double? = nil) -> [[(speaker: Int, share: Double)]] {
        snapshot(lines: lines, buckets: buckets, spanEnd: spanEnd).speakerMix
    }
}
