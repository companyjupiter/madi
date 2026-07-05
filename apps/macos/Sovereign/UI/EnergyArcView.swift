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
                let cols = historyW >= colPitch * 2
                    ? stretched(resampled(to: max(2, Int(historyW / colPitch))))
                    : []

                if cols.count > 1 {
                    let step = historyW / CGFloat(cols.count)
                    let peak = cols.indices.max(by: { cols[$0] < cols[$1] }) ?? 0
                    for (i, v) in cols.enumerated() {
                        let rows = max(1, Int((CGFloat(max(0, min(1, v))) * size.height) / rowPitch))
                        let x = CGFloat(i) * step + step / 2 - dotDiameter / 2
                        // Peak neighborhood glows accent; everything else stays quiet gray.
                        let hot = abs(i - peak) <= 2 && cols[i] > 0.55
                        for r in 0..<min(rows, maxRows) {
                            let y = size.height - CGFloat(r) * rowPitch - dotDiameter
                            let dot = Path(ellipseIn: CGRect(x: x, y: y, width: dotDiameter, height: dotDiameter))
                            if hot {
                                // Vertical gradient: strongest at the column's top dot.
                                let t = rows > 1 ? Double(r) / Double(rows - 1) : 1
                                ctx.fill(dot, with: .color(Theme.Colors.accent.opacity(0.30 + 0.70 * t)))
                            } else {
                                ctx.fill(dot, with: .color(Color.black.opacity(0.12)))
                            }
                        }
                    }
                }

                // Live edge: two accent columns pinned to the right that rise and
                // fall with the mic RMS in real time. sqrt boost keeps quiet
                // speech visible; a 1-dot floor means "recording" always shows a
                // pulse even in silence.
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
                            ctx.fill(dot, with: .color(Theme.Colors.accent.opacity(0.35 + 0.65 * t)))
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

    /// Stretch to this meeting's own min→max so the (now turn-taking-aware, so
    /// genuinely varying) signal uses the full height. Keeps a 0.12 floor so a
    /// quiet stretch still shows a dot or two; a truly flat meeting is left calm.
    private func stretched(_ cols: [Double]) -> [Double] {
        guard let lo = cols.min(), let hi = cols.max(), hi - lo > 0.05 else {
            return cols.map { min(1.0, max(0.12, $0)) }
        }
        return cols.map { 0.12 + 0.88 * (($0 - lo) / (hi - lo)) }
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
