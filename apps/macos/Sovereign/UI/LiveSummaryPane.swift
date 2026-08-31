// LiveSummaryPane.swift — the right-side 요약 tab during a live recording
// (docs/BACKLOG.md 2026-08-11: AI-요약 기능은 우측 패널 탭으로 합류, 라이브 중엔
// 실시간 가치가 있는 탭만 노출). Sits where WorkspaceExplorer sits post-session
// and borrows its visual language — single visible mode ⇒ plain header, no lone
// pill (the explorer's own rule). Content is SessionController.liveSummaryText:
// the rolling on-device bullet summary the lowest broker lane refreshes ~every
// 30 s without touching live captions.

import SwiftUI

struct LiveSummaryPane: View {
    @Bindable var session: SessionController
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(uiLang("실시간 요약", "Live summary"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                if session.liveSummaryBusy {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 21)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Theme.Colors.accent)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(item)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16)
            }

            Spacer(minLength: 0)
            // TimelineView re-evaluates the footer every minute — without it the
            // label froze on "방금 갱신" exactly when the summary went stale.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 4) {
                    Text(uiLang("온디바이스", "On-device"))
                    if let at = session.liveSummaryUpdatedAt {
                        Text("· \(Self.age(at, uiLang, now: context.date))")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
        }
        // Same fixed width + raised-card shell as the WorkspaceExplorer whose
        // slot this pane borrows (its "explorerWidth" pref is a dead remnant —
        // the explorer body is hard 267).
        .frame(width: 267)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Theme.Colors.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Theme.Colors.surfaceSunken, lineWidth: 1))
                .shadow(color: .black.opacity(0.03), radius: 9, x: 4, y: 4)
        )
    }

    private var bullets: [String] {
        LiveSummary.bullets(session.liveSummaryText ?? "")
    }

    /// "방금 갱신" / "N분 전 갱신" — minute-coarse; the enclosing TimelineView
    /// re-evaluates it every 60 s so it can't freeze on "방금".
    static func age(_ date: Date, _ lang: UILanguage, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return lang("방금 갱신", "just updated") }
        return lang("\(s / 60)분 전 갱신", "updated \(s / 60)m ago", "\(s / 60)分前に更新")
    }
}
