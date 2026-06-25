// LiveCoachView.swift — the live "coach / teleprompter" panel for the sidePanel.
// While a meeting records, it shows the host — at a glance — what agenda items have
// been covered vs are still outstanding, which open questions are still unanswered,
// and whether the room's momentum is heating up or going quiet (지금 흐름).
//
// Pure presentation of a LiveCoachState (computed model-free by LiveCoach, fed from
// SessionController). Mirrors LiveActionRailView's compact card style and reuses the
// EnergyArc sparkline rendering. Gated by the host's liveCoachEnabled toggle in the
// sidePanel; appears only while recording.

import SwiftUI

struct LiveCoachView: View {
    let state: LiveCoachState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if state.isEmpty {
                Text("준비된 안건이 없습니다 — 캘린더 일정이 잡히면 지난 결정·액션을 안건으로 띄웁니다.")
                    .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if state.totalCount > 0 { agendaSection }
                if !state.questions.isEmpty { questionsSection }
            }

            if !state.energy.isEmpty { paceSection }
        }
    }

    // MARK: - header (title + 다룸 progress)

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist").font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.accent)
            Text("라이브 코치").font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            if state.totalCount > 0 {
                Text("\(state.coveredCount) / \(state.totalCount) 다룸")
                    .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
            }
        }
    }

    // MARK: - agenda checklist

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(state.covered) { row($0, covered: true) }
            ForEach(state.remaining) { row($0, covered: false) }
        }
    }

    private func row(_ item: CoachAgendaItem, covered: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: covered ? "checkmark.circle.fill" : "circle")
                .font(Theme.Fonts.status)
                .foregroundStyle(covered ? Theme.Colors.meterFill : Theme.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(covered ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                    .strikethrough(covered, color: Theme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(item.origin.rawValue) · \(item.speaker)")
                    .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - unanswered questions

    private var questionsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble").font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.overlapMarker)
                Text("미답변 질문").font(Theme.Fonts.section)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                if state.unansweredCount > 0 {
                    Text("\(state.unansweredCount)건")
                        .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.overlapMarker)
                }
            }
            ForEach(state.questions) { q in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: q.answered ? "checkmark.circle.fill" : "circle.dotted")
                        .font(Theme.Fonts.status)
                        .foregroundStyle(q.answered ? Theme.Colors.meterFill : Theme.Colors.overlapMarker)
                    Text(q.text)
                        .font(Theme.Fonts.status)
                        .foregroundStyle(q.answered ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                        .strikethrough(q.answered, color: Theme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - pace (sparkline + 지금 흐름 cue)

    private var paceSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("지금 흐름").font(Theme.Fonts.section)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text(state.pace.rawValue)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(paceTint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(paceTint.opacity(0.14)))
            }
            Canvas { ctx, size in
                guard !state.energy.isEmpty else { return }
                let count = state.energy.count
                let gap: CGFloat = count > 40 ? 1 : 2
                let totalGap = gap * CGFloat(count - 1)
                let barW = max(1, (size.width - totalGap) / CGFloat(count))
                let minH: CGFloat = 1.5
                for (i, v) in state.energy.enumerated() {
                    let clamped = max(0, min(1, v))
                    let h = max(minH, CGFloat(clamped) * size.height)
                    let x = CGFloat(i) * (barW + gap)
                    let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                    let bar = Path(roundedRect: rect, cornerRadius: min(barW / 2, 1.5))
                    let alpha = 0.30 + 0.70 * Double(clamped)
                    ctx.fill(bar, with: .color(paceTint.opacity(alpha)))
                }
            }
            .frame(height: 26)
            .help("회의 흐름 — 최근 발언 속도·겹침·침묵으로 추정한 분위기")
        }
    }

    private var paceTint: Color {
        switch state.pace {
        case .heating: return Theme.Colors.recording
        case .steady:  return Theme.Colors.accent
        case .low:     return Theme.Colors.textTertiary
        case .unknown: return Theme.Colors.textTertiary
        }
    }
}
