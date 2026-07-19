// ModelGateView.swift — first-run model download UI; blocks the session UI
// until model.safetensors is present and SHA-256 valid.

import SwiftUI

struct ModelGateView: View {
    @Bindable var downloader: ModelDownloader
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 104, height: 104)
                .background(Circle().fill(Theme.Colors.accent.opacity(0.10)))
            VStack(spacing: 4) {
                Text("Madi").font(Theme.Fonts.appTitle).foregroundStyle(Theme.Colors.brandMark)
                Text(uiLang("기기 안에서 안전하게 회의를 기록합니다", "Record meetings securely, entirely on your device"))
                    .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
            }

            switch downloader.state {
            case .checking, .idle:
                ProgressView(uiLang("모델 확인 중…", "Checking model…"))
            case .downloading(let p):
                VStack(spacing: 10) {
                    ProgressView(value: p) {
                        Text(uiLang("음성 모델 다운로드 중 (\(Int(p * 100))%)", "Downloading speech model (\(Int(p * 100))%)", "音声モデルをダウンロード中 (\(Int(p * 100))%)"))
                    }
                    .tint(Theme.Colors.accent)
                    .frame(width: Theme.Size.gateProgressW)
                    Text("~\(ByteCountFormatter.string(fromByteCount: AssetManifest.model.sizeBytes, countStyle: .file)) · \(uiLang("최초 1회", "one time only"))").font(Theme.Fonts.status)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Button(uiLang("취소", "Cancel")) { downloader.cancel() }
                }
            case .verifying:
                ProgressView(uiLang("검증 중…", "Verifying…"))
            case .cancelled:
                VStack(spacing: 8) {
                    Text(uiLang("다운로드를 취소했습니다", "Download cancelled")).foregroundStyle(Theme.Colors.textSecondary)
                    Text(uiLang("음성 모델이 있어야 회의를 기록할 수 있습니다", "The speech model is required to record meetings"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(uiLang("다운로드 시작", "Start download")) { downloader.startDownload() }
                        .buttonStyle(.borderedProminent).tint(Theme.Colors.accent)
                }
            case .failed(let msg):
                VStack(spacing: 8) {
                    Text(uiLang("다운로드 실패", "Download failed")).foregroundStyle(Theme.Colors.recording)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Button(uiLang("다시 시도", "Retry")) { downloader.startDownload() }
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
