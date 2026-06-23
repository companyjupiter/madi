// PrepBriefView.swift — the Meeting Prep Brief sheet, shown BEFORE recording when a
// calendar event is detected. Renders the upcoming meeting's attendees alongside the
// prior decisions and still-open action items the host should walk in knowing, all
// drawn on-device from the workspace's archived transcripts (MeetingPrepBrief →
// PrepBriefData). Sheet styling mirrors RecapCardView (fixed-width shareable card,
// 복사 / 내보내기… footer) so the two pre/post-meeting one-pagers feel consistent.
//
// Sections: 회의 참석자 / 지난 결정 / 미해결 액션 / 관련 논의. The header carries a
// muted "녹음 준비 중…" line and a close button. An optional "워크스페이스에서 더
//찾기" toggle runs an LLM-grounded ask() over the attendee + title keywords — OFF by
// default because loading the summary model evicts the translate engine (one model
// at a time); the answer surfaces under 관련 논의.
//
// The view binds to SessionController.prepBriefData / loadingPrepBrief (set by the
// integrator) and calls back through `onClose` + `onSearchWorkspace` so it stays
// decoupled from session internals. Korean UI, two font weights, Theme tokens only.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PrepBriefView: View {
    @Bindable var session: SessionController
    /// Dismiss the brief (caller marks it dismissed-for-session so it won't re-pop).
    var onClose: () -> Void
    /// Run the optional LLM-grounded workspace context search. Caller loads the
    /// summary engine, asks `MeetingPrepBrief.contextQuery(...)`, and surfaces the
    /// answer via session.qaAnswer. Nil hides the toggle (engine unavailable).
    var onSearchWorkspace: (() -> Void)? = nil

    @State private var copied = false
    @State private var searchEnabled = false

    private var data: PrepBriefData {
        session.prepBriefData ?? .empty(title: session.meetingTitle ?? "회의")
    }

    var body: some View {
        let d = data
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Colors.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.panelGap) {
                    titleBlock(d)
                    if session.loadingPrepBrief && d.isEmpty {
                        loadingHint
                    } else if d.isEmpty {
                        emptyHint
                    } else {
                        if !d.attendees.isEmpty { attendeeBlock(d.attendees) }
                        if !d.decisions.isEmpty { itemBlock("지난 결정", d.decisions, accent: true, checkbox: false) }
                        if !d.openItems.isEmpty { itemBlock("미해결 액션", d.openItems, accent: false, checkbox: true) }
                        if d.decisions.isEmpty && d.openItems.isEmpty { noItemsHint }
                        relatedBlock(d)
                    }
                }
                .padding(Theme.Space.window)
            }
            Divider().overlay(Theme.Colors.separator)
            footer(d)
        }
        .frame(width: 520, height: 580)
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: Theme.Space.chipGap) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Theme.Colors.accent)
            Text("회의 준비 브리핑").font(Theme.Fonts.appTitle)
            Text("녹음 준비 중…").font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
            Button("닫기") { onClose() }
        }
        .padding(Theme.Space.window)
    }

    private func footer(_ d: PrepBriefData) -> some View {
        HStack(spacing: Theme.Space.chipGap) {
            Button { copy(d.markdown()) } label: {
                Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button {
                export(d.markdown(), suggested: "\(d.meetingTitle) 준비 브리핑")
            } label: {
                Label("내보내기…", systemImage: "square.and.arrow.up")
            }
            Spacer()
            Text("이 브리핑은 이 Mac을 떠나지 않습니다.")
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
        }
        .font(Theme.Fonts.status)
        .padding(Theme.Space.window)
    }

    // MARK: blocks

    private func titleBlock(_ d: PrepBriefData) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
            Text(d.meetingTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
            if !d.relatedTalks.isEmpty {
                Text("지난 회의 \(d.relatedTalks.count)개에서 정리한 맥락입니다")
                    .font(Theme.Fonts.display)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private func attendeeBlock(_ attendees: [PrepAttendee]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            Text("회의 참석자").font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
                ForEach(attendees) { a in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.chipGap) {
                        Circle()
                            .fill(Theme.Colors.accent)
                            .frame(width: 5, height: 5)
                        Text(a.role.map { "\(a.name) \($0)" } ?? a.name)
                            .font(Theme.Fonts.speaker)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .textSelection(.enabled)
                        Spacer(minLength: Theme.Space.chipGap)
                        Text(a.pastMeetings > 0 ? "지난 회의 \(a.pastMeetings)회" : "이력 없음")
                            .font(Theme.Fonts.status)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemBlock(_ heading: String, _ items: [PrepItem], accent: Bool, checkbox: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            Text(heading).font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
                ForEach(items) { it in
                    HStack(alignment: .top, spacing: Theme.Space.chipGap) {
                        if checkbox {
                            Image(systemName: "square")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .padding(.top, 2)
                        } else {
                            Circle()
                                .fill(Theme.Colors.accent)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.text)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(it.speaker) · \(it.meeting)")
                                .font(Theme.Fonts.status)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relatedBlock(_ d: PrepBriefData) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            HStack {
                Text("관련 논의").font(Theme.Fonts.section)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                if onSearchWorkspace != nil {
                    Toggle("워크스페이스에서 더 찾기", isOn: $searchEnabled)
                        .toggleStyle(.switch)
                        .font(Theme.Fonts.status)
                        .onChange(of: searchEnabled) { _, on in
                            if on { onSearchWorkspace?() }
                        }
                }
            }
            if !d.relatedTalks.isEmpty {
                ForEach(d.relatedTalks, id: \.self) { m in
                    HStack(spacing: Theme.Space.chipGap) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text(m).font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
            if searchEnabled {
                if session.qaAsking {
                    HStack(spacing: Theme.Space.chipGap) {
                        ProgressView().controlSize(.small)
                        Text("워크스페이스 검색 중…").font(Theme.Fonts.status)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                } else if let answer = session.qaAnswer, !answer.isEmpty {
                    Text(answer)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .padding(Theme.Space.cardPad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.card)
                                .fill(Theme.Colors.accent.opacity(0.06))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: hints

    private var loadingHint: some View {
        HStack(spacing: Theme.Space.chipGap) {
            ProgressView().controlSize(.small)
            Text("워크스페이스에서 지난 맥락을 정리하는 중…")
                .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
            Text("지난 맥락이 없습니다.")
                .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
            Text("워크스페이스에 이 참석자들의 지난 회의록이 쌓이면, 지난 결정과 미해결 액션이 여기에 표시됩니다. 지금 바로 녹음을 시작해도 됩니다.")
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noItemsHint: some View {
        Text("지난 결정이나 미해결 액션을 찾지 못했습니다.")
            .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
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
