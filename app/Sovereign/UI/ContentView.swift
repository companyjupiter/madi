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
    // N2 review navigator (상세 mode): step through low-confidence words.
    @State private var reviewIndex = 0
    @State private var scrollTarget: UUID? = nil
    @State private var scrollTick = 0
    @State private var showSummary = false   // on-device meeting summary sheet

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
        HStack(spacing: 0) {
            transcriptPane
            sidePanel
        }
        .background(Theme.Colors.surfaceSunken)
        .dropDestination(for: URL.self) { urls, _ in
            guard canDrop, let url = urls.first(where: isMediaFile) else { return false }
            session.transcribeFile(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(isPresented: $showSummary) { summarySheet }
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
            Divider().overlay(Theme.Colors.separator)
            if session.summarizing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("로컬 LLM이 요약을 생성하는 중…")
                        .font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textSecondary)
                    Text("전사 내용은 이 Mac을 떠나지 않습니다.")
                        .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text = session.meetingSummary {
                ScrollView {
                    Text(text).font(.system(size: max(13, fontSize - 2)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button { copy(text) } label: { Label("복사", systemImage: "doc.on.doc") }
                    Button { session.summarize() } label: { Label("다시 생성", systemImage: "arrow.clockwise") }
                    Spacer()
                    Button("내보내기…") { export(.init(filenameExtension: "md")!) { try text.write(to: $0, atomically: true, encoding: .utf8) } }
                }.font(Theme.Fonts.status)
            }
        }
        .padding(Theme.Space.window)
        .frame(width: 520, height: 460)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: transcript pane (left, flexible)

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            if case .processing = session.phase { progressBanner }
            if !session.transcript.lines.isEmpty { viewModeBar }
            if viewMode == .detailed && !flaggedWords.isEmpty { reviewBar }
            ZStack {
                if session.transcript.lines.isEmpty {
                    emptyState
                } else {
                    TranscriptView(lines: session.transcript.lines, names: session.speakerNames,
                                   mode: viewMode,
                                   onRename: { session.renameSpeaker($0, to: $1) },
                                   scrollTarget: scrollTarget, scrollTick: scrollTick,
                                   focusedLine: scrollTarget,
                                   interim: session.livePartial,
                                   fontSize: fontSize,
                                   onEdit: { session.editLine($0, to: $1) },
                                   lockedLineID: isRecordingLike ? session.transcript.lines.last?.id : nil,
                                   onRequestDetailed: { contentMode = false })
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
                Text("Sovereign").font(Theme.Fonts.appTitle)
                Text("Whisper").font(Theme.Fonts.appTitle).foregroundStyle(Theme.Colors.textTertiary)
                Spacer()
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

            field("언어") { languagePicker }

            dropZone

            if !session.transcript.lines.isEmpty {
                Divider().overlay(Theme.Colors.separator)
                speakingStats
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
        return t.conforms(to: .audio) || t.conforms(to: .audiovisualContent) || t.conforms(to: .movie)
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .audiovisualContent, .movie]
        if panel.runModal() == .OK, let url = panel.url { session.transcribeFile(url) }
    }
    private func export(_ type: UTType, _ writer: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "transcript"
        if panel.runModal() == .OK, let url = panel.url { try? writer(url) }
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
