// ContentView.swift — main window: model gate, transcript (left, fills window),
// and a right control panel (record / language / mic / file drop).

import SwiftUI
import CoreAudio
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader
    @State private var dropTargeted = false

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
            ZStack {
                if session.transcript.lines.isEmpty {
                    emptyState
                } else {
                    TranscriptView(lines: session.transcript.lines, names: session.speakerNames,
                                   onRename: { session.renameSpeaker($0, to: $1) })
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
            if session.phase == .recording {
                LevelMeter(level: session.level).frame(height: Theme.Size.meterH)
            }

            Divider()

            field("언어") { languagePicker }
            field("마이크") { micPicker }
            Toggle("화자 분리", isOn: $session.diarize).disabled(isBusy)
            Toggle("중첩 발화 감지", isOn: $session.osd).disabled(isBusy)

            Divider()

            dropZone

            Spacer()

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

    @ViewBuilder private func field<V: View>(_ label: String, @ViewBuilder _ control: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            control()
        }
    }

    @ViewBuilder private var recordButton: some View {
        switch session.phase {
        case .recording:
            Button(role: .destructive) { session.stop() } label: {
                Label("정지", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large).keyboardShortcut("r")
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
