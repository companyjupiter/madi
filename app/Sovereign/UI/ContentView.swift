// ContentView.swift — main window: model gate, transcript, record controls.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader

    var body: some View {
        VStack(spacing: 0) {
            switch downloader.state {
            case .ready:
                TranscriptView(lines: session.transcript.lines, names: session.speakerNames)
                Divider()
                controlBar
            default:
                ModelGateView(downloader: downloader)
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            recordButton
            LevelMeter(level: session.level)
                .frame(width: Theme.Size.meterW, height: Theme.Size.meterH)
            Spacer()
            phaseLabel
            exportMenu
        }
        .padding(Theme.Space.controlBar)
    }

    @ViewBuilder private var recordButton: some View {
        switch session.phase {
        case .recording:
            Button(role: .destructive) { session.stop() } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
        case .engineStarting, .ready, .flushing:
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
