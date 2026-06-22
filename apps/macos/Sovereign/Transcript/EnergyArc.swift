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
    /// Per-bucket energy in 0...1 over the meeting timespan.
    ///
    /// - Parameters:
    ///   - lines: diarized transcript lines (uses each line's start/end and
    ///            overlapSpeakers; empty/degenerate input → []).
    ///   - buckets: number of time bins to emit (clamped to ≥ 1).
    /// - Returns: `buckets` values in 0...1, or [] when there is no usable span.
    static func compute(lines: [Line], buckets: Int = 30) -> [Double] {
        let n = max(1, buckets)
        guard !lines.isEmpty else { return [] }

        // Meeting span from the earliest onset to the latest offset.
        let t0 = lines.map(\.start).min() ?? 0
        let t1 = lines.map(\.end).max() ?? 0
        let span = t1 - t0
        guard span > 0 else { return [] }

        let bucketDur = span / Double(n)
        guard bucketDur > 0 else { return [] }

        // Raw energy accumulators per bucket.
        var speech = [Double](repeating: 0, count: n)   // seconds of speech in bucket
        var overlap = [Double](repeating: 0, count: n)  // overlap-weighted speech events

        for l in lines {
            let s = max(t0, l.start)
            let e = min(t1, l.end)
            guard e > s else { continue }
            // Overlap weight: each concurrent extra speaker adds a flat boost.
            let ovBoost = Double(l.overlapSpeakers.count)

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
                }
            }
        }

        // Per-bucket raw score: speaking density (0...1) plus overlap pressure.
        // Silence is implicit — a bucket with little speech scores low.
        var raw = [Double](repeating: 0, count: n)
        for b in 0..<n {
            let density = min(1.0, speech[b] / bucketDur)             // 0 = silent
            let ov = bucketDur > 0 ? min(1.0, overlap[b] / bucketDur) : 0
            raw[b] = density + 0.5 * ov
        }

        // Normalize to 0...1 by the busiest bucket so the arc fills the gamut.
        let peak = raw.max() ?? 0
        guard peak > 0 else { return raw }   // all-silent → all zeros
        return raw.map { min(1.0, max(0.0, $0 / peak)) }
    }
}
