// ContentView.swift — main window: model gate, transcript (left, fills window),
// and a right control panel (record / language / mic / file drop).

import SwiftUI
import AppKit
import CoreAudio
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader
    @State private var dropTargeted = false
    // Default to the clean reading view — general users just want the content.
    // The detailed (timecode + confidence + overlap) view is one tap away.
    @AppStorage("transcriptViewMode") private var contentMode = true
    // C18: opt-in two-party chat layout (staff left / patient right). Only
    // meaningful with exactly two speakers — the toggle hides otherwise.
    @AppStorage("transcriptChatLayout") private var chatLayout = false
    private var twoSpeakers: Bool { Set(session.transcript.lines.map { $0.speaker }).count == 2 }
    private var viewMode: TranscriptViewMode {
        if chatLayout && twoSpeakers { return .chat }
        return contentMode ? .content : .detailed
    }
    // Transcript text size (pt) — readable default, A−/A+ in the bar. Persisted.
    @AppStorage("transcriptFontSize") private var fontSize = 18.0
    // IDE-style workspace explorer (save folder as a file tree) on the right.
    @AppStorage("showWorkspaceExplorer") private var showExplorer = true
    // N2 review navigator (상세 mode): step through low-confidence words.
    @State private var reviewIndex = 0
    // N2 listen-to-review: auto-plays each low-confidence word's audio in sequence.
    @State private var review = ReviewController()
    @State private var scrollTarget: UUID? = nil
    @State private var scrollTick = 0
    @State private var transcriptScrolled = false   // top fade shows only when scrolled
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
            switch downloader.state {
            case .ready:
                ZStack {
                    if showSetToStart {
                        setToStartCard
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else {
                        mainLayout
                            .transition(.opacity)
                    }
                }
                .animation(.snappy(duration: 0.32), value: showSetToStart)
            default: ModelGateView(downloader: downloader)
            }
        }
        .background(WindowAccessor { w in
            if appWindow !== w { appWindow = w }
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
            // Fixed frame — the card IS the window (Figma rev.2 is a wide
            // two-column card). Matches the expanded working-layout size below
            // so 시작하기 doesn't resize the window, just swaps the content.
            // Title text hidden so the wordmark in the content reads as branding.
            content = NSSize(width: min(1150, vis.width - 60), height: min(710, vis.height - 60))
            w.styleMask.remove(.resizable)
            w.contentMinSize = content
            w.contentMaxSize = content
            w.titleVisibility = .hidden
        } else {
            // Expanded working layout — free resize again.
            w.styleMask.insert(.resizable)
            w.contentMinSize = NSSize(width: 760, height: 520)
            w.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            content = NSSize(width: min(1150, vis.width - 60), height: min(710, vis.height - 60))
            w.titleVisibility = .visible
        }
        let frameSize = w.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        var frame = w.frame
        // Keep the window centered on its current screen through the transition.
        frame.origin.x = vis.midX - frameSize.width / 2
        frame.origin.y = vis.midY - frameSize.height / 2
        frame.size = frameSize
        w.setFrame(frame, display: true, animate: animate)
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
                Image(systemName: "sparkles").foregroundStyle(Theme.Colors.accent)
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
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.accent.opacity(0.06)))
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
            if case .processing = session.phase { progressBanner }
            if session.micSilent { silenceBanner }
            if !session.transcript.lines.isEmpty { viewModeBar }
            // W3: pipeline status chips — what the invisible stages are doing
            // RIGHT NOW. Same row grammar/insets as viewModeBar above.
            if isRecordingLike {
                pipelineHUD
                    .padding(.leading, 21).padding(.trailing, 16).padding(.vertical, 4)
            }
            if session.reconciling || session.reconcileNote != nil { reconcileBar }
            if viewMode == .detailed && !flaggedWords.isEmpty { reviewBar }
            // (Speaker timeline moved into the left panel's sequence bar —
            // Figma 188:662 has no timeline card above the transcript.)
            ZStack {
                if session.transcript.lines.isEmpty {
                    emptyState
                } else {
                    TranscriptView(lines: session.transcript.lines, names: session.speakerNames,
                                   autoRecognizedSpeakers: session.autoRecognizedSpeakers,
                                   mode: viewMode,
                                   onRename: { session.renameSpeaker($0, to: $1) },
                                   scrollTarget: scrollTarget, scrollTick: scrollTick,
                                   focusedLine: scrollTarget,
                                   interim: session.livePartial,
                                   interimTranslations: session.livePartialTranslations,
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
                if case .countingDown(let n) = session.phase { countdownOverlay(n) }
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
                session.reset()
            } label: {
                Text("새 기록 시작")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 136/255, green: 156/255, blue: 255/255))  // #889CFF
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
            // D20: translation backlog — distinguishes "밀림" from "고장".
            if isRecordingLike, session.translateQueueDepth > 0 {
                Label("\(session.translateQueueDepth)줄 번역 대기", systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundStyle(Theme.Colors.textTertiary)
                    .help("대기 중인 번역 턴 수 (엔진이 한 번에 하나씩 처리)")
            }
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
            // C18: chat layout toggle (two-party only)
            if twoSpeakers {
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

    // N2 review queue (상세 mode only): step through low-confidence words so the
    // reviewer doesn't have to scan a long transcript for the amber ones.
    /// W3: pipeline status chips (recording only).
    @ViewBuilder private var pipelineHUD: some View {
        HStack(spacing: 5) {
            if session.level > 0.02 {
                HUDChip(icon: "waveform", text: "듣는 중", tint: Theme.Colors.meterFill)
            }
            if session.segmentsInFlight > 0 {
                HUDChip(icon: "text.viewfinder", text: "전사 \(session.segmentsInFlight)", tint: Theme.Colors.accent, pulsing: true)
            }
            if session.translateQueueDepth > 0 {
                HUDChip(icon: "globe", text: "번역 \(session.translateQueueDepth)", tint: Theme.Colors.accent, pulsing: true)
            }
            if session.reconciling {
                HUDChip(icon: "wand.and.stars", text: "AI 검토", tint: Theme.Colors.accent, pulsing: true)
            }
            if !session.coverageGaps.isEmpty {
                HUDChip(icon: "exclamationmark.triangle", text: "누락 의심 \(session.coverageGaps.count)", tint: Theme.Colors.lowConf)
                    .help("음성이 있었는데 전사가 비어 재시도 후에도 실패한 구간")
            }
            if session.hangRecoveries > 0 {
                HUDChip(icon: "arrow.clockwise", text: "복구 \(session.hangRecoveries)", tint: Theme.Colors.lowConf)
                    .help("엔진이 멈춰 자동 재시작·재공급한 횟수 (오디오 무손실)")
            }
            Spacer(minLength: 0)
        }
    }

    /// Post-session AI correction status + one-tap undo of speaker changes.
    private var reconcileBar: some View {
        HStack(spacing: 10) {
            if session.reconciling {
                ProgressView().controlSize(.small)
                Text("AI가 화자·언어를 검토하는 중…").font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else if let note = session.reconcileNote {
                Image(systemName: "wand.and.stars").font(.system(size: 12)).foregroundStyle(Theme.Colors.accent)
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
        .background(Theme.Colors.accent.opacity(0.06))
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

    // determinate file-transcription progress: filename + chunk bar (driven by
    // the engine's "→ N chunk(s)" + per-chunk "[perf]" lines)
    private var progressBanner: some View {
        let done = session.chunksDone, total = session.chunksTotal
        let frac = total > 0 ? Double(done) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("전사 중 — \(session.fileName)").font(Theme.Fonts.body).lineLimit(1)
                Spacer()
                if total > 0 {
                    Text("\(done)/\(total) 청크 · \(Int(frac * 100))%")
                        .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            if total > 0 {
                ProgressView(value: frac).tint(Theme.Colors.accent)
            } else {
                ProgressView(value: 0).tint(Theme.Colors.accent)   // model loading / first chunk
                    .opacity(0.4)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.Colors.accent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.Space.window)
        // top gap matches the 12pt inset the side panels (explorer/control
        // panel) start with from the window's top edge, so this card's top
        // doesn't sit flush against the very top while its neighbors don't.
        .padding(.top, 12).padding(.bottom, 5)
    }

    // Dead-mic warning (B안): shows after 15s of recording with no audible input
    // — the energy graph's live edge going flat is the soft signal; this banner
    // is the loud one. Clears itself as soon as sound returns.
    private var silenceBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(Theme.Colors.lowConf)
            Text("소리가 감지되지 않아요 — 마이크 입력을 확인해주세요")
                .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.Colors.lowConf.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.Space.window)
        .padding(.top, 12).padding(.bottom, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if case .processing = session.phase {
                haloIcon("waveform.badge.magnifyingglass")
                Text("전사 결과가 곧 여기에 표시됩니다…")
                    .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
            } else if case .error(let msg) = session.phase {
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
            } else if isBusy {
                ProgressView()
                Text(phaseText).font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
            } else {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // #4 — full-pane countdown: a big, calm number that ticks 3·2·1 before the
    // mic opens. Dimmed scrim so it reads as a moment of "getting ready".
    // Ring countdown (user ref): an accent arc sweeps one full lap around the
    // number each second, then the digit ticks down. Semibold number, accent
    // purple ring.
    private func countdownOverlay(_ n: Int) -> some View {
        ZStack {
            Theme.Colors.surface
            CountdownRingView(n: n)
        }
        .transition(.opacity)
    }

    // soft accent halo behind a glyph — warm, calm focal point for empty/idle states
    private func haloIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(Theme.Colors.accent)
            .frame(width: 88, height: 88)
            .background(Circle().fill(Theme.Colors.accent.opacity(0.10)))
    }

    // MARK: — Set to start (Figma 113:391) — pre-start config card

    // Redesign chip/CTA/track colors, now routed through adaptive Theme tokens so
    // dark mode works (was hardcoded light-mode literals). chipInk = the monochrome
    // selected-chip / primary-CTA fill (inverts for dark); chipInkOn = its glyph.
    private static let chipInk = Theme.Colors.inkStrong
    private static let chipInkOn = Theme.Colors.inkStrongOn
    private static let optionalOrange = Color(red: 217/255, green: 78/255, blue: 0/255)  // brand/700, reads on both
    private static let dashBorder = Theme.Colors.separator      // dashed drop-zone border
    private static let dropZoneGray = Theme.Colors.textSecondary // file-size subtitle / drop icon
    private static let controlSubtle = Theme.Colors.surfaceSunken // sunken control fill (파일 선택 pill)

    // Two-column "Set to start" (Figma 113:391, rev.2): 최근 항목 (recent
    // transcripts, tap to reopen) | divider | 시작하기 (chips + file + CTA).
    // The card fills the compact window; the wordmark sits top-left like a
    // titlebar item.
    private var setToStartCard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // Centered wordmark reads as the app's title (Figma 209:1523).
                BrandLogo(width: 118)
                    .padding(.top, 40)
                // .top keeps the two headings level; recentColumn + divider
                // stretch to startColumn's (taller) height so the 자동저장 block
                // bottom-aligns with the CTA buttons across both columns.
                HStack(alignment: .top, spacing: 77) {
                    recentColumn
                    Rectangle().fill(Theme.Colors.surfaceSunken)
                        .frame(width: 1).frame(maxHeight: .infinity)
                    startColumn
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 34).padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surface)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: isMediaFile) else { return false }
            stagedFile = u; return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var recentColumn: some View {
        VStack(spacing: 40) {
            Text("최근 항목")
                .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    if recentTranscripts.isEmpty {
                        Text("저장된 기록이 없습니다")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    } else {
                        ForEach(recentTranscripts, id: \.url) { item in
                            Button { session.openArchived(item.url) } label: {
                                HStack(spacing: 7) {
                                    SVGIcon(name: "content", size: 18)
                                    Text(item.url.lastPathComponent)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(relativeAge(item.date))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 24)
                recentBottomBlock
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 318)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Below the recent list (Figma 209:1488): a divider, 자동저장 toggle, and
    // 폴더 location + 변경 — the same autosave controls the working layout's
    // right panel exposes, surfaced up front on the start screen.
    private var recentBottomBlock: some View {
        VStack(spacing: 18) {
            Rectangle().fill(Theme.Colors.surfaceSunken).frame(height: 1)
            HStack {
                Text("자동저장")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                autoSaveToggle
            }
            HStack(spacing: 6) {
                Text("폴더")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                Text(session.autoSaveFolder.lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(session.autoSaveFolder.path)
                Spacer()
                Button("변경") { chooseAutoSaveFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
            }
        }
        .padding(.bottom, 20)  // QA: 저장세팅영역 아래 여백 20px
    }

    // Custom black pill toggle (Figma 209:1493) — the system .switch tints blue
    // and its track sits inset from the frame edge, so it read as detached from
    // the list's right edge. BlackToggle right-aligns exactly and matches the
    // wordmark's black ON state (shared with the right panel's autosave toggle).
    private var autoSaveToggle: some View {
        BlackToggle(isOn: $session.autoSaveEnabled)
    }

    private func chooseAutoSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.autoSaveFolder
        if panel.runModal() == .OK, let url = panel.url { session.autoSaveFolder = url }
    }

    private var startColumn: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("시작하기")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                Text("회의 정보를 설정하면 더 정확한 결과를 얻을 수 있어요")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 20) {
                    setupBlock("언어") { languageChips }
                    setupBlock("회의 모드") { meetingChips }
                    setupBlock("화자") { speakerChips }
                    setupBlock("파일 선택", optional: true) { setupDropZone }
                }
                ctaButtons
            }
        }
        .frame(width: 318)
    }

    /// Newest transcripts across the whole workspace tree, for the 최근 항목
    /// column. Modification date (not name) orders them; capped at 5.
    private var recentTranscripts: [(url: URL, date: Date)] {
        var mds: [URL] = []
        func walk(_ nodes: [FileNode]) {
            for n in nodes {
                if let kids = n.children { walk(kids) }
                else if n.isTranscript { mds.append(n.url) }
            }
        }
        walk(session.workspace.nodes)
        let fm = FileManager.default
        let dated: [(url: URL, date: Date)] = mds.compactMap { u in
            guard let d = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
            else { return nil }
            return (url: u, date: d)
        }
        return Array(dated.sorted { $0.date > $1.date }.prefix(5))
    }

    private func relativeAge(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private var languageChips: some View {
        HStack(spacing: 4) {
            setupChip("자동", selected: session.languageTokenID == nil) { setLanguage(nil) }
            setupChip("EN", selected: session.languageTokenID == WhisperLang.en) { setLanguage(WhisperLang.en) }
            setupChip("KR", selected: session.languageTokenID == WhisperLang.ko) { setLanguage(WhisperLang.ko) }
        }
    }

    private func setLanguage(_ id: Int?) {
        session.languageTokenID = id
        UserDefaults.standard.set(id ?? 0, forKey: "languageTokenID")
    }

    @ViewBuilder
    private func setupBlock<V: View>(_ title: String, optional: Bool = false, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
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

    // rev.2 chip: selected = solid #141616/white·semibold, unselected = white
    // fill with a hairline #f2f2f7 border·medium (was a gray fill in rev.1).
    private func setupChip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Self.chipInkOn : Theme.Colors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Self.chipInk : Theme.Colors.surface))
                .overlay(Capsule().strokeBorder(
                    selected ? Self.chipInk : Theme.Colors.surfaceSunken, lineWidth: 1))
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
                    SVGIcon(name: "folder", size: 24, tint: nil)   // baked indigo (#5A67D8)
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
            .frame(maxWidth: .infinity).frame(height: 125)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Colors.surface)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Colors.separator, lineWidth: 1))
        } else {
            // Before upload (Figma 216:1827): dashed box, folder-plus prompt + pill.
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    SVGIcon(name: "folder-plus", size: 24)
                    Text("파일 드래그 앤 드롭")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                Button { chooseStagedFile() } label: {
                    Text("파일 선택")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Self.controlSubtle))
                }.buttonStyle(.plain).disabled(!canDrop)
            }
            .frame(maxWidth: .infinity).frame(height: 125)
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

    // rev.2: the two CTAs sit side by side, equal width (파일로 dim-disabled
    // until a file is staged; staging flips which one is active).
    private var ctaButtons: some View {
        HStack(spacing: 8) {
            setupCTA("파일로 시작하기", enabled: stagedFile != nil) {
                if let u = stagedFile { stagedFile = nil; session.transcribeFile(u) }
            }
            setupCTA("라이브로 시작하기", enabled: stagedFile == nil) {
                session.startCountdown()
            }
        }
    }

    private func setupCTA(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Self.chipInkOn : .white)
                .frame(maxWidth: .infinity).frame(height: 40)
                // disabled = solid meterTrack gray fill (10% ghost swallowed the
                // white label; this keeps the text visible on a grayed button).
                .background(Capsule().fill(enabled ? Self.chipInk : Theme.Colors.meterTrack))
        }
        .buttonStyle(.plain)
        // .allowsHitTesting (not .disabled) so the white label keeps full opacity —
        // .disabled applies the system dim that grayed the text out.
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

            Rectangle().fill(Theme.Colors.surfaceSunken).frame(height: 1)
                .padding(.horizontal, 16).padding(.top, 22)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    totalTimeBlock
                        .padding(.top, 18)
                    if !session.transcript.lines.isEmpty {
                        speakerSequenceBar.padding(.top, 20)
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
            HStack(spacing: 12) {
                bigControl("일시 정지", action: { session.pauseRecording() }) { pauseGlyph }
                    .keyboardShortcut("p")
                bigControl("정지", action: { session.stop() }) { stopGlyph }
                    .keyboardShortcut("r")
            }
        case .paused:
            HStack(spacing: 12) {
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
                SVGIcon(name: "folder", size: 24, tint: nil)   // baked indigo (#5A67D8)
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
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Colors.surface)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Colors.separator, lineWidth: 1))
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Colors.surface)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.Colors.separator, lineWidth: 1))
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Colors.surface)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1))
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
                // D19: progress toward the next expected commit — turns the
                // "왜 멈춰있지?" wait into a predictable one (translate mode).
                if session.phase == .recording, !session.translateTargets.isEmpty {
                    CommitCadenceRing(since: session.lastCommitAt,
                                      window: session.effectiveWindowSeconds)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
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

    /// Single-lane who-spoke-when bar: consecutive lines by the same speaker
    /// merge into one rounded block, widths ∝ talk time (Figma 188:677), each
    /// floored at 10pt. The scroll surface runs EDGE TO EDGE of the card (it
    /// escapes the panel's 16pt inset) so overflowing blocks slide under the
    /// card edge instead of chopping at an arbitrary inner line; the content
    /// keeps its own 16pt margins, and every new committed turn auto-anchors
    /// the newest block 16pt from the right edge with a smooth animation.
    private var speakerSequenceBar: some View {
        let segs = speakerSegments
        let total = max(segs.reduce(0) { $0 + $1.dur }, 0.001)
        let minW: CGFloat = 10
        let spacing: CGFloat = 2
        return GeometryReader { geo in
            let inner = max(geo.size.width - 32, 1)   // resting width between the 16pt margins
            let gaps = CGFloat(max(segs.count - 1, 0)) * spacing
            let avail = max(inner - gaps, 1)
            let widths = segs.map { max(minW, avail * CGFloat($0.dur / total)) }
            let contentW = widths.reduce(0, +) + gaps
            let overflowing = contentW > inner + 0.5
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // 16pt margins live INSIDE as spacers: the trailing spacer is
                    // itself the scroll anchor, so aligning it to the viewport
                    // edge leaves the newest block exactly 16pt from the right —
                    // rather than jammed against the card edge.
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 16)
                        HStack(spacing: spacing) {
                            ForEach(segs.indices, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.Colors.speaker(segs[i].speaker))
                                    .frame(width: widths[i])
                            }
                        }
                        Color.clear.frame(width: 16).id("seqEnd")
                    }
                    .animation(.snappy(duration: 0.35), value: contentW)
                }
                .scrollDisabled(!overflowing)
                .onAppear { proxy.scrollTo("seqEnd", anchor: .trailing) }
                .onChange(of: contentW) { _, _ in
                    withAnimation(.snappy(duration: 0.35)) {
                        proxy.scrollTo("seqEnd", anchor: .trailing)
                    }
                }
            }
            // Left fade: hints that earlier turns exist off the left edge once
            // the bar overflows (the newest turns stay pinned at the right).
            .overlay(alignment: .leading) {
                if overflowing {
                    LinearGradient(colors: [Theme.Colors.surface, Theme.Colors.surface.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 22)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, -16)   // escape the panel inset → card-edge-wide scroll surface
        .help("발언 순서 — 화자별 발언 구간")
    }

    private var speakerSegments: [(speaker: Int, dur: Double)] {
        var out: [(speaker: Int, dur: Double)] = []
        for l in session.transcript.lines {
            let d = max(0, l.end - l.start)
            if let last = out.last, last.speaker == l.speaker {
                out[out.count - 1].dur += d
            } else {
                out.append((speaker: l.speaker, dur: d))
            }
        }
        return out
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
                        Text(session.speakerNames[entry.key] ?? "Speaker \(entry.key + 1)")
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
                .foregroundStyle(Theme.Colors.accent)
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
                .foregroundStyle(Theme.Colors.accent)
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
                Image(systemName: "calendar").font(Theme.Fonts.status).foregroundStyle(Theme.Colors.accent)
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
private struct HUDChip: View {
    let icon: String
    let text: String
    var tint: Color = Theme.Colors.textSecondary
    var pulsing = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.1)))
        .opacity(pulsing ? 0.85 : 1)
    }
}

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
private struct CountdownRingView: View {
    let n: Int
    @State private var sweep: CGFloat = 0

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(Theme.Colors.separator, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(Theme.Colors.accent,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))   // start the lap at 12 o'clock
                Text("\(n)")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.3), value: n)
            }
            .frame(width: 87, height: 87)
            Text("곧 녹음을 시작합니다")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .onAppear { runSweep() }
        .onChange(of: n) { _, _ in runSweep() }
    }

    private func runSweep() {
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { sweep = 0 }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 1.0)) { sweep = 1 }
        }
    }
}

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
