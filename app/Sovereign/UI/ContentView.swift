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
            Divider()
            sidePanel
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard canDrop, let url = urls.first(where: isMediaFile) else { return false }
            session.transcribeFile(url)
            return true
        } isTargeted: { dropTargeted = $0 }
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
                                   fontSize: fontSize)
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Colors.accent.opacity(0.06)))
                        .overlay(Label("드롭하여 전사", systemImage: "tray.and.arrow.down")
                            .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.accent))
                        .padding(8).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // 내용/상세 toggle — keeps the clean reading view (default) free of the
    // editor/review detail. Persisted across launches via @AppStorage.
    private var viewModeBar: some View {
        HStack(spacing: 10) {
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
        VStack(spacing: 10) {
            if case .processing = session.phase {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 40)).foregroundStyle(Theme.Colors.accent.opacity(0.5))
                Text("전사 결과가 곧 여기에 표시됩니다…")
                    .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            } else if case .error(let msg) = session.phase {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundStyle(.orange)
                Text(msg).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            } else if isBusy {
                ProgressView()
                Text(phaseText).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 46)).foregroundStyle(Theme.Colors.textTertiary)
                Text("회의를 녹음하거나, 오른쪽에 오디오 파일을 드롭하세요")
                    .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: right control panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sovereign Whisper").font(Theme.Fonts.appTitle)

            recordButton
            if session.phase == .recording || session.phase == .paused {
                LevelMeter(level: session.level).frame(height: Theme.Size.meterH)
                    .opacity(session.phase == .paused ? 0.4 : 1)
            }

            Divider()

            field("언어") { languagePicker }
            field("마이크") { micPicker }
            field("실시간 반응") { liveSpeedPicker }
            livePreviewToggle
            Toggle("화자 분리", isOn: $session.diarize).disabled(isBusy)
            Toggle("중첩 발화 감지", isOn: $session.osd).disabled(isBusy)

            Divider()

            dropZone

            if !session.transcript.lines.isEmpty {
                Divider()
                speakingStats
            }

            if !session.transcript.lines.isEmpty {
                Divider()
                editorToolsPanel
                if session.tightenStat.cuts > 0 { tightenStatView }
            }

            Spacer()

            autoSaveRow

            HStack {
                Text(phaseText).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                exportMenu
            }
        }
        .padding(Theme.Space.window)
        .frame(width: 280)
        .background(Theme.Colors.textTertiary.opacity(0.04))
    }

    // 편집 도구: toggle + tune every editor feature. Dense by design — a UI/UX
    // designer will restyle later. Binds to the persisted session.editorSettings;
    // exports + the tighten stat react live. Control-panel only — never the
    // clean 내용 transcript.
    @State private var editorToolsExpanded = false
    private var editorToolsPanel: some View {
        DisclosureGroup("편집 도구", isExpanded: $editorToolsExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("필러 컷", isOn: $session.editorSettings.fillers)
                Toggle("무음 컷", isOn: $session.editorSettings.silences)
                sliderRow("무음 최소초", $session.editorSettings.silenceMinGap, 0.2...3.0)
                Divider()
                Toggle("자동 챕터", isOn: $session.editorSettings.chapters)
                sliderRow("챕터 휴지초", $session.editorSettings.chapterGap, 1...10)
                sliderRow("챕터 최소간격", $session.editorSettings.chapterMinLen, 10...120, "%.0f")
                Divider()
                Toggle("리테이크", isOn: $session.editorSettings.retakes)
                sliderRow("유사도", $session.editorSettings.retakeSim, 0.5...0.95, "%.2f")
                Divider()
                Toggle("하이라이트", isOn: $session.editorSettings.highlights)
                sliderRow("최소 신뢰도", $session.editorSettings.hlMinConf, 0.5...0.99, "%.2f")
                sliderRow("최소 휴지초", $session.editorSettings.hlMinPause, 0.3...3.0)
            }
            .font(Theme.Fonts.status)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.top, 4)
        }
        .font(Theme.Fonts.status)
        .tint(Theme.Colors.accent)
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>,
                           _ range: ClosedRange<Double>, _ fmt: String = "%.1f") -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 84, alignment: .leading)
                .foregroundStyle(Theme.Colors.textSecondary)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue))
                .frame(width: 34, alignment: .trailing).monospacedDigit()
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    // 자동 저장: 회의/전사가 끝나면 .md 를 선택한 폴더에 자동 저장. 경로는 변경 가능.
    private var autoSaveRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $session.autoSaveEnabled) {
                Text("완료 시 .md 자동저장").font(Theme.Fonts.status)
            }
            .toggleStyle(.switch).controlSize(.mini)
            if session.autoSaveEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(Theme.Fonts.status)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(session.autoSaveFolder.lastPathComponent)
                        .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("변경") { chooseAutoSaveFolder() }
                        .font(Theme.Fonts.status).buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .help(session.autoSaveFolder.path)
                if let saved = session.lastAutoSaved {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(Theme.Fonts.status)
                            .foregroundStyle(Theme.Colors.accent)
                        Button(saved.lastPathComponent) {
                            NSWorkspace.shared.activateFileViewerSelecting([saved])
                        }
                        .font(Theme.Fonts.status).buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help("Finder에서 보기")
                    }
                }
            }
        }
    }

    private func chooseAutoSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.autoSaveFolder
        panel.prompt = "선택"
        panel.message = "전사 완료 시 .md 를 저장할 폴더"
        if panel.runModal() == .OK, let url = panel.url { session.autoSaveFolder = url }
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
            Text("발언 시간").font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            control()
        }
    }

    @ViewBuilder private var recordButton: some View {
        switch session.phase {
        case .recording:
            HStack(spacing: 8) {
                Button { session.pauseRecording() } label: {
                    Label("일시정지", systemImage: "pause.circle.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).keyboardShortcut("p")
                Button(role: .destructive) { session.stop() } label: {
                    Label("정지", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).keyboardShortcut("r")
            }
        case .paused:
            HStack(spacing: 8) {
                Button { session.resumeRecording() } label: {
                    Label("재개", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).keyboardShortcut("p").tint(Theme.Colors.recording)
                Button(role: .destructive) { session.stop() } label: {
                    Label("정지", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).keyboardShortcut("r")
            }
        case .engineStarting, .ready, .processing, .flushing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phaseText).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 28)
        default:
            Button { session.start() } label: {
                Label("녹음 시작", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
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

    // 실시간 반응 속도: shorter window = snappier live text, less Whisper context.
    // Default 정확(10s) keeps current accuracy; can't change mid-session.
    private var liveSpeedPicker: some View {
        Picker("", selection: $session.liveWindowSeconds) {
            Text("빠름").tag(5.0)
            Text("보통").tag(7.0)
            Text("정확").tag(10.0)
        }
        .pickerStyle(.segmented).labelsHidden()
        .disabled(session.phase == .recording || session.phase == .paused)
        .help("빠름=텍스트가 더 자주 뜸(체감↑), 정확=Whisper 컨텍스트 길어 품질↑. 녹음 시작 시 적용.")
    }

    // 스트리밍 프리뷰: 채워지는 중인 윈도를 ~1.5초마다 미리 디코드해 회색 "진행 중"
    // 텍스트로 표시 (정확도 손해 0 — 확정 전사는 그대로). 별도 모델 1개 추가 상주.
    private var livePreviewToggle: some View {
        Toggle(isOn: $session.livePreviewEnabled) {
            Text("실시간 프리뷰").font(Theme.Fonts.status)
        }
        .toggleStyle(.switch).controlSize(.mini)
        .disabled(session.phase == .recording || session.phase == .paused)
        .help("켜면 윈도가 닫히기 전에도 회색 중간 텍스트가 즉시 표시됩니다(정확도 무손해). 메모리에 모델 1개 추가(~830MB).")
    }

    private var micPicker: some View {
        Picker("", selection: $session.inputDeviceID) {
            Text("시스템 기본").tag(AudioDeviceID?.none)
            ForEach(session.availableInputs) { dev in
                Text(dev.name).tag(AudioDeviceID?.some(dev.id))
            }
        }
        .labelsHidden().disabled(session.phase == .recording)
    }

    // Visible drop target + an explicit "Choose File…" button so file input is
    // discoverable without knowing about drag-&-drop.
    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(dropTargeted ? Theme.Colors.accent : Theme.Colors.textTertiary)
            Text("오디오·영상 파일\n드래그 앤 드롭")
                .multilineTextAlignment(.center)
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            Button("파일 선택…") { chooseFile() }
                .controlSize(.small).disabled(!canDrop)
        }
        .frame(maxWidth: .infinity).frame(height: 128)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Theme.Colors.accent.opacity(dropTargeted ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(dropTargeted ? Theme.Colors.accent : Theme.Colors.textTertiary,
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
