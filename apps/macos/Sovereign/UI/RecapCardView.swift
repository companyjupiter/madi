// RecapCardView.swift — a shareable post-meeting one-pager. Renders the on-device
// summary as a single fixed-width card: derived title + date, TL;DR, 결정 목록,
// 담당자별 액션, 화자별 발화시간(막대), 그리고 한 줄 인용. "복사"는 Markdown 한
// 페이지를 NSPasteboard로, "내보내기…"는 같은 Markdown을 파일로 저장한다.
//
// 모든 파싱/집계 로직은 이 파일 안의 RecapData 에 모여 있고 (SessionController 무수정),
// 섹션 분리는 SummaryDeck.parseSections 를 그대로 재사용한다 — [요약]/[액션]/[결정]
// 토큰 규칙이 슬라이드 덱과 한 곳에서 관리된다.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pure value model for the recap card — built from a TranscriptStore + summary
/// text, no SwiftUI/engine dependency, so it's trivially testable in isolation.
struct RecapData {
    struct Talk: Identifiable {
        let speaker: Int
        let name: String
        let seconds: Double
        var id: Int { speaker }
    }

    var title: String
    var dateText: String
    var tldr: [String]          // TL;DR 문장/불릿 (요약 섹션)
    var decisions: [String]     // 결정 사항
    var actions: [String]       // 액션 아이템 (담당자 prefix 포함될 수 있음)
    var talk: [Talk]            // 화자별 발화시간 (내림차순)
    var totalTalk: Double       // 막대 정규화용 최대값(= 최댓값 화자)
    var quote: String?          // 가장 긴 한 줄 인용

    /// Build from the live/archived transcript + the on-device summary text.
    static func make(lines: [Line],
                     names: [Int: String],
                     summary: String?,
                     title: String,
                     date: Date) -> RecapData {
        let df = DateFormatter(); df.dateFormat = "yyyy년 M월 d일 (EEE)"; df.locale = Locale(identifier: "ko_KR")
        let dateText = df.string(from: date)

        // ── sections (reuse the deck's tolerant parser) ──
        var tldr: [String] = [], decisions: [String] = [], actions: [String] = []
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for sec in SummaryDeck.parseSections(summary) {
                let items = sec.bullets + sec.paras
                if sec.title.contains("액션") { actions += items }
                else if sec.title.contains("결정") { decisions += items }
                else { tldr += items }   // 요약/기타
            }
        }

        // ── talk-time per speaker ──
        var secs: [Int: Double] = [:]
        for l in lines {
            let d = max(0, l.end - l.start)
            secs[l.speaker, default: 0] += d
        }
        let talk = secs
            .map { Talk(speaker: $0.key,
                        name: SpeakerID.display($0.key, names: names, fallback: "화자\($0.key)"),
                        seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
        let maxTalk = talk.map(\.seconds).max() ?? 0

        // ── key quote: the longest single line (proxy for a substantive remark) ──
        let quote = lines
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
            .max(by: { $0.count < $1.count })

        return RecapData(title: title.isEmpty ? "회의 요약" : title,
                         dateText: dateText,
                         tldr: tldr, decisions: decisions, actions: actions,
                         talk: talk, totalTalk: maxTalk, quote: quote)
    }

    /// One-page Markdown — what "복사"/"내보내기" emit.
    var markdown: String {
        var s = "# \(title)\n\n_\(dateText)_\n"
        if !tldr.isEmpty {
            s += "\n## TL;DR\n"
            for t in tldr { s += "- \(t)\n" }
        }
        if !decisions.isEmpty {
            s += "\n## 결정\n"
            for d in decisions { s += "- \(d)\n" }
        }
        if !actions.isEmpty {
            s += "\n## 액션\n"
            for a in actions { s += "- [ ] \(a)\n" }
        }
        if !talk.isEmpty {
            s += "\n## 발화 시간\n"
            for t in talk { s += "- \(t.name): \(RecapData.clock(t.seconds))\n" }
        }
        if let quote, !quote.isEmpty {
            s += "\n> \(quote)\n"
        }
        return s
    }

    /// m:ss / h:mm:ss clock for a duration in seconds.
    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

/// Sheet-style one-pager. Width fixed (~520) for a consistent shareable layout.
struct RecapCardView: View {
    @Bindable var session: SessionController
    var onClose: () -> Void

    @State private var copied = false

    private var data: RecapData {
        let title = session.fileName.isEmpty
            ? "회의 요약"
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
                    if !d.decisions.isEmpty { section("결정", d.decisions, accent: true) }
                    if !d.actions.isEmpty { actionBlock(d.actions) }
                    if !d.talk.isEmpty { talkBlock(d) }
                    if let q = d.quote, !q.isEmpty { quoteBlock(q) }
                    if d.tldr.isEmpty && d.decisions.isEmpty && d.actions.isEmpty {
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
            Text("리캡 카드").font(Theme.Fonts.appTitle)
            Text("온디바이스").font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
            Button("닫기") { onClose() }
        }
        .padding(Theme.Space.window)
    }

    private func footer(_ d: RecapData) -> some View {
        HStack(spacing: Theme.Space.chipGap) {
            Button { copy(d.markdown) } label: {
                Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button {
                export(d.markdown, suggested: "\(d.title) 리캡")
            } label: {
                Label("내보내기…", systemImage: "square.and.arrow.up")
            }
            Spacer()
            Text("이 카드는 이 Mac을 떠나지 않습니다.")
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
            Text("액션").font(Theme.Fonts.section)
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
            Text("발화 시간").font(Theme.Fonts.section)
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
            Text("요약이 아직 없습니다.")
                .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
            Text("회의 요약을 먼저 생성하면 TL;DR·결정·액션이 채워집니다. 발화 시간과 인용은 전사만으로도 표시됩니다.")
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
