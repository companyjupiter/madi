// EnergyArcView.swift — compact sparkline of meeting "energy" for the sidePanel.
//
// Renders the [Double] (0...1) from EnergyArc.compute as a row of slim vertical
// bars. Low values draw as a faint accent track, peaks fill solid accent — so a
// glance shows where the meeting heated up (fast talk / overlap) vs went quiet.
// Tapping a bar seeks the transcript to that point in time (mirrors
// TimelineScrubberView's tap → onSeek(line.id) pattern).

import SwiftUI

struct EnergyArcView: View {
    let values: [Double]
    let lines: [Line]
    var onSeek: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("에너지 흐름")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Colors.textSecondary)

            GeometryReader { geo in
                Canvas { ctx, size in
                    guard !values.isEmpty else { return }
                    let count = values.count
                    let gap: CGFloat = count > 40 ? 1 : 2
                    let totalGap = gap * CGFloat(count - 1)
                    let barW = max(1, (size.width - totalGap) / CGFloat(count))
                    let minH: CGFloat = 1.5

                    for (i, v) in values.enumerated() {
                        let clamped = max(0, min(1, v))
                        let h = max(minH, CGFloat(clamped) * size.height)
                        let x = CGFloat(i) * (barW + gap)
                        let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                        let bar = Path(roundedRect: rect, cornerRadius: min(barW / 2, 1.5))
                        // Taller bars read as more accent; quiet bars stay faint.
                        let alpha = 0.30 + 0.70 * Double(clamped)
                        ctx.fill(bar, with: .color(Theme.Colors.accent.opacity(alpha)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { seek(at: $0.location.x, width: geo.size.width) }
                )
            }
            .frame(height: 32)
            .help("회의 에너지 흐름 — 발언 속도·겹침·침묵. 클릭하면 그 구간으로 이동합니다.")
        }
    }

    // Map a tap's x-fraction back to a timestamp over the lines' span, then
    // jump to whichever line covers (or is nearest to) that moment.
    private func seek(at x: CGFloat, width: CGFloat) {
        guard width > 0, !lines.isEmpty else { return }
        let t0 = lines.map(\.start).min() ?? 0
        let t1 = lines.map(\.end).max() ?? 0
        let span = t1 - t0
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
