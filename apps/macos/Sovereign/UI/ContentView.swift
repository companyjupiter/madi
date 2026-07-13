// ContentView.swift — main window: model gate, transcript (left, fills window),
// and a right control panel (record / language / mic / file drop).

import SwiftUI
import AppKit
import CoreAudio
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader
    @Bindable var betaGate: BetaGate
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false
    // Default to the clean reading view — general users just want the content.
    // The detailed (timecode + confidence + overlap) view is one tap away.
    @AppStorage("transcriptViewMode") private var contentMode = true
    // C18: opt-in two-party chat layout (staff left / patient right). Only
    // meaningful with exactly two speakers — the toggle hides otherwise.
    @AppStorage("transcriptChatLayout") private var chatLayout = false
    // The Unknown bucket is not a conversational party — a 2-speaker chat with a
    // rare 미확인 interjection still counts as two-party.
    private var twoSpeakers: Bool { Set(session.transcript.lines.map { $0.speaker }).subtracting([SpeakerID.unknown]).count == 2 }
    private var viewMode: TranscriptViewMode {
        if chatLayout && twoSpeakers { return .chat }
        return contentMode ? .content : .detailed
    }
    // Transcript text size (pt) — readable default, A−/A+ in the bar. Persisted.
    @AppStorage("transcriptFontSize") private var fontSize = 16.0   // Figma 258:568 body 16px
    // IDE-style workspace explorer (save folder as a file tree) on the right.
    @AppStorage("showWorkspaceExplorer") private var showExplorer = true
    // N2 review navigator (상세 mode): step through low-confidence words.
    @State private var reviewIndex = 0
    // N2 listen-to-review: auto-plays each low-confidence word's audio in sequence.
    @State private var review = ReviewController()
    @State private var scrollTarget: UUID? = nil
    @State private var scrollTick = 0
    @State private var transcriptScrolled = false   // top fade shows only when scrolled
    // Set to start language dropdowns: which panel is open ("input"/"output"),
    // and each trigger pill's frame in the card space for panel anchoring.
    @State private var openLangDropdown: String? = nil
    @State private var langPillFrames: [String: CGRect] = [:]
    private struct LangPillFrameKey: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }
    // Guard rails for destructive exits (X on the file card / back chevron):
    // confirm before wiping unsaved content, and stop-confirm mid-recording.
    @State private var showDiscardConfirm = false
    @State private var showBackDiscardConfirm = false
    @State private var showStopConfirm = false
    @State private var showSummary = false   // on-device meeting summary sheet
    @State private var showPrepBrief = false
    // Per-EVENT dismissal (not per-session): once the user closes the brief for a
    // specific calendar event we don't auto-show it again for that same event, but a
    // genuinely different event (different id) still auto-shows. Avoids the stuck flag
    // that blocked the brief for every later meeting once dismissed.
    @State private var dismissedPrepBriefEventIDs: Set<String> = []
    @State private var summaryBySpeaker = false  // 전체 vs 화자별 breakdown
    @State private var qaInput = ""          // "ask the meeting" question
    @AppStorage("qaScope") private var qaWorkspaceScope = false   // false=이 회의, true=전체 워크스페이스
    @State private var showRecap = false     // shareable one-pager recap card sheet
    @State private var showCommandPalette = false   // ⌘K fuzzy launcher overlay
    @State private var languagePickerOpen = false
    @State private var speakerCountPickerOpen = false
    @State private var meetingModePickerOpen = false
    @State private var languagePickerWidth: CGFloat = 0
    @State private var speakerCountPickerWidth: CGFloat = 0
    @State private var meetingModePickerWidth: CGFloat = 0
    // A file picked on the "Set to start" screen is STAGED here (not transcribed
    // yet) — pressing 파일로 시작하기 consumes it. nil ⇒ live recording is the
    // active CTA; non-nil ⇒ file start is active. (The in-session left-panel drop
    // zone keeps its immediate-transcribe behavior; only the setup screen stages.)
    @State private var stagedFile: URL? = nil
    // Imperative window sizing: the "Set to start" screen is a compact, fixed
    // window; starting expands it into the full working layout. Tracked so we
    // only resize when the mode actually flips (nil = not yet applied).
    @State private var appWindow: NSWindow?
    @State private var windowIsSetup: Bool? = nil
    // Save-complete toast (Figma 195:855): appears when a session finishes and
    // the transcript hit disk; auto-dismisses, or 새 기록 시작 jumps back to
    // the Set to start screen.
    @State private var showSaveToast = false
    @State private var saveToastTask: Task<Void, Never>? = nil

    /// Low-confidence word occurrences, in transcript order, for the review queue.
    private var flaggedWords: [(line: UUID, text: String)] {
        var out: [(UUID, String)] = []
        for l in session.transcript.lines {
            for w in l.words where w.conf < Theme.confThreshold {
                let t = w.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append((l.id, t)) }
            }
        }
        return out
    }

    var body: some View {
        Group {
            if betaGate.isExpired {
                // Hard beta expiry: replace the whole session UI (same gating role
                // as the model gate). The app genuinely stops working here.
                ExpiredGateView()
            } else {
                switch downloader.state {
                case .ready:
                    ZStack {
                        if showSetToStart {
                            setToStartCard
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
                        } else {
                            VStack(spacing: 0) {
                                if case .expiringSoon(let d) = betaGate.status {
                                    BetaWarningBanner(daysLeft: d) {
                                        openWindow(id: SovereignApp.updateWindowID)
                                    }
                                }
                                mainLayout
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.snappy(duration: 0.32), value: showSetToStart)
                default: ModelGateView(downloader: downloader)
                }
            }
        }
        .background(WindowAccessor { w in
            if appWindow !== w { appWindow = w }
            // Clean unified titlebar: no title text, no divider — the traffic
            // lights float over the content and the in-content wordmark is the
            // only branding. (Was .titleBar with a visible title in the working
            // layout, which drew an old-looking name + separator line.)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            // Kill the automatic hairline macOS draws under the titlebar when
            // content scrolls (the intermittent "bottom border" below the header).
            w.titlebarSeparatorStyle = .none
            syncWindowMode()
        })
        .onChange(of: showSetToStart) { _, _ in syncWindowMode() }
        .onChange(of: session.phase) { _, new in
            if case .done = new, session.lastAutoSaved != nil {
                showSaveToast = true
                saveToastTask?.cancel()
                saveToastTask = Task {
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled { showSaveToast = false }
                }
            }
            // A live recording stopped with nothing transcribed → there's no
            // session to review, so drop straight back to the Set to start panel.
            if case .done = new, session.transcript.lines.isEmpty,
               session.sourceMediaURL == nil {
                session.reset()
            }
        }
    }

    // Resize the real NSWindow when the setup↔working mode flips. First call (at
    // launch) snaps without animation; later flips animate the expand/collapse.
    private func syncWindowMode() {
        guard let w = appWindow else { return }
        let setup = showSetToStart
        if windowIsSetup == setup { return }
        let firstApply = (windowIsSetup == nil)
        windowIsSetup = setup
        applyWindowMode(w, setup: setup, animate: !firstApply)
    }

    private func applyWindowMode(_ w: NSWindow, setup: Bool, animate: Bool) {
        let vis = (w.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content: NSSize
        if setup {
            // The card IS the window (Figma rev.4 wide two-column card), but
            // free to resize — the content block centers itself both ways
            // (setToStartCard's GeometryReader), so stretching just adds margin.
            content = NSSize(width: min(1150, vis.width - 60), height: min(710, vis.height - 60))
            w.styleMask.insert(.resizable)
            w.contentMinSize = NSSize(width: 980, height: 640)
            w.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            // Expanded working layout — free resize again. (Title stays hidden /
            // titlebar transparent — set once in WindowAccessor, not per mode.)
            w.styleMask.insert(.resizable)
            w.contentMinSize = NSSize(width: 760, height: 520)
            w.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            content = NSSize(width: min(1150, vis.width - 60), height: min(710, vis.height - 60))
        }
        let frameSize = w.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        var frame = w.frame
        // Keep the window centered on its current screen through the transition.
        frame.origin.x = vis.midX - frameSize.width / 2
        frame.origin.y = vis.midY - frameSize.height / 2
        frame.size = frameSize
        w.setFrame(frame, display: true, animate: animate)
        // Re-assert the clean titlebar: mutating styleMask above resets these,
        // which is why the header separator kept coming back on layout switch.
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
    }

    // The pre-start "Set to start" screen (Figma 113:391) shows only while nothing
    // has begun yet: idle phase + no transcript. Staging a file keeps us here
    // (transcribeFile isn't called until 파일로 시작하기), so the card stays up with
    // the file staged. Any start → phase leaves .idle → expands into mainLayout.
    private var showSetToStart: Bool {
        if case .idle = session.phase, session.transcript.lines.isEmpty { return true }
        return false
    }

    // transcript fills the window; a fixed control panel sits on the right
    private var mainLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                // zIndex so its drop shadow (right edge) renders over
                // transcriptPane's opaque background instead of being clipped by
                // it — HStack draws later siblings on top by default.
                sidePanel.zIndex(1)
                transcriptPane
                // Always visible in the redesign — the header toggle is gone and
                // the export/folder controls live in this panel now.
                WorkspaceExplorer(session: session, isVisible: $showExplorer)
            }
            .background(
                ZStack {
                    Theme.Colors.surface
                    // Same trick as sidePanel's own catcher, one level further out:
                    // closes a pill dropdown when clicking the transcript pane too,
                    // while staying BEHIND this whole HStack's content so it never
                    // wins hit-testing over the dropdown rows themselves.
                    if languagePickerOpen || speakerCountPickerOpen || meetingModePickerOpen {
                        Color.black.opacity(0.0001)
                            .onTapGesture { languagePickerOpen = false; speakerCountPickerOpen = false; meetingModePickerOpen = false }
                    }
                }
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard canDrop, let url = urls.first(where: isMediaFile) else { return false }
                session.transcribeFile(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .sheet(isPresented: $showSummary) { summarySheet }
            .sheet(isPresented: $showRecap) { RecapCardView(session: session) { showRecap = false } }
            .sheet(isPresented: $showPrepBrief) {
                PrepBriefView(
                    session: session,
                    onClose: {
                        showPrepBrief = false
                        if let id = session.calendar.event?.id { dismissedPrepBriefEventIDs.insert(id) }
                    },
                    onSearchWorkspace: { session.searchPrepContext() }
                )
            }
            // Auto-show when a NEW event is detected (keyed by event id, so re-loading
            // the same event doesn't re-fire) and the user hasn't dismissed THAT event.
            .onChange(of: session.calendar.event?.id) { _, id in
                guard let id, !dismissedPrepBriefEventIDs.contains(id) else { return }
                session.ensurePrepBrief()
                showPrepBrief = true
            }

            // ⌘K — hidden button carries the shortcut; palette overlays everything.
            Button("") { showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            if showCommandPalette {
                CommandPalette(session: session, isPresented: $showCommandPalette)
                    .transition(.opacity).zIndex(1)
            }
        }
        .animation(.snappy, value: showCommandPalette)
    }

    // On-device meeting intelligence — summary + action items from the local LLM.
    // The transcript never leaves the Mac (the product moat vs cloud meeting tools).
    private var summarySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.Colors.textSecondary)   // de-accent
                Text("회의 요약").font(Theme.Fonts.appTitle)
                Text("온디바이스").font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
                Button("닫기") { showSummary = false }
            }
            Picker("", selection: $summaryBySpeaker) {
                Text("전체").tag(false)
                Text("화자별").tag(true)
            }
            .pickerStyle(.segmented).fixedSize()
            .onChange(of: summaryBySpeaker) { _, on in
                if on, session.speakerSummary == nil, !session.speakerSummarizing { session.summarizeBySpeaker() }
            }
            Divider().overlay(Theme.Colors.separator)
            let busy = summaryBySpeaker ? session.speakerSummarizing : session.summarizing
            let text = summaryBySpeaker ? session.speakerSummary : session.meetingSummary
            if busy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("로컬 LLM이 \(summaryBySpeaker ? "화자별 요약" : "요약")을 생성하는 중…")
                        .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
                    Text("전사 내용은 이 Mac을 떠나지 않습니다.")
                        .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text {
                ScrollView {
                    Text(text).font(.system(size: max(13, fontSize - 2)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button { copy(text) } label: { Label("복사", systemImage: "doc.on.doc") }
                    Button { summaryBySpeaker ? session.summarizeBySpeaker() : session.summarize() } label: {
                        Label("다시 생성", systemImage: "arrow.clockwise")
                    }
                    Button { exportDeck() } label: { Label("슬라이드(HTML)", systemImage: "rectangle.on.rectangle.angled") }
                    Button { showRecap = true } label: { Label("리캡 카드", systemImage: "rectangle.portrait.on.rectangle.portrait") }
                    Spacer()
                    Button("내보내기…") { export(.init(filenameExtension: "md")!) { try text.write(to: $0, atomically: true, encoding: .utf8) } }
                }.font(Theme.Fonts.status)
            }
            qaBlock
        }
        .padding(Theme.Space.window)
        .frame(width: 520, height: 540)
    }

    // "회의록한테 물어보기" — Q&A grounded in the transcript, on-device.
    private var qaBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.Colors.separator)
            Text("회의록에 물어보기").font(Theme.Fonts.section).foregroundStyle(Theme.Colors.textSecondary)
            Picker("", selection: $qaWorkspaceScope) {
                Text("이 회의").tag(false)
                Text("전체 워크스페이스").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 6) {
                TextField(qaWorkspaceScope ? "전체 회의록에서 검색 — 예: 지난달 보안 결정은?" : "예: 무엇을 결정했나요? / 김부장이 맡은 일은?", text: $qaInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask() }
                Button { ask() } label: { Image(systemName: "paperplane.fill") }
                    .disabled(qaInput.trimmingCharacters(in: .whitespaces).isEmpty || session.qaAsking)
            }
            if session.qaAsking {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("로컬 LLM이 답하는 중…").font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary) }
            } else if let a = session.qaAnswer {
                Text(a).font(.system(size: max(12, fontSize - 3)))
                    .foregroundStyle(Theme.Colors.textPrimary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.surfaceSunken))   // de-accent
            }
        }
    }
    private func ask() {
        let q = qaInput.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if qaWorkspaceScope { session.askWorkspace(q) } else { session.askTranscript(q) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    // save the summary as a presentation HTML deck, then reveal it in Finder
    private func exportDeck() {
        if let url = session.exportSummaryDeck() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: transcript pane (left, flexible)

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 20)   // top breathing room above the toolbar
            // (file progress / silence / pipeline chips all live in the
            // transcript-tail status line now — see transcriptStatus.)
            // Toolbar (글자 크기 · 내용/상세) stays put even while the transcript is
            // still empty/loading — the pane frame shouldn't jump when the first
            // line lands.
            viewModeBar
            // reconcile RESULT only (has an undo button, so it can't be a
            // transient status line); the in-progress state is the status line's.
            if session.reconcileNote != nil { reconcileBar }
            if viewMode == .detailed && !flaggedWords.isEmpty { reviewBar }
            // (Speaker timeline moved into the left panel's sequence bar —
            // Figma 188:662 has no timeline card above the transcript.)
            ZStack {
                if session.transcript.displayLines.isEmpty {
                    emptyState
                } else {
                    // displayLines (not lines): the ~30fps coalesced snapshot —
                    // the transcript panel re-diffs once per frame, not once per
                    // word/translation token (Phase 1 anti-twitch).
                    TranscriptView(lines: session.transcript.displayLines, names: session.speakerNames,
                                   autoRecognizedSpeakers: session.autoRecognizedSpeakers,
                                   mode: viewMode,
                                   onRename: { session.renameSpeaker($0, to: $1) },
                                   scrollTarget: scrollTarget, scrollTick: scrollTick,
                                   focusedLine: scrollTarget,
                                   interim: session.livePartial,
                                   interimTranslations: session.livePartialTranslations,
                                   warningText: transcriptWarning,
                                   gapTimes: coverageGapTimes,
                                   activityText: transcriptActivity,
                                   activeLangs: session.translateTargets.sorted(),
                                   translateBusy: session.translateQueueDepth > 0
                                       || session.streamingTranslation != nil,
                                   fontSize: fontSize,
                                   streamingTransID: session.streamingTranslation?.id,
                                   streamingTransLang: session.streamingTranslation?.lang,
                                   onEdit: { session.editLine($0, to: $1) },
                                   onEditWord: { session.editWord($0, index: $1, to: $2) },
                                   lockedLineID: isRecordingLike ? session.transcript.lines.last?.id : nil,
                                   onRequestDetailed: { contentMode = false },
                                   onPlay: session.sourceMediaURL != nil ? { session.playLine($0) } : nil,
                                   playingLine: session.linePlayer.currentLine,
                                   onScrolledFromTopChange: { transcriptScrolled = $0 })
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity)
                        // Top+bottom fades (Figma 188:733 / 195:1039): scrolled
                        // text dissolves into the window instead of clipping hard.
                        // Top fade only while earlier text is hidden above.
                        .overlay(alignment: .top) {
                            if transcriptScrolled {
                                LinearGradient(
                                    colors: [Theme.Colors.surface, Theme.Colors.surface.opacity(0)],
                                    startPoint: .top, endPoint: .bottom)
                                    .frame(height: 36)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [Theme.Colors.surface.opacity(0), Theme.Colors.surface],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: 60)
                                .allowsHitTesting(false)
                        }
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Colors.accent.opacity(0.06)))
                        .overlay(Label("드롭하여 전사", systemImage: "tray.and.arrow.down")
                            .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.accent))
                        .padding(8).allowsHitTesting(false)
                }
                // (countdown now renders inline as the pre-transcript status
                // line in emptyState — no separate full-pane ring overlay.)
                if showSaveToast {
                    VStack {
                        Spacer()
                        saveToast
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.surface)
            .animation(.snappy(duration: 0.3), value: showSaveToast)
        }
    }

    // Dark blurred toast pinned to the transcript column's bottom edge —
    // "saved" confirmation + the shortcut back to a fresh session.
    private var saveToast: some View {
        HStack(spacing: 10) {
            Text(saveToastText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            Button {
                showSaveToast = false
                if let u = session.lastAutoSaved { NSWorkspace.shared.open(u) }
            } label: {
                HStack(spacing: 5) {
                    Text("파일 열기")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)   // de-accent: was #889CFF
                    SVGIcon(name: "chevron-left", size: 12, tint: .white)
                        .rotationEffect(.degrees(180))   // point right
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.6))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .frame(maxWidth: 572)
        .padding(.horizontal, 10)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var saveToastText: String {
        if let u = session.lastAutoSaved {
            return "회의록이 자동 저장되었어요 · \(u.lastPathComponent)"
        }
        return "회의록이 자동 저장되었어요"
    }

    // 내용/상세 toggle — keeps the clean reading view (default) free of the
    // editor/review detail. Persisted across launches via @AppStorage.
    // Pill-shaped 내용/상세 switch — same shape language as WorkspaceExplorer's
    // 파일/사람/열린 항목/음성 switcher (sliding accent capsule via matchedGeometryEffect).
    // rev.2 pill (Figma 188:771): gray track, WHITE sliding thumb with a soft
    // drop shadow — replaces the accent-filled capsule of rev.1.
    @Namespace private var contentModeNS
    private var contentModeSwitch: some View {
        HStack(spacing: 1) {
            ForEach([true, false], id: \.self) { isContent in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { contentMode = isContent }
                } label: {
                    Text(isContent ? "내용" : "상세")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(contentMode == isContent ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background {
                            if contentMode == isContent {
                                Capsule().fill(Theme.Colors.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 2)
                                    .matchedGeometryEffect(id: "contentModePill", in: contentModeNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(width: 99)
        .background(Capsule().fill(Theme.Colors.surfaceSunken))
    }

    // rev.3 toolbar (Figma 188:766): font-size group left, 내용/상세 pill right.
    // Reset is gone — leaving a session now goes through the left panel's back
    // chevron or the save-toast's 새 기록 시작.
    private var viewModeBar: some View {
        HStack(spacing: 10) {
            Button { fontSize = max(12, fontSize - 2) } label: { Text("A").font(.system(size: 11)) }
                .buttonStyle(.plain).help("글자 작게")
            Text("\(Int(fontSize))").font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary).monospacedDigit()
            Button { fontSize = min(34, fontSize + 2) } label: { Text("A").font(.system(size: 17)) }
                .buttonStyle(.plain).help("글자 크게")
            Spacer(minLength: 0)
            // A5/B9: floating live-translation caption overlay (Zoom·Teams 위,
            // 클리닉 이중 패널 포함) — translate targets picked in Settings.
            if !session.translateTargets.isEmpty {
                Button { session.toggleCaptionOverlay() } label: {
                    Image(systemName: session.captionOverlayOn ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.captionOverlayOn ? Theme.Colors.accent : Theme.Colors.textSecondary)
                .help(session.captionOverlayOn ? "자막 오버레이 끄기" : "자막 오버레이 — 화면 위 실시간 번역 자막 창")
            }
            // C18: chat layout toggle (two-party only) — hidden from the toolbar
            // (the 말풍선 icon). The .chat mode still exists in code but isn't
            // exposed here; flip `showChatToggle` to restore it.
            let showChatToggle = false
            if showChatToggle, twoSpeakers {
                Button { chatLayout.toggle() } label: {
                    Image(systemName: chatLayout ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(chatLayout ? Theme.Colors.accent : Theme.Colors.textSecondary)
                .help("대화 레이아웃 (직원 왼쪽 · 환자 오른쪽)")
            }
            contentModeSwitch
                .disabled(chatLayout && twoSpeakers)
                .opacity(chatLayout && twoSpeakers ? 0.45 : 1)
                .help("내용: 깨끗한 회의록 보기 · 상세: 시각·신뢰도·겹침 표시")
        }
        .padding(.leading, 21).padding(.trailing, 16).padding(.vertical, 8)
        .padding(.top, 5)
    }

    /// Post-session AI correction RESULT + one-tap undo of speaker changes.
    /// (The in-progress state is the transcript-tail status line.)
    private var reconcileBar: some View {
        HStack(spacing: 10) {
            if let note = session.reconcileNote {
                Image(systemName: "wand.and.stars").font(.system(size: 12)).foregroundStyle(Theme.Colors.textSecondary)   // de-accent
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                if session.transcript.hasSpeakerCorrections {
                    Button("화자 교정 되돌리기") { session.revertReconcile() }
                        .controlSize(.small).buttonStyle(.plain).foregroundStyle(Theme.Colors.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.Colors.surfaceSunken)   // de-accent
        .overlay(alignment: .bottom) { Divider() }
    }

    private var reviewBar: some View {
        let flagged = flaggedWords
        let idx = min(reviewIndex, max(0, flagged.count - 1))
        func jump(_ d: Int) {
            guard !flagged.isEmpty else { return }
            review.stop(); session.linePlayer.stop()   // manual chevron pauses listen-mode
            reviewIndex = ((idx + d) % flagged.count + flagged.count) % flagged.count
            scrollTarget = flagged[reviewIndex].line
            scrollTick += 1
        }
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.lowConf)
            Text("검토 필요 \(flagged.count)개").font(Theme.Fonts.status)
            if !flagged.isEmpty {
                Text("· \(flagged[idx].text)").font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                Spacer()
                Text("\(idx + 1)/\(flagged.count)").font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textTertiary)
                ReviewControlView(session: session, controller: review,
                                  reviewIndex: $reviewIndex,
                                  scrollTarget: $scrollTarget,
                                  scrollTick: $scrollTick,
                                  flaggedCount: flagged.count)
                Button { jump(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).help("이전 검토 단어")
                Button { jump(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).help("다음 검토 단어")
            } else { Spacer() }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.Colors.lowConf.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.Space.window)
        .padding(.top, 5).padding(.bottom, 5)
    }

    // (file-transcription progress + dead-mic warning banners folded into the
    // transcript-tail status line — see transcriptStatus / StatusLineView.)

    private var emptyState: some View {
        Group {
            if case .error(let msg) = session.phase {
                errorState(msg)
            } else if isBusy {
                // Pre-transcript: NOT a centered spinner/orb — the transcript
                // simply "hasn't shown yet", so the pane carries the SAME status
                // line the user already knows (gray text + loading dots; the
                // warn-gradient during countdown), placed top-left where the
                // first line lands. One consistent loading language start→
                // countdown→전사→번역.
                VStack(alignment: .leading, spacing: 0) {
                    preTranscriptStatus
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Theme.Space.window)
            } else {
                readyState
            }
        }
    }

    // The single top-left status row shown while the transcript is still empty.
    @ViewBuilder private var preTranscriptStatus: some View {
        HStack(spacing: 5) {
            if case .countingDown(let n) = session.phase {
                // Same warn-gradient as the status rows, NO exclamation icon —
                // reads as an eager "about to start", not a warning.
                GradientText("곧 녹음이 시작됩니다 \(n)")
                LoadingDots(color: Color(red: 136/255, green: 145/255, blue: 234/255))
                    .padding(.top, 4)
            } else {
                Text("전사 결과가 곧 여기에 표시됩니다")
                    .font(StatusArea.warnFont).tracking(-0.28)
                    .foregroundStyle(Theme.Colors.textTertiary)
                LoadingDots(color: Theme.Colors.textTertiary)
                    .padding(.top, 4)
            }
        }
        .frame(height: 21)
    }

    private var readyState: some View {
        VStack(spacing: 16) {
            OrbView()
            VStack(spacing: 6) {
                Text("기록할 준비가 되었어요")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("‘녹음 시작’을 누르거나, 오디오·영상 파일을 끌어다 놓으세요.")
                    .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.orange)
            Text(msg).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            HStack(spacing: 8) {
                if msg.contains("마이크 권한") {
                    Button("시스템 설정 열기") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if msg.contains("모델이 준비되지") {
                    SettingsLink { Text("설정 열기") }.buttonStyle(.borderedProminent)
                }
                Button("처음으로") { session.reset() }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }


    // soft accent halo behind a glyph — warm, calm focal point for empty/idle states
    private func haloIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(Theme.Colors.textTertiary)   // de-accent
            .frame(width: 88, height: 88)
            .background(Circle().fill(Theme.Colors.surfaceSunken))
    }

    // MARK: — Set to start (Figma 113:391) — pre-start config card

    // Redesign chip/CTA/track colors, now routed through adaptive Theme tokens so
    // dark mode works (was hardcoded light-mode literals). chipInk = the monochrome
    // selected-chip / primary-CTA fill (inverts for dark); chipInkOn = its glyph.
    private static let chipInk = Theme.Colors.inkStrong
    // brand/700 — the *Optional badge (Figma 246:789); reads on light & dark.
    private static let optionalOrange = Color(red: 217/255, green: 78/255, blue: 0/255)
    private static let chipInkOn = Theme.Colors.inkStrongOn
    private static let dashBorder = Theme.Colors.separator      // dashed drop-zone border
    private static let dropZoneGray = Theme.Colors.textSecondary // file-size subtitle / drop icon
    private static let controlSubtle = Theme.Colors.surfaceSunken // sunken control fill (파일 선택 pill)

    // "Set to start" rev.4 (Figma 246:749): wordmark + tagline up top, then two
    // columns — 회의 정보 (language/mode/speaker knobs) | divider | 시작하기
    // (file drop + start CTAs + mic picker). The language dropdown panels float
    // in a ZStack layer above the columns, positioned by measured pill frames.
    private var setToStartCard: some View {
        // GeometryReader + minHeight keeps the whole block centered BOTH ways as
        // the window grows, while the ScrollView still kicks in when it shrinks.
        GeometryReader { geo in
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header (Figma 246:801/800) — leading-aligned with the
                    // 회의 정보 column below.
                    BrandLogo(width: 126)
                    Text("녹음하면 회의가 글이 되고, 실시간으로 번역돼요. 모두 이 Mac 안에서")
                        .font(Theme.Fonts.startTagline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)   // wrap to 2 lines
                        .frame(width: 380, alignment: .leading)
                        .padding(.top, 12)

                    HStack(alignment: .top, spacing: 77) {
                        meetingInfoColumn
                        Rectangle().fill(Theme.Colors.surfaceSunken)
                            .frame(width: 1).frame(maxHeight: .infinity)
                        startColumn
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 110)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                // Extra bottom margin: the header-heavy layout reads as sitting
                // low when geometrically centered, so bias the block upward.
                .padding(.bottom, 100)
            }
            // Click-away layer + floating dropdown panel as OVERLAYS: they draw
            // above the card without contributing to its layout size (as ZStack
            // children they inflated it, shoving the centered content upward).
            // Later overlay wins hit-testing, so the panel stays clickable.
            .overlay(alignment: .topLeading) {
                if openLangDropdown != nil {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { openLangDropdown = nil }
                }
            }
            .overlay(alignment: .topLeading) {
                if let which = openLangDropdown, let f = langPillFrames[which] {
                    langDropdownPanel(which)
                        .frame(width: f.width)
                        .offset(x: f.minX, y: f.maxY + 4)
                }
            }
            .coordinateSpace(name: "startCard")
            .onPreferenceChange(LangPillFrameKey.self) { langPillFrames = $0 }
            // Fill the viewport so the (default-center) frame alignment centers
            // the content vertically; dropdown offsets stay ZStack-relative.
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
        }
        // macOS 26 draws a hard scroll-edge hairline where content passes under
        // the transparent titlebar — reads as a header divider here; suppress.
        .modifier(HideTopScrollEdgeHairline())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surface)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: isMediaFile) else { return false }
            stagedFile = u; return true
        } isTargeted: { dropTargeted = $0 }
    }

    // Left column (Figma 463:2864): 회의 정보 — the language/mode/speaker knobs,
    // moved here so 시작하기 keeps only the actual start actions. (최근 항목 left
    // this screen in the rev.4 redesign.)
    private var meetingInfoColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("회의 정보")
                    .font(Theme.Fonts.startHeader).foregroundStyle(Theme.Colors.textPrimary)
                Text("회의 정보를 설정하면 더 정확한 결과를 얻을 수 있어요")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                languageRow
                setupBlock("회의 모드") { meetingChips }
                setupBlock("화자") { speakerChips }
            }
            .padding(.top, 22)
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Right column (Figma 246:750): 시작하기 — file drop + 파일로 시작하기, an
    // "or" hairline, then mic picker + 지금 녹음 시작 side by side.
    private var startColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("시작하기")
                    .font(Theme.Fonts.startHeader).foregroundStyle(Theme.Colors.textPrimary)
                Text("오디오, 비디오 파일을 선택하거나 지금 바로 녹음을 시작해 보세요")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                setupDropZone
                setupCTA("파일로 시작하기", enabled: stagedFile != nil) {
                    if let u = stagedFile { stagedFile = nil; session.transcribeFile(u) }
                }
                orDivider
                    .padding(.vertical, 2)
                HStack(spacing: 4) {
                    micPicker
                    setupCTA("지금 녹음 시작", enabled: stagedFile == nil) {
                        session.startCountdown()
                    }
                }
            }
        }
        .frame(width: 380)
    }

    // Figma 463:2932 — hairline · or · hairline between the two start paths.
    private var orDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.Colors.surfaceSunken)
                .frame(height: 1).frame(maxWidth: .infinity)
            Text("or")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.textPrimary)
            Rectangle().fill(Theme.Colors.surfaceSunken)
                .frame(height: 1).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 2)
    }

    /// Mic device rows for the custom dropdown panels — same visual language as
    /// the language dropdowns (check row, closes on pick). Selection routes
    /// through setInputDevice so a live session hot-swaps.
    @ViewBuilder private var micPanelRows: some View {
        langCheckRow("시스템 기본", checked: session.inputDeviceID == nil, dimmed: false) {
            session.setInputDevice(nil); openLangDropdown = nil
        }
        ForEach(session.availableInputs) { dev in
            langCheckRow(dev.name, checked: session.inputDeviceID == dev.id, dimmed: false) {
                session.setInputDevice(dev.id); openLangDropdown = nil
            }
        }
    }

    // Mic input picker (Figma 463:2851): which device 지금 녹음 시작 captures.
    // Opens the shared custom dropdown panel (id "mic") like the language pills.
    private var micPicker: some View {
        Button {
            openLangDropdown = (openLangDropdown == "mic") ? nil : "mic"
        } label: {
            HStack(spacing: 4) {
                Text(micLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .rotationEffect(.degrees(openLangDropdown == "mic" ? 180 : 0))
            }
            .padding(.leading, 22).padding(.trailing, 16)
            .frame(width: 200, height: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Theme.Colors.surface))
        // Outline unified with the 회의 정보 pills (surfaceSunken, not meterTrack).
        .overlay(Capsule().strokeBorder(Theme.Colors.surfaceSunken, lineWidth: 1))
        .help("녹음에 사용할 마이크")
        .background(GeometryReader { g in
            Color.clear.preference(key: LangPillFrameKey.self,
                                   value: ["mic": g.frame(in: .named("startCard"))])
        })
    }

    /// Collapsed mic label: the chosen device, else the system default's name.
    private var micLabel: String {
        let inputs = session.availableInputs
        if let id = session.inputDeviceID,
           let d = inputs.first(where: { $0.id == id }) { return d.name }
        if let def = AudioDevices.defaultInputID,
           let d = inputs.first(where: { $0.id == def }) { return d.name }
        return "시스템 기본"
    }

    // 인풋(단일)·아웃풋(멀티 체크박스) 언어 드롭다운 한 줄 (Figma 246:756 +
    // 247:555). Panels render at the card's ZStack layer (see setToStartCard).
    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("입력 언어")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("출력 언어")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 3)
            HStack(spacing: 4) {
                langTrigger(id: "input", label: inputLangLabel)
                langTrigger(id: "output", label: outputLangLabel)
                    .opacity(AssetManifest.translateAvailable ? 1 : 0.4)
                    .allowsHitTesting(AssetManifest.translateAvailable)
                    .help(AssetManifest.translateAvailable ? "" : "번역 모델이 필요해요 — 설정 › 번역")
            }
        }
    }

    // MARK: language dropdowns (Figma 247:555)

    /// Input options: whisper token id (nil = auto-detect) + display label.
    private static let inputLangOptions: [(id: Int?, label: String)] = [
        (nil, "자동"), (WhisperLang.ko, "한국어"), (WhisperLang.en, "영어"),
        (WhisperLang.zh, "중국어"), (WhisperLang.ja, "일본어"),
    ]
    /// Output options: translateTargets code + Korean display label.
    private static let outputLangOptions: [(code: String, label: String)] = [
        ("Korean", "한국어"), ("English", "영어"), ("Chinese", "중국어"), ("Japanese", "일본어"),
    ]
    private let maxTranslateTargets = 3

    private var inputLangLabel: String {
        Self.inputLangOptions.first { $0.id == session.languageTokenID }?.label ?? "자동"
    }

    /// translateTargets code of the chosen input language (nil for 자동) — used
    /// to drop it from the output list (KO→KO translation is meaningless).
    private var inputLangCode: String? {
        switch session.languageTokenID {
        case WhisperLang.ko: return "Korean"
        case WhisperLang.en: return "English"
        case WhisperLang.zh: return "Chinese"
        case WhisperLang.ja: return "Japanese"
        default: return nil
        }
    }

    /// Collapsed pill label: 번역 안 함 / 영어 / 영어 · 일본어 / 영어 외 2.
    private var outputLangLabel: String {
        let labelFor: (String) -> String = { code in
            Self.outputLangOptions.first { $0.code == code }?.label ?? code
        }
        let picked = session.translateTargets.sorted().map(labelFor)
        switch picked.count {
        case 0: return "번역 안 함"
        case 1: return picked[0]
        case 2: return picked.joined(separator: " · ")
        default: return "\(picked[0]) 외 \(picked.count - 1)"
        }
    }

    private func setLanguage(_ id: Int?) {
        session.languageTokenID = id
        UserDefaults.standard.set(id ?? 0, forKey: "languageTokenID")
        // The new input language can't also be a translation target.
        if let code = inputLangCode, session.translateTargets.contains(code) {
            var t = session.translateTargets; t.remove(code)
            session.translateTargets = t
        }
        openLangDropdown = nil
    }

    private func toggleTranslateTarget(_ code: String) {
        var t = session.translateTargets
        if t.contains(code) { t.remove(code) }
        else if t.count < maxTranslateTargets { t.insert(code) }   // 최대 3개 동시 번역
        session.translateTargets = t
    }

    /// Trigger pill (h30): label + chevron; tap toggles its panel. Reports its
    /// frame in the card's coordinate space so the panel can anchor below it.
    private func langTrigger(id: String, label: String) -> some View {
        Button {
            openLangDropdown = (openLangDropdown == id) ? nil : id
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .rotationEffect(.degrees(openLangDropdown == id ? 180 : 0))
            }
            .padding(.leading, 14).padding(.trailing, 12)
            .frame(height: 34)   // +2px top/bottom — closes the gap to the mic pill
            .background(Capsule().fill(Theme.Colors.surface))
            .overlay(Capsule().strokeBorder(Theme.Colors.surfaceSunken, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear.preference(key: LangPillFrameKey.self,
                                   value: [id: g.frame(in: .named("startCard"))])
        })
    }

    /// The floating panel (Figma 246:1222/1244): white card, radius 12, rows of
    /// px14/py8. Input = single-select (closes on pick); output = checkbox
    /// multi-select topped by an exclusive "번역 안 함" row (stays open).
    @ViewBuilder
    private func langDropdownPanel(_ which: String) -> some View {
        VStack(spacing: 0) {
            if which == "mic" || which == "side-mic" {
                micPanelRows
            } else if which == "input" {
                ForEach(Self.inputLangOptions, id: \.label) { opt in
                    Button { setLanguage(opt.id) } label: {
                        HStack {
                            Text(opt.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                langCheckRow("번역 안 함", checked: session.translateTargets.isEmpty, dimmed: false) {
                    session.translateTargets = []
                }
                ForEach(Self.outputLangOptions.filter { $0.code != inputLangCode }, id: \.code) { opt in
                    let on = session.translateTargets.contains(opt.code)
                    let capped = !on && session.translateTargets.count >= maxTranslateTargets
                    langCheckRow(opt.label, checked: on, dimmed: capped) {
                        toggleTranslateTarget(opt.code)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.black.opacity(0.04), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    /// Output row: label + 15pt checkbox (#141616 filled + white ✓ when on).
    private func langCheckRow(_ label: String, checked: Bool, dimmed: Bool,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: 8)
                ZStack {
                    if checked {
                        RoundedRectangle(cornerRadius: 6).fill(Self.chipInk)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Self.chipInkOn)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.separator, lineWidth: 0.75)
                    }
                }
                .frame(width: 15, height: 15)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.4 : 1)
        .allowsHitTesting(!dimmed)
    }

    @ViewBuilder
    private func setupBlock<V: View>(_ title: String, optional: Bool = false, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                if optional {
                    Text("*Optional").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Self.optionalOrange)
                }
            }
            .padding(.horizontal, 3)
            content()
        }
    }

    private var meetingChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(MeetingMode.allCases) { m in
                    setupChip(m.label, selected: session.meetingMode == m) { session.meetingMode = m }
                }
            }
        }
    }

    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SpeakerCount.allCases) { s in
                    setupChip(s.label, selected: session.speakerCount == s) { session.speakerCount = s }
                }
            }
        }
    }

    // Figma 246:771 chip: both states keep the white fill and 12px medium ink —
    // selection is a dark OUTLINE (#070808-equivalent ink border), not a solid
    // black fill (that budget now belongs to the CTA row).
    private func setupChip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Theme.Colors.surface))
                .overlay(Capsule().strokeBorder(
                    selected ? Self.chipInk : Theme.Colors.surfaceSunken, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var setupDropZone: some View {
        if let f = stagedFile {
            // After upload (Figma 216:1811): white card, folder icon + name + size,
            // close (times) button top-right to clear the staged file.
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    SVGIcon(name: "content", size: 20)   // de-accent: neutral doc glyph
                    VStack(spacing: 1) {
                        Text(f.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(fileSizeLabel(f))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Self.dropZoneGray)
                    }
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button { stagedFile = nil } label: {
                    SVGIcon(name: "close", size: 13)
                }
                .buttonStyle(.plain)
                .padding(.top, 9).padding(.trailing, 11)
            }
            .frame(maxWidth: .infinity).frame(height: 85)
            .background(
                // Match the 재생/멈춤 controls: shadow only, no outline.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Colors.surface)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            )
        } else {
            // Before upload (Figma 463:2912): compact dashed strip — the whole
            // zone is the picker button ("파일 선택 or 드래그 앤 드롭").
            Button { chooseStagedFile() } label: {
                VStack(spacing: 4) {
                    SVGIcon(name: "folder-plus", size: 24)
                        .opacity(0.6)
                    Text("파일 선택 or 드래그 앤 드롭")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                .frame(maxWidth: .infinity).frame(height: 85)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!canDrop)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dropTargeted ? Theme.Colors.accent : Self.dashBorder,
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
    }

    /// Compact byte-size label for a staged file (Figma "234k").
    private func fileSizeLabel(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)k" }
        return String(format: "%.1fM", Double(bytes) / (1024 * 1024))
    }

    // Figma 246:797 CTA pills (h40). Whichever can't start right now renders on
    // the muted track fill so exactly one reads as "press this". (The design's
    // 10% ghost swallowed the white label — meterTrack keeps it legible.)
    private func setupCTA(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            Text(title)
                .font(Theme.Fonts.cta)
                .foregroundStyle(Self.chipInkOn)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(Capsule().fill(enabled ? Self.chipInk : Theme.Colors.meterTrack))
        }
        .buttonStyle(.plain)
        // .allowsHitTesting (not .disabled) so the label keeps full opacity —
        // .disabled applies a system dim that grays the white text out.
        .allowsHitTesting(enabled)
    }

    private func chooseStagedFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .audiovisualContent, .movie, .video]
        if panel.runModal() == .OK, let url = panel.url { stagedFile = url }
    }

    // MARK: right control panel

    // Left session panel (Figma 188:672): floating white card — wordmark+gear /
    // big transport buttons / 총 시간 + speaker sequence bar + share list /
    // 에너지 흐름 line graph. (Live rail/coach panels dropped for v1 — their
    // engine isn't shipped; the toggles are already out of the UI.)
    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // rev.3 header: back chevron (→ Set to start) / centered wordmark /
            // black gear. Back only acts when the session is over — mid-recording
            // it dims instead of tearing the session down.
            ZStack {
                BrandLogo(width: 64)
                HStack {
                    Button { handleBack() } label: {
                        SVGIcon(name: "chevron-left", size: 22)
                    }
                    .buttonStyle(.plain)
                    .help("시작 화면으로")
                    .confirmationDialog("녹음이 진행 중이에요", isPresented: $showStopConfirm, titleVisibility: .visible) {
                        Button("정지하기", role: .destructive) { session.stop() }
                        Button("계속 녹음", role: .cancel) {}
                    } message: {
                        Text("정지하면 여기까지의 기록이 정리돼요. 자동저장이 켜져 있으면 파일로 저장됩니다.")
                    }
                    .confirmationDialog("저장되지 않은 기록이 있어요", isPresented: $showBackDiscardConfirm, titleVisibility: .visible) {
                        Button("삭제하고 나가기", role: .destructive) { session.reset() }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text("자동저장이 꺼져 있어 나가면 이 기록은 사라져요. 내보내기로 먼저 저장할 수 있어요.")
                    }
                    Spacer()
                    SettingsLink { SVGIcon(name: "setting", size: 22) }
                        .buttonStyle(.plain)
                        .help("설정 (⌘,)")
                }
            }
            .padding(.horizontal, 16).padding(.top, 18)

            bigControls
                .padding(.horizontal, 16).padding(.top, 16)

            // Input-mic row (Figma 470:3074): visible during a live mic session
            // so the device can be swapped WITHOUT stopping the recording.
            if micRowVisible {
                micRow
                    .padding(.horizontal, 16).padding(.top, 16)
            }

            Rectangle().fill(Theme.Colors.surfaceSunken).frame(height: 1)
                .padding(.horizontal, 16).padding(.top, 22)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    totalTimeBlock
                        .padding(.top, 18)
                    if !session.transcript.lines.isEmpty {
                        speakerSequenceBar.padding(.top, 16)
                        speakerShareList.padding(.top, 18)
                    }
                    Rectangle().fill(Theme.Colors.surfaceSunken).frame(height: 1)
                        .padding(.top, 24)
                    // Finer buckets than the default 30 so brief pauses / lulls
                    // register as dips instead of being averaged flat — the dot
                    // graph then has something to contrast-stretch. While
                    // recording, a 1s tick extends the span to "now" so the graph
                    // visibly grows in real time (silence included) instead of
                    // jumping only when a line commits.
                    // ~7fps while recording so the live meter feels alive; the
                    // energy recompute over the (bounded) line list is cheap.
                    TimelineView(.periodic(from: .now, by: isRecordingLike ? 0.15 : 1)) { _ in
                        let live = isRecordingLike ? session.recordedSeconds : nil
                        let energy = EnergyArc.compute(lines: session.transcript.lines,
                                                       buckets: 64, spanEnd: live)
                        EnergyArcView(values: energy, lines: session.transcript.lines,
                                      liveEnd: live,
                                      liveLevel: isRecordingLike ? session.meterLevel : nil) { id in
                            scrollTarget = id; scrollTick += 1
                        }
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 267)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.Colors.surface))
        // Clip content to the card shape so the edge-to-edge speaker bar (and its
        // left fade) slide under the card edge instead of painting over the
        // border; the border is then re-drawn ON TOP so it always stays crisp.
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(Theme.Colors.surfaceSunken, lineWidth: 1))
        .shadow(color: .black.opacity(0.03), radius: 9, x: 4, y: 4)
        .padding(.vertical, 13)
        .padding(.leading, 13)
        // Custom mic dropdown (same panel style as the start screen's language
        // pickers): click-catcher + floating panel as layout-neutral overlays,
        // anchored by the mic row's measured frame in this coordinate space.
        .coordinateSpace(name: "sidePanel")
        .onPreferenceChange(LangPillFrameKey.self) { langPillFrames.merge($0) { _, new in new } }
        .overlay(alignment: .topLeading) {
            if openLangDropdown == "side-mic" {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { openLangDropdown = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if openLangDropdown == "side-mic", let f = langPillFrames["side-mic"] {
                langDropdownPanel("side-mic")
                    .frame(width: f.width)
                    .offset(x: f.minX, y: f.maxY + 4)
            }
        }
    }

    // MARK: input-mic row (Figma 470:3074)

    /// Only a LIVE mic session can hot-swap its input — file transcription and
    /// system-audio capture have no mic to switch.
    private var micRowVisible: Bool {
        guard session.sourceMediaURL == nil, session.audioSource != .system else { return false }
        switch session.phase {
        case .recording, .paused: return true
        default: return false
        }
    }

    /// "입력 마이크 · <device> ⌄" — swaps the capture device mid-recording.
    private var micRow: some View {
        HStack(spacing: 8) {
            Text("입력 마이크")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer(minLength: 8)
            Button {
                openLangDropdown = (openLangDropdown == "side-mic") ? nil : "side-mic"
            } label: {
                HStack(spacing: 2) {
                    Text(micLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .rotationEffect(.degrees(openLangDropdown == "side-mic" ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("녹음 중에도 입력 마이크를 바꿀 수 있어요")
        }
        // The panel anchors to the WHOLE row's frame (panel width = row width).
        .background(GeometryReader { g in
            Color.clear.preference(key: LangPillFrameKey.self,
                                   value: ["side-mic": g.frame(in: .named("sidePanel"))])
        })
    }

    // MARK: big transport controls (Figma 188:711 — two 106pt cards)

    @ViewBuilder private var bigControls: some View {
        // File transcription (any phase) and a finished live session with content
        // show the file card (blue folder + name + size + close) in the top slot
        // instead of live transport / "새 기록 시작".
        if showFileCard {
            fileCard
        } else {
            liveControls
        }
    }

    /// True in file mode, or once a live session is done with transcribed content.
    private var showFileCard: Bool {
        if session.sourceMediaURL != nil { return true }
        if case .done = session.phase, !session.transcript.lines.isEmpty { return true }
        return false
    }

    @ViewBuilder private var liveControls: some View {
        switch session.phase {
        case .recording:
            HStack(spacing: 5) {
                bigControl("일시 정지", action: { session.pauseRecording() }) { pauseGlyph }
                    .keyboardShortcut("p")
                bigControl("정지", action: { session.stop() }) { stopGlyph }
                    .keyboardShortcut("r")
            }
        case .paused:
            HStack(spacing: 5) {
                // rev.3 (Figma 188:714): 재개 is a BLACK play triangle, matching
                // the pause glyph's ink — only 정지 stays red.
                bigControl("재개", action: { session.resumeRecording() }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15)).foregroundStyle(Theme.Colors.textPrimary)
                }
                .keyboardShortcut("p")
                bigControl("정지", action: { session.stop() }) { stopGlyph }
                    .keyboardShortcut("r")
            }
        case .countingDown(let n):
            bigControl("시작까지 \(n) · 취소", action: { session.cancelCountdown() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
            }
            .keyboardShortcut(.cancelAction)
        case .engineStarting, .ready, .flushing:
            busyCard(phaseText)
        case .processing:
            busyCard(session.chunksTotal > 0
                     ? "전사 중 · \(Int(Double(session.chunksDone) / Double(session.chunksTotal) * 100))%"
                     : phaseText)
        default:
            // done / error: the session is over — the only forward move is a new
            // one, which routes back through the Set to start screen via reset().
            bigControl("새 기록 시작", action: { session.reset() }) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
            }
        }
    }

    // File card for the left panel top (matches the drop zone's "after upload"
    // card). Used for file transcription (name = source file, subtitle = progress
    // → size) and for a finished live session with content (name = saved .md,
    // subtitle = its size, or the recorded duration when autosave is off). Close
    // returns to Set to start.
    private var fileCard: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                SVGIcon(name: "content", size: 20)   // de-accent: neutral doc glyph
                VStack(spacing: 1) {
                    Text(fileCardName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(fileCardSubtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Self.dropZoneGray)
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { closeFileCard() } label: {
                SVGIcon(name: "close", size: 13)
            }
            .buttonStyle(.plain)
            .padding(.top, 9).padding(.trailing, 11)
            .help("닫기")
        }
        .frame(maxWidth: .infinity).frame(height: 118)
        .background(
            // Match the 재생/멈춤 controls: shadow only, no outline.
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Colors.surface)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        )
        .confirmationDialog("저장되지 않은 기록이 있어요", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("삭제하고 닫기", role: .destructive) { session.reset() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("자동저장이 꺼져 있어 닫으면 이 기록은 사라져요. 내보내기로 먼저 저장할 수 있어요.")
        }
    }

    /// True when leaving would lose content: lines exist but nothing hit disk.
    /// Excludes file sessions (source media persists) and opened archives
    /// (fileName is set from the .md that's already on disk).
    private var hasUnsavedTranscript: Bool {
        !session.transcript.lines.isEmpty && session.lastAutoSaved == nil
            && session.sourceMediaURL == nil && session.fileName.isEmpty
    }

    private func closeFileCard() {
        switch session.phase {
        case .processing, .flushing:
            session.cancelFile()   // reset() no-ops mid-transcription — this tears the engine down
        default:
            if hasUnsavedTranscript { showDiscardConfirm = true } else { session.reset() }
        }
    }

    /// Back chevron: countdown → cancel; recording → confirm stop (reset() would
    /// silently no-op there, which read as a dead button); unsaved content →
    /// confirm discard; otherwise straight back to Set to start.
    private func handleBack() {
        switch session.phase {
        case .countingDown:
            session.cancelCountdown()
        case .recording, .paused:
            showStopConfirm = true
        case .processing, .flushing:
            session.cancelFile()   // file transcription in flight
        default:
            if hasUnsavedTranscript { showBackDiscardConfirm = true } else { session.reset() }
        }
    }

    private var fileCardName: String {
        // fileName covers file mode, opened archives, and AI-titled live sessions;
        // otherwise fall back to the auto-saved .md name (live w/o title).
        if !session.fileName.isEmpty { return session.fileName }
        return session.lastAutoSaved?.lastPathComponent ?? "회의 기록"
    }

    private var fileCardSubtitle: String {
        if case .processing = session.phase, session.sourceMediaURL != nil {
            if session.chunksTotal > 0 {
                return "전사 중 · \(Int(Double(session.chunksDone) / Double(session.chunksTotal) * 100))%"
            }
            return "전사 중…"
        }
        // Size of whichever file backs this session; fall back to the duration
        // for a live session that wasn't auto-saved.
        if let u = session.sourceMediaURL { return fileSizeLabel(u) }
        if let u = session.lastAutoSaved { return fileSizeLabel(u) }
        return totalTimeText
    }

    private var pauseGlyph: some View {
        HStack(spacing: 2.5) {
            RoundedRectangle(cornerRadius: 1.5).frame(width: 6.25, height: 15)
            RoundedRectangle(cornerRadius: 1.5).frame(width: 6.25, height: 15)
        }
        .foregroundStyle(Theme.Colors.textPrimary)
    }

    private var stopGlyph: some View {
        RoundedRectangle(cornerRadius: 1.875)
            .fill(Theme.Colors.recording)
            .frame(width: 15, height: 15)
    }

    private func bigControl<G: View>(_ label: String, action: @escaping () -> Void,
                                     @ViewBuilder glyph: () -> G) -> some View {
        Button(action: action) {
            // Figma 188:711 measured: icon box 25pt, label 5pt below it.
            VStack(spacing: 5) {
                glyph().frame(height: 25)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 106)
            .background(
                // No outline (removed per design); shadow carries the elevation.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Colors.surface)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func busyCard(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity).frame(height: 106)
        .background(
            // Match the 재생/멈춤 controls + file cards: shadow only, no outline.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Colors.surface)
                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
        )
    }

    // MARK: 총 시간 + speaker stats (Figma 188:673)

    // Ticks once a second while recording; frozen at the transcript's span
    // otherwise (file transcripts / reopened archives have no wall clock).
    private var totalTimeBlock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(totalTimeText)
                    .font(.system(size: 30)).monospacedDigit()
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("총 시간")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                // (CommitCadenceRing removed — the accent commit-cadence spinner
                // next to 총 시간 was dropped per de-accent / cleaner-live-UI.)
            }
        }
    }

    private var totalTimeText: String {
        let secs: Int
        if session.recordStartedAt != nil {
            // This session's wall clock (frozen at stop) — the transcript span
            // undercounts badly when most of the recording was silence.
            secs = Int(session.recordedSeconds)
        } else {
            // Reopened archive: no wall clock, the transcript span is all there is.
            let lines = session.transcript.lines
            secs = Int(max(0, (lines.map(\.end).max() ?? 0) - (lines.map(\.start).min() ?? 0)))
        }
        // Over an hour rolls into H:MM:SS (e.g. 1:45:07) instead of 105:07.
        if secs >= 3600 {
            return String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    /// 100% stacked speaker-share bar: ONE rounded segment per speaker, width ∝
    /// total talk time, sorted to match the share list below (largest first) so
    /// the list reads as this bar's legend. Fixed width by construction — the
    /// old time-ordered sequence bar grew a block per turn and needed horizontal
    /// scrolling; who-spoke-WHEN now lives in the energy flow's speaker colors,
    /// so this bar only answers "how much".
    private var speakerSequenceBar: some View {
        var times: [Int: Double] = [:]
        for l in session.transcript.lines { times[l.speaker, default: 0] += max(0, l.end - l.start) }
        let sorted = times.sorted { $0.value > $1.value }
        let total = max(0.001, times.values.reduce(0, +))
        let spacing: CGFloat = 2
        return GeometryReader { geo in
            let avail = max(geo.size.width - CGFloat(max(sorted.count - 1, 0)) * spacing, 1)
            HStack(spacing: spacing) {
                ForEach(sorted, id: \.key) { entry in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.Colors.speakerGradient(entry.key))
                        .frame(width: max(4, avail * CGFloat(entry.value / total)))
                        .help("\(SpeakerID.display(entry.key, names: session.speakerNames, fallback: "Speaker \(entry.key + 1)")) · \(Int((entry.value / total * 100).rounded()))%")
                }
            }
            .animation(.snappy(duration: 0.35), value: total)
        }
        .frame(height: 26)
        .help("발언 비율 — 화자별 점유")
    }

    private var speakerShareList: some View {
        var times: [Int: Double] = [:]
        for l in session.transcript.lines { times[l.speaker, default: 0] += max(0, l.end - l.start) }
        let total = max(0.001, times.values.reduce(0, +))
        let sorted = times.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(sorted, id: \.key) { entry in
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.Colors.speaker(entry.key)).frame(width: 6, height: 6)
                        Text(SpeakerID.display(entry.key, names: session.speakerNames, fallback: "Speaker \(entry.key + 1)"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(mmss(entry.value))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text("\(Int((entry.value / total * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1).fixedSize()
                        .frame(minWidth: 38, alignment: .trailing)
                        .padding(.leading, 3)   // Figma 188:689 time↔percent gap
                }
            }
        }
    }

    // saved-confirmation only — the auto-save folder config lives in Settings.
    private func savedStatus(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textSecondary)   // de-accent
            Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .font(Theme.Fonts.status).buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1).truncationMode(.middle).help("Finder에서 보기")
        }
    }

    // 타이튼 stat: removable filler + silence time. Editor info in the control
    // panel — never touches the clean transcript. Exports via the menu's CSV.
    private var tightenStatView: some View {
        let s = session.tightenStat
        return HStack(spacing: 6) {
            Image(systemName: "scissors").font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textSecondary)   // de-accent
            Text("타이튼: \(s.cuts)컷 · \(String(format: "%.0f", s.seconds))초 절감 가능")
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
        }
        .help("필러 + 무음 컷 목록을 내보내기 메뉴의 ‘타이튼 컷 목록 (.csv)’로 저장")
    }

    private func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // Shared title size for the side panel's section labels (언어 / 화자 수 /
    // 발언 시간 / …) — kept as one constant so they stay in lockstep.
    private var sidePanelTitleFont: Font { .system(size: 12, weight: .semibold, design: .rounded) }

    @ViewBuilder private func field<V: View>(_ label: String, labelFont: Font? = nil, @ViewBuilder _ control: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(labelFont ?? sidePanelTitleFont).foregroundStyle(Theme.Colors.textSecondary)
            control()
        }
    }

    // Calendar prefill: the live event's title + attendees. After the session,
    // attendees who never spoke are dimmed with a "발언 없음" mark.
    private func calendarBlock(_ ev: CalendarBridge.MeetingEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)   // de-accent
                Text(ev.title).font(Theme.Fonts.section).foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            if !ev.attendees.isEmpty {
                ForEach(ev.attendees, id: \.self) { name in
                    let absent = session.calendar.absent.contains(name)
                    HStack(spacing: 5) {
                        Circle().fill(absent ? Theme.Colors.textTertiary : Theme.Colors.accent)
                            .frame(width: 5, height: 5)
                        Text(name).font(Theme.Fonts.status)
                            .foregroundStyle(absent ? Theme.Colors.textTertiary : Theme.Colors.textSecondary)
                            .lineLimit(1)
                        if absent {
                            Text("발언 없음").font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private var recordButton: some View {
        switch session.phase {
        case .recording:
            HStack(spacing: 8) {
                pillButton("일시정지", icon: "pause.fill", fill: Theme.Colors.surfaceSunken, textColor: Theme.Colors.textPrimary) {
                    session.pauseRecording()
                }.keyboardShortcut("p")
                pillButton("정지", icon: "stop.fill", fill: Theme.Colors.recording, textColor: .white) {
                    session.stop()
                }.keyboardShortcut("r")
            }
        case .paused:
            HStack(spacing: 8) {
                pillButton("재개", icon: "record.circle.fill", fill: Theme.Colors.recording, textColor: .white) {
                    session.resumeRecording()
                }.keyboardShortcut("p")
                pillButton("정지", icon: "stop.fill", fill: Theme.Colors.surfaceSunken, textColor: Theme.Colors.textPrimary) {
                    session.stop()
                }.keyboardShortcut("r")
            }
        case .countingDown(let n):
            pillButton("시작까지 \(n)… (취소)", icon: "xmark.circle", fill: Theme.Colors.surfaceSunken, textColor: Theme.Colors.textPrimary) {
                session.cancelCountdown()
            }.keyboardShortcut(.cancelAction)
        case .engineStarting, .ready, .processing, .flushing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phaseText).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 25)
        default:
            // A loaded file occupies the session (Figma node 30:118: 30%-opacity
            // accent fill) — recording and file transcription are mutually exclusive.
            let fileLoaded = session.sourceMediaURL != nil
            pillButton("녹음 시작", icon: "play.fill",
                       fill: fileLoaded ? Theme.Colors.accent.opacity(0.3) : Theme.Colors.accent,
                       textColor: .white) {
                session.startCountdown()
            }
            .keyboardShortcut("r")
            .disabled(fileLoaded)
        }
    }

    // Slim accent pill (Figma node 28:203, "녹음 시작": rounded-40, height 21,
    // font 11 semibold) — replaces the native .borderedProminent button so all
    // recordButton states share one compact capsule shape.
    private func pillButton(_ title: String, icon: String, fill: Color, textColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10).padding(.vertical, 4).frame(height: 25)
            .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
    }

    // Pill-style dropdown (Figma node 28:363: bg #ECECEC pill, rounded-40,
    // height 25 (21 + 2px/side bump), and — 2px below — a tailless white panel
    // the EXACT width of the pill: rounded-7, hairline border (black 4%),
    // barely-there shadow (black 2%, y4 blur3.5). A manual overlay instead of
    // .popover/Menu: both force their own arrow/chevron and a much heavier
    // system shadow that doesn't match this spec.
    private func pillDropdown(_ text: String, isOpen: Binding<Bool>, width: Binding<CGFloat>, @ViewBuilder options: @escaping () -> some View) -> some View {
        Button { isOpen.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4).frame(height: 25)
            .background(
                Capsule().fill(Color(red: 0.925, green: 0.925, blue: 0.925))
                    .overlay(
                        GeometryReader { geo in
                            Color.clear.onAppear { width.wrappedValue = geo.size.width }
                                .onChange(of: geo.size.width) { _, w in width.wrappedValue = w }
                        }
                    )
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isOpen.wrappedValue {
                VStack(alignment: .leading, spacing: 0) { options() }
                    .padding(.vertical, 5)
                    .frame(width: width.wrappedValue, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.04)))
                    .shadow(color: Color.black.opacity(0.02), radius: 1.75, x: 0, y: 4)
                    .offset(y: 27)
            }
        }
    }

    // Dropdown row (Figma node 28:337): 10px black text, selected row shows a
    // small accent checkmark trailing.
    private func dropdownRow(_ text: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Prominent language selector — the deterministic fix for "spoke Korean,
    // got English": auto-detect can misfire on an ambiguous opening; picking
    // the language locks it. Persisted across launches.
    private var languagePicker: some View {
        let binding = Binding<Int?>(
            get: { session.languageTokenID },
            set: { session.languageTokenID = $0
                   UserDefaults.standard.set($0 ?? 0, forKey: "languageTokenID") }
        )
        let label = binding.wrappedValue == WhisperLang.ko ? "한국어"
            : binding.wrappedValue == WhisperLang.en ? "English" : "자동 감지"
        return pillDropdown(label, isOpen: $languagePickerOpen, width: $languagePickerWidth) {
            dropdownRow("자동 감지", selected: binding.wrappedValue == nil) { binding.wrappedValue = nil; languagePickerOpen = false }
            dropdownRow("한국어", selected: binding.wrappedValue == WhisperLang.ko) { binding.wrappedValue = WhisperLang.ko; languagePickerOpen = false }
            dropdownRow("English", selected: binding.wrappedValue == WhisperLang.en) { binding.wrappedValue = WhisperLang.en; languagePickerOpen = false }
        }
        .disabled(isBusy)
    }

    private var meetingModePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            pillDropdown(session.meetingMode.label, isOpen: $meetingModePickerOpen, width: $meetingModePickerWidth) {
                ForEach(MeetingMode.allCases) { mode in
                    dropdownRow(mode.label, selected: mode == session.meetingMode) {
                        session.meetingMode = mode; meetingModePickerOpen = false
                    }
                }
            }
            .disabled(isBusy || isRecordingLike)
            .zIndex(1)
            Text(session.meetingMode.config.mode.summaryDescription)
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    // 화자 수 고정 — 자동/1/2/3/4명 이상. Maps to the engine's DIAR_MAXK cap.
    private var speakerCountPicker: some View {
        pillDropdown(session.speakerCount.label, isOpen: $speakerCountPickerOpen, width: $speakerCountPickerWidth) {
            ForEach(SpeakerCount.allCases) { c in
                dropdownRow(c.label, selected: c == session.speakerCount) { session.speakerCount = c; speakerCountPickerOpen = false }
            }
        }
        .disabled(isBusy)
    }

    // Visible drop target + an explicit "Choose File…" button so file input is
    // discoverable without knowing about drag-&-drop. (Figma node 28:203)
    private var dropZone: some View {
        VStack(spacing: 5) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 19))
                .foregroundStyle(dropTargeted ? Theme.Colors.accent : Theme.Colors.textTertiary)
            Text("오디오 영상 파일\n드래그 앤 드롭")
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Colors.textSecondary)
            Button { chooseFile() } label: {
                Text("파일 선택")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.Colors.meterTrack))
            }
            .buttonStyle(.plain).disabled(!canDrop)
        }
        .frame(maxWidth: .infinity).frame(height: 107)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Theme.Colors.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(dropTargeted ? Theme.Colors.accent : Theme.Colors.textTertiary,
                          style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
    }

    // Loaded-file chip (Figma node 30:118) — replaces dropZone once a file is
    // staged/transcribing. X cancels (terminates an in-flight file engine too)
    // and returns to the empty drop zone.
    private var loadedFileChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill").font(.system(size: 13))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(session.fileName)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button { session.cancelFile() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Colors.surfaceSunken))
    }

    private var exportMenu: some View {
        Menu {
            Button("Markdown (.md)") { export(.init(filenameExtension: "md")!, session.exportMarkdown) }
            Button("Subtitles (.srt)") { export(.init(filenameExtension: "srt")!, session.exportSRT) }
            Button("Subtitles (.vtt)") { export(.init(filenameExtension: "vtt")!, session.exportVTT) }
            Button("Plain text (.txt)") { export(.plainText, session.exportText) }
            Button("JSON (.json)") { export(.json, session.exportJSON) }
            Divider()
            Button("타이튼 컷 목록 (.csv)") { export(.commaSeparatedText, session.exportCutList) }
            Button("유튜브 챕터 (.txt)") { export(.plainText, session.exportChapters) }
        } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(session.transcript.lines.isEmpty)
    }

    // MARK: helpers

    private var canDrop: Bool {
        switch session.phase { case .idle, .done, .error: return true; default: return false }
    }
    private var isBusy: Bool {
        switch session.phase { case .idle, .done, .error: return false; default: return true }
    }
    private var isCountingDown: Bool {
        if case .countingDown = session.phase { return true }; return false
    }
    // recording or paused → the last line is still in progress (don't edit it yet)
    private var isRecordingLike: Bool {
        session.phase == .recording || session.phase == .paused
    }

    /// Gradient WARNING row (Figma 260:1316): silence takes priority; otherwise
    /// the 누락 의심/복구 summary (which is expandable via coverageGapTimes).
    private var transcriptWarning: String? {
        if session.micSilent { return "소리가 감지되지 않아요 — 마이크를 확인해주세요" }
        var parts: [String] = []
        if !session.coverageGaps.isEmpty { parts.append("누락 의심 \(session.coverageGaps.count)구간") }
        if session.hangRecoveries > 0 { parts.append("복구 \(session.hangRecoveries)회") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// mm:ss of each suspected-missing segment — expands under the warning row.
    /// (Empty while silence is the active warning, so that row stays non-expandable.)
    private var coverageGapTimes: [String] {
        guard !session.micSilent else { return [] }
        return session.coverageGaps.sorted().map { secs in
            let s = Int(secs); return String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    /// Dimmed ACTIVITY row (loading dots): what a stage is doing right now.
    /// The activity row is a pure rendering of the session's pipeline state
    /// machine (Phase 4) — no signal-priority logic lives in the view anymore.
    private var transcriptActivity: String? {
        switch session.pipeline {
        case .diarizing:                 "AI가 화자·언어를 검토하는 중"
        case .fileTranscribing(let pct): pct.map { "파일 전사 중 · \($0)%" } ?? "파일 전사 중"
        case .translating(let n):        "번역 중 · \(n)줄 대기"
        case .translatingBacklogged:     "말이 빨라 번역이 밀렸어요 · 정지 후 자동으로 채워요"
        case .transcribing:              "전사 중"
        case .listening:                 "듣는 중"
        case .backfilling(let n):        "번역 채우는 중 · \(n)줄 남음"
        case .idle, .completed, .error:  nil   // error surfaces via phase UI, silence via warning row
        }
    }
    // accept anything the system recognizes as audio or audiovisual media (104+
    // types) — not a hardcoded extension list. Unknown extensions are let through
    // and AudioDecode surfaces a clear error if they can't actually be decoded.
    private func isMediaFile(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return true }
        // audio + video containers (mp4/mov/m4v/webm/mkv…) — AudioDecode extracts
        // the audio track from any AVFoundation-decodable file.
        return t.conforms(to: .audio) || t.conforms(to: .audiovisualContent)
            || t.conforms(to: .movie) || t.conforms(to: .video)
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .audiovisualContent, .movie, .video]
        if panel.runModal() == .OK, let url = panel.url { session.transcribeFile(url) }
    }
    private func export(_ type: UTType, _ writer: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.directoryURL = session.autoSaveFolder      // default to the left-panel workspace folder
        panel.nameFieldStringValue = exportBaseName
        if panel.runModal() == .OK, let url = panel.url { try? writer(url) }
    }
    /// Default export filename — the auto-saved meeting name / source file / title,
    /// so a manual export lands beside the workspace's other files with a real name.
    private var exportBaseName: String {
        if let saved = session.lastAutoSaved { return saved.deletingPathExtension().lastPathComponent }
        let f = (session.fileName as NSString).deletingPathExtension
        if !f.isEmpty { return f }
        return session.meetingTitle ?? "transcript"
    }

    private var phaseText: String {
        switch session.phase {
        case .idle: "준비됨"
        case .countingDown(let n): "\(n)초 후 시작…"
        case .engineStarting: "모델 로딩…"
        case .ready: "마이크 시작…"
        case .recording: "녹음 중"
        case .paused: "일시정지"
        case .processing: "파일 전사 중…"
        case .flushing: "마무리…"
        case .done: "완료"
        case .error(let m): "오류: \(m)"
        }
    }
}

// FigmaCheckboxToggleStyle — 14x14 rounded-3px box (Figma nodes 28:41 / 28:45,
// +2px over spec per follow-up feedback): off = flat #D9D9D9, on =
// Theme.Colors.accent with a small white checkmark.
struct FigmaCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Button { configuration.isOn.toggle() } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? Theme.Colors.accent : Color(red: 0.851, green: 0.851, blue: 0.851))
                    .frame(width: 14, height: 14)
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            configuration.label
        }
    }
}

