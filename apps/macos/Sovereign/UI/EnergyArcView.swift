// EnergyArcView.swift — meeting "energy" dot-matrix graph for the left session
// panel (Figma 195:1024 reference image: columns of small dots rising with the
// energy level, quiet gray everywhere except the meeting's hottest region,
// which lights up in a vertical accent gradient).
//
// Values come from EnergyArc.compute (0…1 per time bucket). Tapping anywhere
// seeks the transcript to that moment (same onSeek contract as before).

import SwiftUI

struct EnergyArcView: View {
    let values: [Double]
    let lines: [Line]
    /// Live "now" (same clock as line offsets) while recording — keeps the time
    /// axis and tap-to-seek aligned with the growing span EnergyArc bucketed.
    var liveEnd: Double? = nil
    /// Real-time mic RMS (0…1) while recording — drives the accent "live edge"
    /// columns on the right so the graph visibly breathes with the room, giving
    /// at-a-glance proof that audio is coming in. nil when not recording.
    var liveLevel: Float? = nil
    var onSeek: (UUID) -> Void

    private let dotDiameter: CGFloat = 2.6
    private let rowPitch: CGFloat = 5.5
    private let colPitch: CGFloat = 5.5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("에너지 흐름")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textSecondary)

            // While recording, the chart shows even before any line commits —
            // the live edge alone is the "mic is alive" signal.
            if values.count > 1 || liveLevel != nil {
                chart
                    .frame(height: 64)
                    .help("회의 에너지 흐름 — 발언 속도·겹침·침묵. 클릭하면 그 구간으로 이동합니다.")
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(totalLabel)
                }
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                Text("발언이 쌓이면 흐름이 표시됩니다")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
        }
    }

    private var chart: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let maxRows = max(1, Int(size.height / rowPitch))
                // Recording: reserve the right edge for 2 live columns (+1 col gap)
                // that breathe with the current mic level.
                let liveCols = liveLevel != nil ? 2 : 0
                let liveZone = CGFloat(liveCols == 0 ? 0 : liveCols + 1) * colPitch
                let historyW = max(0, size.width - liveZone)
                let colCount = max(2, Int(historyW / colPitch))
                let cols = historyW >= colPitch * 2 ? stretched(resampled(to: colCount)) : []
                let mix = historyW >= colPitch * 2 ? columnMix(colCount) : []

                if cols.count > 1 {
                    let step = historyW / CGFloat(cols.count)
                    for (i, v) in cols.enumerated() {
                        let rows = max(1, Int((CGFloat(max(0, min(1, v))) * size.height) / rowPitch))
                        let x = CGFloat(i) * step + step / 2 - dotDiameter / 2
                        let m = i < mix.count ? mix[i] : []
                        for r in 0..<min(rows, maxRows) {
                            let y = size.height - CGFloat(r) * rowPitch - dotDiameter
                            let dot = Path(ellipseIn: CGRect(x: x, y: y, width: dotDiameter, height: dotDiameter))
                            if m.isEmpty {
                                // Silence — flat quiet gray, no speaker to show.
                                ctx.fill(dot, with: .color(Theme.Colors.textTertiary))
                            } else {
                                // Speaker dithering: every dot keeps a PURE
                                // speaker color; the RATIO of colored dots tracks
                                // each speaker's share, so a 60:40 bucket reads
                                // as roughly 6:4 dots — "느낌적 퍼센트", no muddy
                                // blends, and overlap moments show for free as
                                // two colors interleaving. Golden-ratio stride =
                                // stratified (evenly interleaved, exact-ish
                                // proportions) AND deterministic per (col,row),
                                // so live redraws never shimmer.
                                let u = (Double(r) * 0.6180339887 + Double(i) * 0.3819660113)
                                    .truncatingRemainder(dividingBy: 1)
                                var sp = m[0].speaker
                                var acc = 0.0
                                for entry in m {
                                    acc += entry.share
                                    if u < acc { sp = entry.speaker; break }
                                }
                                // Vertical gradient: strongest at the column top
                                // (same alpha ramp the accent columns used).
                                let t = rows > 1 ? Double(r) / Double(rows - 1) : 1
                                ctx.fill(dot, with: .color(Theme.Colors.speaker(sp).opacity(0.30 + 0.70 * t)))
                            }
                        }
                    }
                }

                // Live edge: two columns pinned to the right that rise and fall
                // with the mic RMS in real time. sqrt boost keeps quiet speech
                // visible; a 1-dot floor means "recording" always shows a pulse
                // even in silence. Quiet GRAY (not accent) — the de-accent pass
                // left the whole graph speaker-colored/neutral, so the live edge
                // reads as "listening" texture, not a colored highlight.
                if let lv = liveLevel {
                    // ~2.6× gain then a soft curve so a normal speaking voice
                    // fills most of the column (raw RMS is small); loud speech
                    // clips at full, which reads fine for a "live" meter.
                    let boosted = pow(Double(max(0, min(1, lv * 2.6))), 0.45)
                    for c in 0..<liveCols {
                        let frac = c == 0 ? boosted : boosted * 0.7
                        let rows = max(1, Int(CGFloat(frac) * size.height / rowPitch))
                        let x = size.width - CGFloat(liveCols - c) * colPitch
                        for r in 0..<min(rows, maxRows) {
                            let y = size.height - CGFloat(r) * rowPitch - dotDiameter
                            let dot = Path(ellipseIn: CGRect(x: x, y: y, width: dotDiameter, height: dotDiameter))
                            let t = rows > 1 ? Double(r) / Double(rows - 1) : 1
                            ctx.fill(dot, with: .color(Theme.Colors.textTertiary.opacity(0.45 + 0.55 * t)))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { seek(at: $0.location.x, width: geo.size.width) }
            )
        }
    }

    /// Perceptual two-segment mapping — NOT a min→max stretch (which rendered
    /// all-or-nothing columns), and NOT a single gamma curve either (which
    /// lifted mids so far that the peak stopped standing out in HEIGHT).
    ///
    ///   · ordinary range (p10…p85): 0.12 → 0.60, γ0.7 — silence stays a floor
    ///     dot, normal speech reads as graded mid columns
    ///   · peak range (p85…max):     0.60 → 1.0 — headroom RESERVED for the
    ///     meeting's genuinely hottest moments, so the peak is taller than
    ///     everything else on its own. Height must carry the peak signal:
    ///     column COLOR is reserved for the upcoming speaker dithering.
    private func stretched(_ cols: [Double]) -> [Double] {
        guard cols.count > 1, let mx = cols.max() else {
            return cols.map { min(1.0, max(0.12, $0)) }
        }
        let sorted = cols.sorted()
        let lo = sorted[Int(Double(sorted.count - 1) * 0.10)]
        let hi = max(sorted[Int(Double(sorted.count - 1) * 0.85)], lo + 0.20)
        let midCeil = 0.60
        return cols.map { v in
            // Flat meeting (no real peak above the busy range) → mid band only.
            if v <= hi || mx - hi < 0.03 {
                let t = max(0, min(1, (v - lo) / (hi - lo)))
                return 0.12 + (midCeil - 0.12) * pow(t, 0.7)
            }
            let t = max(0, min(1, (v - hi) / (mx - hi)))
            return midCeil + (1 - midCeil) * pow(t, 0.9)
        }
    }

    // ── Speaker mix per rendered column (for the dot dithering) ────────────
    /// speakerShares bucketed EXACTLY like `values` (same lines/spanEnd/count),
    /// resampled with the same stride as `resampled(to:)` so column i's height
    /// and colors describe the same slice, then smoothed across neighbors so
    /// speaker transitions drift like a gradient instead of switching hard.
    private func columnMix(_ count: Int) -> [[(speaker: Int, share: Double)]] {
        let raw = EnergyArc.speakerShares(lines: lines, buckets: max(1, values.count),
                                          spanEnd: liveEnd)
        guard raw.count == values.count, !raw.isEmpty else { return [] }
        // Mirror resampled(to:)'s passthrough + stride math.
        var cols: [[Int: Double]]
        if raw.count <= count {
            cols = raw.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.speaker, $0.share) }) }
        } else {
            cols = []
            cols.reserveCapacity(count)
            let stride = Double(raw.count) / Double(count)
            for i in 0..<count {
                let lo = Int(Double(i) * stride)
                let hi = min(raw.count, max(lo + 1, Int(Double(i + 1) * stride)))
                var merged: [Int: Double] = [:]
                for b in lo..<hi { for e in raw[b] { merged[e.speaker, default: 0] += e.share } }
                cols.append(merged)
            }
        }
        // Neighbor blend (¼·½·¼): the reference-image "drift" — a speaker
        // hand-off bleeds a column into its neighbors instead of a hard edge.
        var out: [[(speaker: Int, share: Double)]] = []
        out.reserveCapacity(cols.count)
        for i in cols.indices {
            var blend: [Int: Double] = [:]
            for (j, w) in [(i - 1, 0.25), (i, 0.5), (i + 1, 0.25)] where cols.indices.contains(j) {
                for (sp, sh) in cols[j] { blend[sp, default: 0] += sh * w }
            }
            let top = blend.sorted { $0.value > $1.value }.prefix(2)
            let total = top.reduce(0) { $0 + $1.value }
            out.append(total > 0 ? top.map { (speaker: $0.key, share: $0.value / total) } : [])
        }
        return out
    }

    /// Bucket-average the raw values down to `count` columns so dot spacing
    /// stays constant regardless of meeting length.
    private func resampled(to count: Int) -> [Double] {
        guard values.count > count else { return values }
        var out: [Double] = []
        out.reserveCapacity(count)
        let stride = Double(values.count) / Double(count)
        for i in 0..<count {
            let lo = Int(Double(i) * stride)
            let hi = min(values.count, max(lo + 1, Int(Double(i + 1) * stride)))
            let slice = values[lo..<hi]
            out.append(slice.reduce(0, +) / Double(slice.count))
        }
        return out
    }

    private var spanT1: Double {
        max(lines.map(\.end).max() ?? 0, liveEnd ?? 0)
    }

    private var totalLabel: String {
        let t0 = lines.map(\.start).min() ?? 0
        let secs = Int(max(0, spanT1 - t0))
        if secs >= 3600 {
            return String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // Map a tap's x-fraction back to a timestamp over the lines' span, then
    // jump to whichever line covers (or is nearest to) that moment.
    private func seek(at x: CGFloat, width: CGFloat) {
        guard width > 0, !lines.isEmpty else { return }
        let t0 = lines.map(\.start).min() ?? 0
        let span = spanT1 - t0
        guard span > 0 else { return }
        let frac = max(0, min(1, x / width))
        let t = t0 + Double(frac) * span
        if let hit = lines.first(where: { t >= $0.start && t <= $0.end }) {
            onSeek(hit.id)
        } else if let nearest = lines.min(by: { abs($0.start - t) < abs($1.start - t) }) {
            onSeek(nearest.id)
        }
    }
}
