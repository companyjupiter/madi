// LiveActionRailView.swift — the side rail that fills in real time while a meeting
// records: decisions / action items (with owner) / open questions the on-device
// LLM extracts from the running transcript. So the meeting is "already organized"
// by the time it ends. Gated to ≥16 GB machines (see SessionController.liveRailCapable).

import SwiftUI

struct LiveActionRailView: View {
    let items: [RailItem]
    var extracting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.accent)
                Text("라이브 인텔리전스").font(Theme.Fonts.section)
                    .foregroundStyle(Theme.Colors.textSecondary)
                if extracting {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                }
                Spacer()
            }
            if items.isEmpty {
                Text("결정·할 일·질문을 실시간 추출합니다…")
                    .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
            } else {
                ForEach(items) { card($0) }
            }
        }
    }

    private func card(_ item: RailItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(item.kind.rawValue)
                .font(Theme.Fonts.status)
                .foregroundStyle(tint(item.kind))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(tint(item.kind).opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                if let owner = item.owner, !owner.isEmpty {
                    Text(owner).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textPrimary)
                }
                Text(item.text).font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func tint(_ kind: RailItem.Kind) -> Color {
        switch kind {
        case .decision: return Theme.Colors.accent
        case .action:   return Theme.Colors.recording
        case .question: return Theme.Colors.textTertiary
        }
    }
}
