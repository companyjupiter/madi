// OpenLoopsView.swift — the "열린 항목" view that swaps in for the file tree in
// the workspace explorer (third tab, alongside 파일 / 사람). Surfaces every open
// loop — 결정 / 액션 / 질문 — pulled from past meetings' summaries by
// SessionController.openLoopsAnalytics() → OpenLoopsAggregator. Each row shows a
// kind badge, the owner (action items), the loop text, its source meeting + age
// ("12일째 후속 없음"), and a follow-up note when a later meeting re-mentioned it.
//
// Two groups: 후속 필요 (unresolved, oldest first) and 후속됨 (resolved). Tapping
// a row re-opens the source meeting via session.openArchived. Pure presentation
// over the [OpenLoopItem] the aggregator produces; the toggle that shows it lives
// in the WorkspaceExplorer header (lead-applied segmented Picker), like 사람.

import SwiftUI
import AppKit

struct OpenLoopsView: View {
    @Bindable var session: SessionController

    // Computed on demand (like the people tab) — recomputed when the view appears
    // / the workspace changes, not held as @Observable state.
    @State private var loops: [OpenLoopItem] = []

    private var unresolved: [OpenLoopItem] { loops.filter { !$0.isResolved } }
    private var resolved: [OpenLoopItem] { loops.filter { $0.isResolved } }

    var body: some View {
        Group {
            if loops.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
                        if !unresolved.isEmpty {
                            sectionHeader("후속 필요", count: unresolved.count)
                            ForEach(unresolved) { row($0) }
                        }
                        if !resolved.isEmpty {
                            sectionHeader("후속됨", count: resolved.count)
                            ForEach(resolved) { row($0) }
                        }
                    }
                    .padding(12)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { reload() }
        // Re-aggregate when the workspace root changes (folder switch / reload).
        .onChange(of: session.workspace.root) { _, _ in reload() }
    }

    private func reload() { loops = session.openLoopsAnalytics() }

    // MARK: section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("\(count)")
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    // MARK: a loop row

    private func row(_ item: OpenLoopItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                badge(item.kind)
                if let owner = item.owner, !owner.isEmpty {
                    Text(owner)
                        .font(Theme.Fonts.speaker)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(ageText(item))
                    .font(Theme.Fonts.status)
                    .foregroundStyle(item.isResolved ? Theme.Colors.textTertiary : Theme.Colors.lowConf)
                    .lineLimit(1)
            }
            Text(item.text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(item.meetingName)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if let follow = followText(item) {
                    Text("·").foregroundStyle(Theme.Colors.textTertiary)
                    Text(follow)
                        .font(Theme.Fonts.status)
                        .foregroundStyle(Theme.Colors.accent)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Space.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colors.surfaceSunken)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { openMeeting(item) }
        .contextMenu {
            Button("회의록 열기") { openMeeting(item) }
        }
        .help(item.meetingName)
    }

    /// Kind badge — [결정] / [액션] / [질문] in a tinted pill.
    private func badge(_ kind: OpenLoopItem.Kind) -> some View {
        Text(kind.rawValue)
            .font(Theme.Fonts.section)
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color(for: kind)))
    }

    private func color(for kind: OpenLoopItem.Kind) -> Color {
        switch kind {
        case .decision: return Theme.Colors.meterFill     // 결정 — settled green
        case .action:   return Theme.Colors.accent        // 액션 — actionable accent
        case .question: return Theme.Colors.overlapMarker // 질문 — open amber
        }
    }

    /// "12일째 후속 없음" (unresolved) / "12일 경과" (resolved — age still shown).
    private func ageText(_ item: OpenLoopItem) -> String {
        let d = item.ageDays()
        return item.isResolved ? "\(d)일 경과" : "\(d)일째 후속 없음"
    }

    /// "5일 후 회의2에서 언급됨" when a later meeting re-mentioned it.
    private func followText(_ item: OpenLoopItem) -> String? {
        guard item.isResolved, let m = item.followedUpInMeeting else { return nil }
        if let n = item.followUpAfterDays { return "\(n)일 후 \(m)에서 언급됨" }
        return "\(m)에서 언급됨"
    }

    private func openMeeting(_ item: OpenLoopItem) {
        guard let url = transcriptURL(named: item.meetingName) else { return }
        session.openArchived(url)
    }

    /// Resolve a meeting name back to its .md URL by walking the explorer tree
    /// (loop items carry the basename; openArchived needs the URL).
    private func transcriptURL(named name: String) -> URL? {
        func find(_ nodes: [FileNode]) -> URL? {
            for n in nodes {
                if let kids = n.children, let hit = find(kids) { return hit }
                if n.isTranscript, n.url.deletingPathExtension().lastPathComponent == name { return n.url }
            }
            return nil
        }
        return find(session.workspace.nodes)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("열린 항목이 없습니다")
                .font(Theme.Fonts.display)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("회의 요약에 [결정]·[액션]·[질문]이 기록되면\n여기에서 회의별 후속 현황을 추적합니다.")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
