// ModelGateView.swift — first-run model download UI; blocks the session UI
// until model.safetensors is present and SHA-256 valid.

import SwiftUI

struct ModelGateView: View {
    @Bindable var downloader: ModelDownloader

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle").font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Sovereign Whisper").font(.title2).bold()

            switch downloader.state {
            case .checking, .idle:
                ProgressView("Checking model…")
            case .downloading(let p):
                VStack(spacing: 8) {
                    ProgressView(value: p) {
                        Text("Downloading model (\(Int(p * 100))%)")
                    }
                    .frame(width: 320)
                    Text("~1.5 GB · one time").font(.caption).foregroundStyle(.secondary)
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
