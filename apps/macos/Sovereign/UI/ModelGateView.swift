// ModelGateView.swift — first-launch model guide. Whisper Q8 is the required
// transcription/speaker engine; the hardware-selected DNA model is optional and
// powers translation, correction, summaries, and Q&A. No download starts until
// the user understands and chooses a setup.

import SwiftUI

struct ModelGateView: View {
    @Bindable var downloader: ModelDownloader
    @Bindable var translateDownloader: TranslateModelDownloader
    @Binding var setupChoice: FirstRunModelSetupChoice?
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    private var translationVariant: TranslateModelVariant {
        AssetManifest.translateModelVariant
    }

    private var translationAsset: RemoteAsset {
        AssetManifest.translateModel
    }

    private var translationEngineAvailable: Bool {
        AssetManifest.translateEngineURL != nil
    }

    private var memoryGB: Int {
        let gib = UInt64(1 << 30)
        return Int((physicalMemory + gib / 2) / gib)
    }

    private var isDownloading: Bool {
        if case .downloading = downloader.state { return true }
        if case .downloading = translateDownloader.state { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                VStack(spacing: 12) {
                    whisperCard
                    translationCard
                }

                actions

                Label(
                    uiLang("모델만 내려받으며, 회의 음성과 전사문은 이 Mac을 떠나지 않습니다.",
                           "Only the models are downloaded. Meeting audio and transcripts never leave this Mac.",
                           "ダウンロードするのはモデルだけです。会議音声と文字起こしがこの Mac を離れることはありません。"),
                    systemImage: "lock.shield")
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 36)
            .padding(.vertical, 38)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.surfaceSunken)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 84, height: 84)
                .background(Circle().fill(Theme.Colors.accent.opacity(0.10)))

            Text(uiLang("이 Mac에 맞게 Madi 준비하기",
                        "Set up Madi for this Mac",
                        "この Mac に合わせて Madi を準備"))
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)

            Text(uiLang("전사에 필요한 모델과 AI 기능용 모델을 선택하세요. 처음 한 번만 받습니다.",
                        "Choose the required transcription model and the optional AI model. This is a one-time download.",
                        "文字起こしに必須のモデルと AI 機能用モデルを選びます。ダウンロードは初回のみです。"))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Text(uiLang("이 Mac: \(memoryGB) GB 메모리 · \(translationVariant.displayName) 추천",
                        "This Mac: \(memoryGB) GB memory · \(translationVariant.displayName) recommended",
                        "この Mac: メモリ \(memoryGB) GB · \(translationVariant.displayName) を推奨"))
                .font(Theme.Fonts.label)
                .foregroundStyle(Theme.Colors.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.Colors.accent.opacity(0.10)))
        }
    }

    private var whisperCard: some View {
        modelCard(
            icon: "waveform",
            title: "Whisper large-v3 Turbo Q8",
            badge: uiLang("필수", "Required", "必須"),
            subtitle: uiLang("전사 · 화자 분리 · 실시간 프리뷰",
                             "Transcription · speaker separation · live preview",
                             "文字起こし · 話者分離 · ライブプレビュー"),
            detail: uiLang("Madi 독자 Zig/Metal 엔진 · 다운로드 \(fileSize(AssetManifest.model.sizeBytes))",
                           "Madi's native Zig/Metal engine · \(fileSize(AssetManifest.model.sizeBytes)) download",
                           "Madi 独自の Zig/Metal エンジン · ダウンロード \(fileSize(AssetManifest.model.sizeBytes))"),
            status: whisperStatus,
            progress: whisperProgress,
            error: whisperError,
            required: true)
    }

    private var translationCard: some View {
        let ram = String(format: "%.1f", translationAsset.approxRuntimeMemoryGB ?? 0)
        let profile = translationVariant == .realtime2B
            ? uiLang("8GB Mac 실시간 우선", "Realtime-first for 8 GB Macs", "8 GB Mac 向けリアルタイム優先")
            : uiLang("품질 우선", "Quality-first", "品質優先")
        return modelCard(
            icon: "character.bubble",
            title: translationVariant.displayName,
            badge: uiLang("선택 · 이 Mac 추천", "Optional · Recommended", "任意 · この Mac に推奨"),
            subtitle: uiLang("번역 · AI 교정 · 요약 · 질의응답",
                             "Translation · AI correction · summary · Q&A",
                             "翻訳 · AI 修正 · 要約 · 質疑応答"),
            detail: uiLang("\(profile) · 다운로드 \(fileSize(translationAsset.sizeBytes)) · 실행 메모리 실측 약 \(ram) GB",
                           "\(profile) · \(fileSize(translationAsset.sizeBytes)) download · measured runtime memory ~\(ram) GB",
                           "\(profile) · ダウンロード \(fileSize(translationAsset.sizeBytes)) · 実測実行メモリ約 \(ram) GB"),
            status: translationStatus,
            progress: translationProgress,
            error: translationError,
            required: false)
            .opacity(translationEngineAvailable ? 1 : 0.65)
    }

    private func modelCard(icon: String, title: String, badge: String,
                           subtitle: String, detail: String, status: String,
                           progress: Double?, error: String?, required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(required ? Theme.Colors.accent : Theme.Colors.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill((required ? Theme.Colors.accent : Theme.Colors.textPrimary).opacity(0.09)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(Theme.Fonts.label).foregroundStyle(Theme.Colors.textPrimary)
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(required ? Theme.Colors.accent : Theme.Colors.textSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill((required ? Theme.Colors.accent : Theme.Colors.textSecondary).opacity(0.10)))
                    }
                    Text(subtitle).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
                    Text(detail).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                Text(status)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(statusColor(status))
            }

            if let progress {
                ProgressView(value: progress)
                    .tint(Theme.Colors.accent)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.recording)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .fill(Theme.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .stroke(required ? Theme.Colors.accent.opacity(0.28) : Theme.Colors.separator, lineWidth: 1))
    }

    @ViewBuilder
    private var actions: some View {
        if setupChoice == nil {
            VStack(spacing: 10) {
                if translationEngineAvailable {
                    Button {
                        start(.recommended)
                    } label: {
                        Text(uiLang("추천 구성 다운로드 · \(downloadSize(.recommended))",
                                    "Download recommended setup · \(downloadSize(.recommended))",
                                    "推奨構成をダウンロード · \(downloadSize(.recommended))"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.Colors.accent)
                }

                Button {
                    start(.transcriptionOnly)
                } label: {
                    Text(uiLang("전사만 준비 · \(downloadSize(.transcriptionOnly))",
                                "Set up transcription only · \(downloadSize(.transcriptionOnly))",
                                "文字起こしのみ準備 · \(downloadSize(.transcriptionOnly))"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text(uiLang("DNA는 나중에 설정(⌘,) → 번역에서 받을 수 있습니다.",
                            "You can download DNA later in Settings (⌘,) → Translation.",
                            "DNA は後から「設定（⌘,）→ 翻訳」でダウンロードできます。"))
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        } else {
            VStack(spacing: 10) {
                if hasRetryableDownload {
                    Button(uiLang("실패한 다운로드 다시 시도", "Retry failed downloads", "失敗したダウンロードを再試行")) {
                        retryDownloads()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.Colors.accent)
                }

                if setupChoice == .recommended && downloader.state == .ready && translateDownloader.state != .ready {
                    Button(uiLang("전사를 먼저 시작하고 DNA는 계속 받기",
                                  "Start transcribing while DNA continues",
                                  "文字起こしを先に始め、DNA は継続してダウンロード")) {
                        setupChoice = .transcriptionOnly
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.Colors.accent)
                }

                if isDownloading {
                    Button(uiLang("다운로드 취소", "Cancel downloads", "ダウンロードをキャンセル")) {
                        cancelDownloads()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }

    private var whisperStatus: String {
        switch downloader.state {
        case .ready: return uiLang("설치됨", "Installed", "インストール済み")
        case .checking: return uiLang("확인 중", "Checking", "確認中")
        case .downloading(let p): return "\(Int(p * 100))%"
        case .verifying: return uiLang("검증 중", "Verifying", "検証中")
        case .failed: return uiLang("실패", "Failed", "失敗")
        case .cancelled: return uiLang("취소됨", "Cancelled", "キャンセル済み")
        case .idle: return uiLang("다운로드 전", "Not downloaded", "未ダウンロード")
        }
    }

    private var translationStatus: String {
        guard translationEngineAvailable else {
            return uiLang("엔진 없음", "Engine unavailable", "エンジンなし")
        }
        switch translateDownloader.state {
        case .ready: return uiLang("설치됨", "Installed", "インストール済み")
        case .downloading(let p): return "\(Int(p * 100))%"
        case .verifying: return uiLang("검증 중", "Verifying", "検証中")
        case .failed: return uiLang("실패", "Failed", "失敗")
        case .idle: return uiLang("선택 사항", "Optional", "任意")
        }
    }

    private var whisperProgress: Double? {
        if case .downloading(let p) = downloader.state { return p }
        if case .verifying = downloader.state { return 1 }
        return nil
    }

    private var translationProgress: Double? {
        if case .downloading(let p) = translateDownloader.state { return p }
        if case .verifying = translateDownloader.state { return 1 }
        return nil
    }

    private var whisperError: String? {
        if case .failed(let message) = downloader.state { return message }
        return nil
    }

    private var translationError: String? {
        if case .failed(let message) = translateDownloader.state { return message }
        return nil
    }

    private var hasRetryableDownload: Bool {
        switch downloader.state {
        case .idle, .cancelled, .failed: return setupChoice != nil
        default: break
        }
        guard setupChoice == .recommended else { return false }
        switch translateDownloader.state {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func statusColor(_ status: String) -> Color {
        if status == uiLang("설치됨", "Installed", "インストール済み") { return .green }
        if status == uiLang("실패", "Failed", "失敗") { return Theme.Colors.recording }
        return Theme.Colors.textSecondary
    }

    private func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func downloadSize(_ choice: FirstRunModelSetupChoice) -> String {
        let bytes = FirstRunModelSetupPolicy.downloadBytes(
            choice: choice,
            requiredModelReady: downloader.state == .ready,
            translationModelReady: translateDownloader.state == .ready,
            translationAssetBytes: translationAsset.sizeBytes)
        return fileSize(bytes)
    }

    private func start(_ choice: FirstRunModelSetupChoice) {
        setupChoice = choice
        if downloader.state != .ready { downloader.startDownload() }
        if choice == .recommended, translationEngineAvailable,
           translateDownloader.state != .ready {
            translateDownloader.startDownload()
        }
    }

    private func retryDownloads() {
        switch downloader.state {
        case .idle, .cancelled, .failed: downloader.startDownload()
        default: break
        }
        if setupChoice == .recommended, translationEngineAvailable {
            switch translateDownloader.state {
            case .idle, .failed: translateDownloader.startDownload()
            default: break
            }
        }
    }

    private func cancelDownloads() {
        if case .downloading = downloader.state { downloader.cancel() }
        if case .downloading = translateDownloader.state { translateDownloader.cancel() }
    }
}
