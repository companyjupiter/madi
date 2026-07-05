// ModelGateView.swift — first-run model download UI; blocks the session UI
// until model.safetensors is present and SHA-256 valid.

import SwiftUI

struct ModelGateView: View {
    @Bindable var downloader: ModelDownloader

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 104, height: 104)
                .background(Circle().fill(Theme.Colors.accent.opacity(0.10)))
            VStack(spacing: 4) {
                Text("Madi").font(Theme.Fonts.appTitle).foregroundStyle(Theme.Colors.brandMark)
                Text("기기 안에서 안전하게 회의를 기록합니다")
                    .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            }

            switch downloader.state {
            case .checking, .idle:
                ProgressView("모델 확인 중…")
            case .downloading(let p):
                VStack(spacing: 10) {
                    ProgressView(value: p) {
                        Text("음성 모델 다운로드 중 (\(Int(p * 100))%)")
                    }
                    .tint(Theme.Colors.accent)
                    .frame(width: Theme.Size.gateProgressW)
                    Text("~\(ByteCountFormatter.string(fromByteCount: AssetManifest.model.sizeBytes, countStyle: .file)) · 최초 1회").font(Theme.Fonts.status)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Button("취소") { downloader.cancel() }
                }
            case .verifying:
                ProgressView("검증 중…")
            case .failed(let msg):
                VStack(spacing: 8) {
                    Text("다운로드 실패").foregroundStyle(Theme.Colors.recording)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Button("다시 시도") { downloader.startDownload() }
                        .buttonStyle(.borderedProminent).tint(Theme.Colors.accent)
                }
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surfaceSunken)
        .padding(40)
    }
}