/// W3: one-line pipeline status — listening / transcribing / translating /
/// AI-reviewing / suspected misses / hang recoveries. Turns the invisible
/// background stages into a glanceable answer to "지금 뭘 하는 중이지?".

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.meterTrack)
                Capsule().fill(Theme.Colors.meterFill)
                    .frame(width: geo.size.width * CGFloat(min(1, level)))
            }
        }
    }
}

// Grabs the hosting NSWindow so ContentView can resize it imperatively (compact
// "Set to start" frame ↔ expanded working layout). onResolve fires once the view
// is in a window and again on updates; callers de-dupe by tracking mode.
/// Suppresses the macOS 26 "hard" scroll-edge hairline at the top of a scroll
/// view sitting under the transparent titlebar (it reads as a header divider).
/// No-op on earlier macOS, where the hairline never appears.
private struct HideTopScrollEdgeHairline: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in if let w = v?.window { onResolve(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in if let w = nsView?.window { onResolve(w) } }
    }
}

// Ring countdown digit (user reference): a faint track + an accent arc that
// sweeps one full lap (0→1) over each 1s tick, then the Semibold number ticks
// down. The sweep resets instantly (disabled transaction) at each new number so
// every second starts a fresh lap.
/// D19: a small ring filling toward the next expected commit (elapsed since the
/// last commit / window length). TimelineView animates it without a manual timer;
/// it saturates at 1.0 and holds (a decode may run past the nominal window).
struct CommitCadenceRing: View {
    let since: Date
    let window: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(since)
            let p = window > 0 ? min(1.0, max(0.0, elapsed / window)) : 0
            ZStack {
                Circle().stroke(Theme.Colors.meterTrack, lineWidth: 2)
                Circle().trim(from: 0, to: p)
                    .stroke(Theme.Colors.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .help("다음 확정까지 진행도")
        }
    }
}
