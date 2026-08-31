// RecapCardView.swift — a shareable post-meeting one-pager. Renders the on-device
// summary as a single fixed-width card: derived title + date, TL;DR, 템플릿 섹션
// (요점/용어/문답), 결정 목록, 담당자별 액션, 화자별 발화시간(막대), 그리고 한 줄
// 인용. "복사"는 Markdown 한 페이지를 NSPasteboard로, "내보내기…"는 같은
// Markdown을 파일로 저장한다.
//
// 파싱/집계 로직은 Transcript/RecapData.swift (SovereignCore, 단위테스트 대상)로
// 추출됐고, 섹션 의미는 SummarySection 레지스트리(SummaryTemplate.swift)에서
// 읽는다 — 태그 규칙이 슬라이드 덱·오픈 루프와 한 곳에서 관리된다.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet-style one-pager. Width fixed (~520) for a consistent shareable layout.
struct RecapCardView: View {
    @Bindable var session: SessionController
    var onClose: () -> Void

    @State private var copied = false
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    private var data: RecapData {
        let title = session.fileName.isEmpty
            ? uiLang("회의 요약", "Meeting summary")
            : (session.fileName as NSString).deletingPathExtension
        return RecapData.make(lines: session.transcript.lines,
                              names: session.speakerNames,
                              summary: session.meetingSummary,
                              title: title,
                              date: Date())
    }

    var body: some View {
        let d = data
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Colors.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.panelGap) {
                    titleBlock(d)
                    if !d.tldr.isEmpty { section("TL;DR", d.tldr) }
                    // 템플릿 전용 섹션 (핵심 요점/용어·개념/문답) — 회의 요약에선 빈 배열.
                    ForEach(d.extras) { e in section(e.title, e.items) }
                    if !d.decisions.isEmpty { section(uiLang("결정", "Decisions"), d.decisions, accent: true) }
                    if !d.actions.isEmpty { actionBlock(d.actions) }
                    if !d.talk.isEmpty { talkBlock(d) }
                    if let q = d.quote, !q.isEmpty { quoteBlock(q) }
                    if d.tldr.isEmpty && d.decisions.isEmpty && d.actions.isEmpty && d.extras.isEmpty {
                        emptyHint
                    }
                }
                .padding(Theme.Space.window)
            }
            Divider().overlay(Theme.Colors.separator)
            footer(d)
        }
        .frame(width: 520, height: 560)
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: Theme.Space.chipGap) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .foregroundStyle(Theme.Colors.accent)
            Text(uiLang("리캡 카드", "Recap card")).font(Theme.Fonts.appTitle)
            Text(uiLang("온디바이스", "On-device")).font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
            Button(uiLang("닫기", "Close")) { onClose() }
        }
        .padding(Theme.Space.window)
    }

    private func footer(_ d: RecapData) -> some View {
        HStack(spacing: Theme.Space.chipGap) {
            Button { copy(d.markdown) } label: {
                Label(copied ? uiLang("복사됨", "Copied") : uiLang("복사", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button {
                export(d.markdown, suggested: uiLang("\(d.title) 리캡", "\(d.title) recap"))
            } label: {
                Label(uiLang("내보내기…", "Export…"), systemImage: "square.and.arrow.up")
            }
            Spacer()
            Text(uiLang("이 카드는 이 Mac을 떠나지 않습니다.", "This card never leaves this Mac."))
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
        }
        .font(Theme.Fonts.status)
        .padding(Theme.Space.window)
    }

    // MARK: blocks

    private func titleBlock(_ d: RecapData) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
            Text(d.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(d.dateText)
                .font(Theme.Fonts.display)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func section(_ heading: String, _ items: [String], accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            Text(heading).font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: Theme.Space.chipGap) {
                        Circle()
                            .fill(accent ? Theme.Colors.accent : Theme.Colors.textTertiary)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(item).font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionBlock(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            Text(uiLang("액션", "Actions")).font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: Theme.Space.chipGap) {
                        Image(systemName: "square")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .padding(.top, 2)
                        Text(item).font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func talkBlock(_ d: RecapData) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            Text(uiLang("발화 시간", "Talk time")).font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
                ForEach(d.talk) { t in
                    let frac = d.totalTalk > 0 ? max(0.02, t.seconds / d.totalTalk) : 0
                    HStack(spacing: Theme.Space.chipGap) {
                        Text(t.name)
                            .font(Theme.Fonts.speaker)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .frame(width: 88, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: Theme.Radius.meter)
                                    .fill(Theme.Colors.meterTrack)
                                RoundedRectangle(cornerRadius: Theme.Radius.meter)
                                    .fill(Theme.Colors.speaker(t.speaker))
                                    .frame(width: geo.size.width * frac)
                            }
                        }
                        .frame(height: 10)
                        Text(RecapData.clock(t.seconds))
                            .font(Theme.Fonts.timestamp)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func quoteBlock(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.chipGap) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Colors.accent)
                .frame(width: 3)
            Text("\u{201C}\(quote)\u{201D}")
                .font(.system(size: 15, weight: .regular).italic())
                .foregroundStyle(Theme.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.cardPad)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colors.accent.opacity(0.06))
        )
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            Text(uiLang("요약이 아직 없습니다.", "No summary yet."))
                .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
            Text(uiLang("회의 요약을 먼저 생성하면 TL;DR·결정·액션이 채워집니다. 발화 시간과 인용은 전사만으로도 표시됩니다.",
                        "Generate a meeting summary first and TL;DR, decisions, and actions fill in. Talk time and the quote show from the transcript alone."))
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: actions

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private func export(_ s: String, suggested: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "\(suggested).md"
        panel.directoryURL = session.autoSaveFolder
        if panel.runModal() == .OK, let url = panel.url {
            try? s.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
