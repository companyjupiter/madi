// WorkspaceStatsView.swift — the 통계 tab in the workspace explorer. Renders the
// pure WorkspaceStats rollup (see WorkspaceAnalytics) as compact stat tiles + a
// recent-weeks meeting trend, sized for the narrow (267 pt) right panel. Replaces
// the removed 사람 tab (which was voiceprint-only).

import SwiftUI

struct WorkspaceStatsView: View {
    let stats: WorkspaceStats
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    private static let grouper: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()

    var body: some View {
        if stats.meetingCount == 0 {
            VStack(spacing: 6) {
                Text(uiLang("저장된 회의가 없습니다", "No saved meetings"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(uiLang("회의를 저장하면 활동 통계가 쌓입니다", "Activity stats build up as you save meetings"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        } else {
            // rev.2 (Figma 318:1579): flat value-over-label grid (no sunken tiles),
            // hairline-divided key/value rows, and the trend chart in the same
            // amber→orange gradient as the speaker share bar.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 7),
                                        GridItem(.flexible(), spacing: 7)], spacing: 22) {
                        statItem("\(stats.meetingCount)", uiLang("회의", "Meetings"))
                        statItem(hoursMinutes(stats.totalSeconds), uiLang("총 시간", "Total time"))
                        statItem(hoursMinutes(stats.avgSeconds), uiLang("평균 길이", "Avg length"))
                        statItem(Self.grouper.string(from: NSNumber(value: stats.totalWords)) ?? "\(stats.totalWords)", uiLang("총 단어", "Total words"))
                    }
                    divider
                    HStack {
                        Text(uiLang("평균 화자", "Avg speakers"))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        Text(uiLang(String(format: "%.1f명", stats.avgSpeakers), String(format: "%.1f", stats.avgSpeakers)))
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                    }
                    divider
                    trendBlock
                }
                .padding(.horizontal, 19).padding(.top, 20)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.Colors.surfaceSunken).frame(height: 1)
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 18)).foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trendBlock: some View {
        let maxV = max(1, stats.weeklyTrend.max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(uiLang("최근 \(stats.weeklyTrend.count)주", "Last \(stats.weeklyTrend.count) wks", "直近 \(stats.weeklyTrend.count)週"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text(uiLang("이번주 \(stats.thisWeekCount)", "This week \(stats.thisWeekCount)", "今週 \(stats.thisWeekCount)"))
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(stats.weeklyTrend.enumerated()), id: \.offset) { i, v in
                    // 15pt floor keeps quiet weeks as visible pills (Figma), not slivers.
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == stats.weeklyTrend.count - 1
                              ? AnyShapeStyle(Theme.Colors.speakerGradient(0))
                              : AnyShapeStyle(Theme.Colors.surfaceSunken))
                        .frame(height: max(15, CGFloat(v) / CGFloat(maxV) * 42))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 42, alignment: .bottom)
        }
    }

    /// Seconds → "Nh Mm" / "Nm" (compact for the narrow tile).
    private func hoursMinutes(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? uiLang("\(m / 60)시간 \(m % 60)분", "\(m / 60)h \(m % 60)m", "\(m / 60)時間 \(m % 60)分") : uiLang("\(m)분", "\(m)m", "\(m)分")
    }
}
