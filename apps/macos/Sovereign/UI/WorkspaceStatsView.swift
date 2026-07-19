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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        tile("\(stats.meetingCount)", uiLang("회의", "Meetings"))
                        tile(hoursMinutes(stats.totalSeconds), uiLang("총 시간", "Total time"))
                        tile(hoursMinutes(stats.avgSeconds), uiLang("평균 길이", "Avg length"))
                        tile(Self.grouper.string(from: NSNumber(value: stats.totalWords)) ?? "\(stats.totalWords)", uiLang("총 단어", "Total words"))
                    }
                    HStack {
                        Text(uiLang("평균 화자", "Avg speakers")).font(.system(size: 12)).foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        Text(uiLang(String(format: "%.1f명", stats.avgSpeakers), String(format: "%.1f", stats.avgSpeakers)))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                    }
                    trendBlock
                }
                .padding(.horizontal, 20).padding(.top, 16)
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.Colors.surfaceSunken))
    }

    private var trendBlock: some View {
        let maxV = max(1, stats.weeklyTrend.max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(uiLang("최근 \(stats.weeklyTrend.count)주", "Last \(stats.weeklyTrend.count) wks")).font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
                Text(uiLang("이번 주 \(stats.thisWeekCount)", "This week \(stats.thisWeekCount)"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.textSecondary)
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(stats.weeklyTrend.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == stats.weeklyTrend.count - 1 ? Theme.Colors.accent : Theme.Colors.surfaceSunken)
                        .frame(height: max(4, CGFloat(v) / CGFloat(maxV) * 42))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 42, alignment: .bottom)
        }
    }

    /// Seconds → "Nh Mm" / "Nm" (compact for the narrow tile).
    private func hoursMinutes(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? uiLang("\(m / 60)시간 \(m % 60)분", "\(m / 60)h \(m % 60)m") : uiLang("\(m)분", "\(m)m")
    }
}
