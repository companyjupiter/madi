// InfoView.swift — Help → 정보 window. Shows the app's semantic version, release
// channel, and the beta lifecycle (expiry date + live status from BetaGate), plus
// quick links. Read-only; the actual one-click update flow lives in Sparkle.

import SwiftUI
import AppKit

struct InfoView: View {
    @Bindable var betaGate: BetaGate
    let sparkleUpdater: SparkleUpdater
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Theme.Colors.accent)
                Text("Madi")
                    .font(Theme.Fonts.appTitle)
                    .foregroundStyle(Theme.Colors.brandMark)
                HStack(spacing: 6) {
                    Text(AppVersion.full)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if AppVersion.isBeta { channelBadge }
                }
                Text("\(uiLang("빌드", "Build")) \(AppVersion.build) · \(AppVersion.bundleID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            Divider().frame(maxWidth: 300)

            // Beta lifecycle (expiry status) only applies to the beta channel.
            if AppVersion.isBeta { expirySection }

            HStack(spacing: 14) {
                Button {
                    NSWorkspace.shared.open(AppVersion.releasesURL)
                } label: { Label(uiLang("릴리스", "Releases"), systemImage: "shippingbox") }
                Button { sparkleUpdater.checkForUpdates() } label: {
                    Label(uiLang("업데이트 확인", "Check for updates"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!sparkleUpdater.canCheckForUpdates)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .buttonStyle(.bordered)

            Text(uiLang("© companyjupiter · 온-디바이스 회의 기록. 오디오는 Mac을 떠나지 않습니다.",
                        "© companyjupiter · On-device meeting notes. Audio never leaves your Mac."))
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 380)
        .background(Theme.Colors.surface)
        .onAppear { betaGate.refresh() }
    }

    private var channelBadge: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.Colors.accent.opacity(0.16)))
            .foregroundStyle(Theme.Colors.accent)
    }

    @ViewBuilder private var expirySection: some View {
        VStack(spacing: 6) {
            switch betaGate.status {
            case .active:
                statusRow(icon: "checkmark.seal.fill", tint: Theme.Colors.meterFill,
                          title: uiLang("베타 사용 가능", "Beta active"),
                          detail: uiLang("\(Self.expiryText(uiLang))까지", "Through \(Self.expiryText(uiLang))"))
            case .expiringSoon(let days):
                statusRow(icon: "exclamationmark.triangle.fill", tint: Theme.Colors.overlapMarker,
                          title: days <= 0 ? uiLang("오늘 베타가 종료됩니다", "Beta ends today") : uiLang("베타 종료 D-\(days)", "Beta ends in \(days)d"),
                          detail: uiLang("\(Self.expiryText(uiLang)) 종료 · 정식판 준비를 권장합니다", "Ends \(Self.expiryText(uiLang)) · we recommend preparing the full version"))
            case .expired:
                statusRow(icon: "hourglass.bottomhalf.filled", tint: Theme.Colors.recording,
                          title: uiLang("베타 기간 종료됨", "Beta period ended"),
                          detail: uiLang("\(Self.expiryText(uiLang)) 종료 · 정식판을 받아 주세요", "Ended \(Self.expiryText(uiLang)) · please get the full version"))
            }
        }
    }

    private func statusRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(detail)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(tint.opacity(0.08)))
    }

    static func expiryText(_ lang: UILanguage) -> String {
        let f = DateFormatter()
        switch lang {
        case .en: f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d, yyyy"
        case .ja: f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年M月d日"
        case .ko: f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "yyyy년 M월 d일"
        }
        return f.string(from: AppVersion.betaExpiryDate)
    }
}
