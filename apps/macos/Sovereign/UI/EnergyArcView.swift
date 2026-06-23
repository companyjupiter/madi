// EnergyArcView.swift — compact sparkline of meeting "energy" for the sidePanel.
//
// Renders the [Double] (0...1) from EnergyArc.compute as a row of slim vertical
// bars. Low values draw as a faint accent track, peaks fill solid accent — so a
// glance shows where the meeting heated up (fast talk / overlap) vs went quiet.

import SwiftUI

struct EnergyArcView: View {
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("에너지 흐름")
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)

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
            .frame(height: 32)
            .help("회의 에너지 흐름 — 발언 속도·겹침·침묵")
        }
    }
}
