// SettingsView.swift — input/diarization/model settings.

import SwiftUI

struct SettingsView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader

    var body: some View {
        TabView {
            transcription.tabItem { Label("Transcription", systemImage: "text.bubble") }
            model.tabItem { Label("Model", systemImage: "shippingbox") }
        }
        .frame(width: 420, height: 260)
        .padding()
    }

    private var transcription: some View {
        Form {
            Toggle("Speaker diarization", isOn: $session.diarize)
            Toggle("Overlapped-speech detection", isOn: $session.osd)
            Picker("Language", selection: $session.languageTokenID) {
                Text("Auto-detect").tag(Int?.none)
                Text("Korean").tag(Int?.some(WhisperLang.ko))
                Text("English").tag(Int?.some(WhisperLang.en))
            }
        }
        .disabled(session.phase == .recording)
    }

    private var model: some View {
        Form {
            LabeledContent("Status") {
                Text(AssetManifest.modelIsValid() ? "Installed" : "Not installed")
            }
            LabeledContent("Location") {
                Text(AssetManifest.modelURL.path).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Button("Re-download model") { downloader.startDownload() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AssetManifest.modelURL])
            }
        }
    }
}

/// Whisper language token IDs (must match the engine's token table).
/// TODO: confirm exact ids against the BPE/token table before shipping.
enum WhisperLang {
    static let en = 50259
    static let ko = 50264
}
