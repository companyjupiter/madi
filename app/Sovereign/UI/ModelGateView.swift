// ModelGateView.swift — first-run model download UI; blocks the session UI
// until model.safetensors is present and SHA-256 valid.

import SwiftUI

struct ModelGateView: View {
    @Bindable var downloader: ModelDownloader

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: Theme.Size.gateIcon))
                .foregroundStyle(Theme.Colors.accent)
            Text("Sovereign Whisper").font(Theme.Fonts.appTitle)

            switch downloader.state {
            case .checking, .idle:
                ProgressView("Checking model…")
            case .downloading(let p):
                VStack(spacing: 8) {
                    ProgressView(value: p) {
                        Text("Downloading model (\(Int(p * 100))%)")
                    }
                    .frame(width: Theme.Size.gateProgressW)
                    Text("~\(ByteCountFormatter.string(fromByteCount: AssetManifest.model.sizeBytes, countStyle: .file)) · one time").font(Theme.Fonts.status)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Button("Cancel") { downloader.cancel() }
                }
            case .verifying:
                ProgressView("Verifying…")
            case .failed(let msg):
                VStack(spacing: 8) {
                    Text("Download failed").foregroundStyle(.red)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { downloader.startDownload() }
                }
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
