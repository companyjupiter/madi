// ContentView.swift — main window: model gate, transcript (left, fills window),
// and a right control panel (record / language / mic / file drop).

import SwiftUI
import CoreAudio
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader
    @State private var dropTargeted = false
    // Default to the clean reading view — general users just want the content.
    // The detailed (timecode + confidence + overlap) view is one tap away.
    @AppStorage("transcriptViewMode") private var contentMode = true
    private var viewMode: TranscriptViewMode { contentMode ? .content : .detailed }
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
            case .ready: mainLayout
            default: ModelGateView(downloader: downloader)
            }
        }
    }

    // transcript fills the window; a fixed control panel sits on the right
    private var mainLayout: some View {
        ZStack {
            HStack(spacing: 0) {
                if showExplorer {
                    WorkspaceExplorer(session: session, isVisible: $showExplorer)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                transcriptPane
                sidePanel
            }
            .animation(.snappy, value: showExplorer)
            .background(Theme.Colors.surfaceSunken)
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
            if case .processing = session.phase { progressBanner }
            if !session.transcript.lines.isEmpty { viewModeBar }
            if viewMode == .detailed && !flaggedWords.isEmpty { reviewBar }
            if !session.transcript.lines.isEmpty {
                TimelineScrubberView(
                    lines: session.transcript.lines,
                    speakerNames: session.speakerNames,
                    onSeek: { id in scrollTarget = id; scrollTick += 1 }
                )
                .padding(.horizontal, Theme.Space.window)
                .padding(.bottom, Theme.Space.lineInner)
            }
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
                                   onEdit: { session.editLine($0, to: $1) },
                                   lockedLineID: isRecordingLike ? session.transcript.lines.last?.id : nil,
                                   onRequestDetailed: { contentMode = false },
                                   onPlay: session.sourceMediaURL != nil ? { session.playLine($0) } : nil,
                                   playingLine: session.linePlayer.currentLine)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // 내용/상세 toggle — keeps the clean reading view (default) free of the
    // editor/review detail. Persisted across launches via @AppStorage.
    private var viewModeBar: some View {
        HStack(spacing: 10) {
            // #3 — new session: clear the transcript without the stop→start dance.
            // Only when not actively capturing (idle / done / error).
            if !isBusy {
                Button { session.reset() } label: {
                    Label("초기화", systemImage: "arrow.counterclockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.Colors.textSecondary)
                .help("전사 내용을 지우고 새 회의를 시작합니다")
                Divider().frame(height: 14)
                // on-device meeting summary + action items (local LLM)
                if AssetManifest.translateAvailable {
                    Button { session.summarize(); showSummary = true } label: {
                        Label("요약", systemImage: "sparkles").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Colors.accent)
                    .help("로컬 LLM으로 회의 요약·액션아이템 생성 (기기 밖으로 안 나감)")
                    Divider().frame(height: 14)
                }
            }
            // text-size: A− / current pt / A+
            Button { fontSize = max(12, fontSize - 2) } label: { Text("A").font(.system(size: 11)) }
                .buttonStyle(.plain).help("글자 작게")
            Text("\(Int(fontSize))").font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary).monospacedDigit()
            Button { fontSize = min(34, fontSize + 2) } label: { Text("A").font(.system(size: 17)) }
                .buttonStyle(.plain).help("글자 크게")
            Spacer()
            Picker("", selection: $contentMode) {
                Text("내용").tag(true)
                Text("상세").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("내용: 깨끗한 회의록 보기 · 상세: 시각·신뢰도·겹침 표시")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    // N2 review queue (상세 mode only): step through low-confidence words so the
    // reviewer doesn't have to scan a long transcript for the amber ones.
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
        .overlay(alignment: .bottom) { Divider() }
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
        .overlay(alignment: .bottom) { Divider() }
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
            } else if isBusy {
                ProgressView()
                Text(phaseText).font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
            } else {
                haloIcon("waveform")
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
    private func countdownOverlay(_ n: Int) -> some View {
        ZStack {
            Theme.Colors.surfaceSunken.opacity(0.86)
            VStack(spacing: 14) {
                Text("\(n)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.accent)
                    .contentTransition(.numericText(countsDown: true))
                    .id(n)
                    .transition(.scale.combined(with: .opacity))
                Text("곧 녹음을 시작합니다…")
                    .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .animation(.snappy, value: n)
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

    // MARK: right control panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.panelGap) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                Text("Madi").font(Theme.Fonts.appTitle).foregroundStyle(Theme.Colors.brandMark)
                Spacer()
                Button { showExplorer.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 14)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(showExplorer ? Theme.Colors.accent : Theme.Colors.textSecondary)
                    .help("작업 폴더 탐색기")
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.Colors.textSecondary)
                    .help("설정 (⌘,)")
            }

            VStack(alignment: .leading, spacing: 10) {
                recordButton
                if session.phase == .recording || session.phase == .paused {
                    LevelMeter(level: session.level).frame(height: Theme.Size.meterH)
                        .opacity(session.phase == .paused ? 0.4 : 1)
                }
            }

            if let ev = session.calendar.event { calendarBlock(ev) }

            if SessionController.liveRailCapable, session.liveRailEnabled,
               isRecordingLike || !session.liveRailItems.isEmpty {
                Divider().overlay(Theme.Colors.separator)
                LiveActionRailView(items: session.liveRailItems, extracting: session.liveRailBusy)
            }

            if session.liveCoachEnabled,
               isRecordingLike || !(session.prepBriefData?.isEmpty ?? true) {
                Divider().overlay(Theme.Colors.separator)
                // Render the cached snapshot (recomputed on a ~1Hz throttle by
                // SessionController) — NOT a per-body-render compute, which would
                // fire on every word event (40k+/hr) and O(transcript × keywords).
                LiveCoachView(state: session.liveCoachState)
            }

            field("회의 모드") { meetingModePicker }

            field("언어") { languagePicker }

            field("화자 수") { speakerCountPicker }

            Toggle(isOn: $session.autoSaveSummary) {
                Label("A.I 요약", systemImage: "sparkles")
                    .font(Theme.Fonts.status)
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(Theme.Colors.textSecondary)
            .help("완료 시 회의 요약을 전사문과 별개의 ‘요약.md’ 파일로 저장합니다 (요약 모델 필요)")

            VStack(alignment: .leading, spacing: 1) {
                Toggle(isOn: $session.liveRailEnabled) {
                    Label("라이브 액션 추출", systemImage: "bolt").font(Theme.Fonts.status)
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.Colors.textSecondary)
                .disabled(!SessionController.liveRailCapable || isRecordingLike)
                if !SessionController.liveRailCapable {
                    Text("16GB 이상 메모리 필요 (DNA3 LLM 동시 구동)")
                        .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .help("녹음 중 결정·할 일·질문을 실시간 추출합니다. 요약 모델(DNA3)을 전사와 동시 구동 — 메모리 사용이 크고, 같은 모델을 쓰는 ‘실시간 번역’은 이때 일시 중지됩니다. 녹음 전에 설정하세요.")

            Toggle(isOn: $session.liveCoachEnabled) {
                Label("라이브 코치", systemImage: "checklist").font(Theme.Fonts.status)
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(Theme.Colors.textSecondary)
            .help("녹음 중 안건(지난 결정·미해결 액션) 처리 현황, 미답변 질문, 회의 흐름을 실시간으로 코치합니다. 모델 불필요 — 모든 기기에서 동작합니다.")

            if !session.translateTargets.isEmpty {
                Button { session.toggleCaptionOverlay() } label: {
                    Label(session.captionOverlayOn ? "자막 오버레이 끄기" : "자막 오버레이",
                          systemImage: "captions.bubble")
                        .font(Theme.Fonts.status)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.captionOverlayOn ? Theme.Colors.accent : Theme.Colors.textSecondary)
                .help("화면 위에 떠 있는 실시간 번역 자막 창 — Zoom·Teams 통화 위에 표시")
            }

            dropZone

            if !session.transcript.lines.isEmpty {
                Divider().overlay(Theme.Colors.separator)
                speakingStats
                let energy = EnergyArc.compute(lines: session.transcript.lines)
                if !energy.isEmpty { EnergyArcView(values: energy) }
            }

            Spacer(minLength: 8)

            if !session.transcript.lines.isEmpty, session.tightenStat.cuts > 0 { tightenStatView }
            if let saved = session.lastAutoSaved { savedStatus(saved) }

            HStack {
                Text(phaseText).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                exportMenu
            }
        }
        .padding(Theme.Space.window)
        .frame(width: Theme.Size.sidePanelW)
        .background(
            Theme.Colors.surface
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.Colors.separator, lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 2)
        )
        .padding(.vertical, 12)
        .padding(.trailing, 12)
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

    // 발언권 분석: per-speaker talk time from the diarized lines (who talked how
    // much). Σ(line end − start) per speaker → colored share bars.
    private var speakingStats: some View {
        var times: [Int: Double] = [:]
        for l in session.transcript.lines { times[l.speaker, default: 0] += max(0, l.end - l.start) }
        let total = max(0.001, times.values.reduce(0, +))
        let sorted = times.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 7) {
            Text("발언 시간").font(Theme.Fonts.section).foregroundStyle(Theme.Colors.textSecondary)
            ForEach(sorted, id: \.key) { entry in
                let frac = entry.value / total
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.Colors.speaker(entry.key)).frame(width: 7, height: 7)
                        Text(session.speakerNames[entry.key] ?? "Speaker \(entry.key)")
                            .font(Theme.Fonts.status).lineLimit(1)
                        Spacer()
                        Text("\(mmss(entry.value)) · \(Int((frac * 100).rounded()))%")
                            .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Colors.speaker(entry.key).opacity(0.18))
                            Capsule().fill(Theme.Colors.speaker(entry.key))
                                .frame(width: geo.size.width * frac)
                        }
                    }.frame(height: 4)
                }
            }
        }
    }
    private func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    @ViewBuilder private func field<V: View>(_ label: String, @ViewBuilder _ control: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Theme.Fonts.section).foregroundStyle(Theme.Colors.textSecondary)
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
                Button { session.pauseRecording() } label: {
                    Label("일시정지", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).keyboardShortcut("p")
                Button(role: .destructive) { session.stop() } label: {
                    Label("정지", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.Colors.recording)
                .controlSize(.large).keyboardShortcut("r")
            }
        case .paused:
            HStack(spacing: 8) {
                Button { session.resumeRecording() } label: {
                    Label("재개", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("p").tint(Theme.Colors.recording)
                Button(role: .destructive) { session.stop() } label: {
                    Label("정지", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).keyboardShortcut("r")
            }
        case .countingDown(let n):
            Button { session.cancelCountdown() } label: {
                Label("시작까지 \(n)… (취소)", systemImage: "xmark.circle")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 8)
            }
            .buttonStyle(.bordered).controlSize(.large).keyboardShortcut(.cancelAction)
        case .engineStarting, .ready, .processing, .flushing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phaseText).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 36)
        default:
            Button { session.startCountdown() } label: {
                Label("녹음 시작", systemImage: "record.circle.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 8)
            }
            .buttonStyle(.borderedProminent).tint(Theme.Colors.accent)
            .controlSize(.large).keyboardShortcut("r")
        }
    }

    // Prominent language selector — the deterministic fix for "spoke Korean,
    // got English": auto-detect can misfire on an ambiguous opening; picking
    // the language locks it. Persisted across launches.
    private var languagePicker: some View {
        Picker("", selection: Binding(
            get: { session.languageTokenID },
            set: { session.languageTokenID = $0
                   UserDefaults.standard.set($0 ?? 0, forKey: "languageTokenID") }
        )) {
            Text("자동 감지").tag(Int?.none)
            Text("한국어").tag(Int?.some(WhisperLang.ko))
            Text("English").tag(Int?.some(WhisperLang.en))
        }
        .labelsHidden().disabled(isBusy)
    }

    private var meetingModePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(
                get: { session.meetingMode },
                set: { session.meetingMode = $0 }
            )) {
                ForEach(MeetingMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.sfSymbol).tag(mode)
                }
            }
            .labelsHidden().disabled(isBusy || isRecordingLike)
            Text(session.meetingMode.config.mode.summaryDescription)
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    // 화자 수 고정 — 자동/1/2/3/4명 이상. Maps to the engine's DIAR_MAXK cap.
    private var speakerCountPicker: some View {
        Picker("", selection: Binding(
            get: { session.speakerCount },
            set: { session.speakerCount = $0 }
        )) {
            ForEach(SpeakerCount.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().disabled(isBusy)
    }

    // Visible drop target + an explicit "Choose File…" button so file input is
    // discoverable without knowing about drag-&-drop.
    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24))
                .foregroundStyle(dropTargeted ? Theme.Colors.accent : Theme.Colors.textTertiary)
            Text("오디오·영상 파일\n드래그 앤 드롭")
                .multilineTextAlignment(.center)
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            Button("파일 선택…") { chooseFile() }
                .controlSize(.small).disabled(!canDrop)
        }
        .frame(maxWidth: .infinity).frame(height: 124)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.dropZone)
            .fill(Theme.Colors.accent.opacity(dropTargeted ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.dropZone)
            .strokeBorder(dropTargeted ? Theme.Colors.accent : Theme.Colors.separator,
                          style: StrokeStyle(lineWidth: 1.5, dash: [6])))
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
