// LiveSummaryPane.swift — the right-side 요약 tab during a live recording
// (docs/BACKLOG.md 2026-08-11: AI-요약 기능은 우측 패널 탭으로 합류, 라이브 중엔
// 실시간 가치가 있는 탭만 노출). Sits where WorkspaceExplorer sits post-session
// and borrows its visual language — single visible mode ⇒ plain header, no lone
// pill (the explorer's own rule). Content is SessionController.liveNotes: one
// on-device note per ~minute of speech, appended (never rewritten) by the lowest
// broker lane, grouped into 5-minute sections for reading.

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

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections, id: \.index) { section in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(Self.range(section, uiLang))
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                ForEach(Array(section.notes.enumerated()), id: \.offset) { _, note in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle()
                                            .fill(Theme.Colors.accent)
                                            .frame(width: 5, height: 5)
                                            .padding(.top, 6)
                                        Text(note.text)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.Colors.textPrimary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 20).padding(.top, 16)
                }
                // Follow the newest note, the way the transcript follows the newest line.
                .onChange(of: session.liveNotes.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
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

    private var sections: [LiveSummary.Section] { LiveSummary.sections(session.liveNotes) }

    private static let bottom = "live-notes-bottom"

    /// "0–5분" / "0–5 min" / "0–5分" — the section's session-time span.
    static func range(_ section: LiveSummary.Section, _ lang: UILanguage) -> String {
        let a = Int(section.startSeconds / 60), b = a + Int(LiveSummary.sectionSeconds / 60)
        return lang("\(a)–\(b)분", "\(a)–\(b) min", "\(a)–\(b)分")
    }

    /// "방금 갱신" / "N분 전 갱신" — minute-coarse; the enclosing TimelineView
    /// re-evaluates it every 60 s so it can't freeze on "방금".
    static func age(_ date: Date, _ lang: UILanguage, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return lang("방금 갱신", "just updated") }
        return lang("\(s / 60)분 전 갱신", "updated \(s / 60)m ago", "\(s / 60)分前に更新")
    }
}
