// ContentView.swift — main window: model gate, transcript, record controls.

import SwiftUI
import CoreAudio
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            switch downloader.state {
            case .ready:
                contentArea
                Divider()
                controlBar
            default:
                ModelGateView(downloader: downloader)
            }
        }
    }

    // transcript (or empty/processing state) with a file drag-&-drop target
    private var contentArea: some View {
        ZStack {
            if session.transcript.lines.isEmpty {
                emptyState
            } else {
                TranscriptView(lines: session.transcript.lines, names: session.speakerNames)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Colors.accent.opacity(0.06)))
                    .overlay(Label("드롭하여 전사", systemImage: "tray.and.arrow.down")
                        .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.accent))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard canDrop, let url = urls.first(where: isAudioFile) else { return false }
            session.transcribeFile(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if isBusy {
                ProgressView()
                Text(phaseText).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            } else {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 44)).foregroundStyle(Theme.Colors.textTertiary)
                Text("오디오 파일을 여기에 드래그 앤 드롭")
                    .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
                Text("또는 ⏺ Record 로 회의를 실시간 전사")
                    .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canDrop: Bool {
        switch session.phase {
        case .idle, .done, .error: return true
        default: return false
        }
    }
    private var isBusy: Bool {
        switch session.phase {
        case .idle, .done, .error: return false
        default: return true
        }
    }
    private func isAudioFile(_ url: URL) -> Bool {
        ["wav", "m4a", "mp3", "aiff", "aif", "caf", "aac", "flac", "mp4", "mov"]
            .contains(url.pathExtension.lowercased())
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            recordButton
            LevelMeter(level: session.level)
                .frame(width: Theme.Size.meterW, height: Theme.Size.meterH)
            Spacer()
            micPicker
            phaseLabel
            exportMenu
        }
        .padding(Theme.Space.controlBar)
    }

    private var micPicker: some View {
        Picker("", selection: $session.inputDeviceID) {
            Label("System Default", systemImage: "mic").tag(AudioDeviceID?.none)
            ForEach(session.availableInputs) { dev in
                Text(dev.name).tag(AudioDeviceID?.some(dev.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
        .disabled(session.phase == .recording) // device binds at record start
        .help("Input microphone (pick before recording)")
    }

    @ViewBuilder private var recordButton: some View {
        switch session.phase {
        case .recording:
            Button(role: .destructive) { session.stop() } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
        case .engineStarting, .ready, .processing, .flushing:
            ProgressView().controlSize(.small)
        default:
            Button { session.start() } label: {
                Label("Record", systemImage: "record.circle")
            }
            .keyboardShortcut("r")
        }
    }

    private var phaseLabel: some View {
        Text(phaseText).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
    }
    private var phaseText: String {
        switch session.phase {
        case .idle: "Ready"
        case .engineStarting: "Loading model…"
        case .ready: "Mic starting…"
        case .recording: "Recording"
        case .processing: "Transcribing file…"
        case .flushing: "Finalizing…"
        case .done: "Done"
        case .error(let m): "Error: \(m)"
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("Markdown (.md)") { export(.init(filenameExtension: "md")!, session.exportMarkdown) }
            Button("Subtitles (.srt)") { export(.init(filenameExtension: "srt")!, session.exportSRT) }
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        .menuStyle(.borderlessButton)
        .disabled(session.transcript.lines.isEmpty)
    }

    private func export(_ type: UTType, _ writer: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "transcript"
        if panel.runModal() == .OK, let url = panel.url { try? writer(url) }
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
