// InfoView.swift — Help → 정보 window. Shows the app's semantic version, release
// channel, and the beta lifecycle (expiry date + live status from BetaGate), plus
// quick links. Read-only; the actual update flow lives in UpdateView.

import SwiftUI
import AppKit

struct InfoView: View {
    @Bindable var betaGate: BetaGate
    @Environment(\.openWindow) private var openWindow

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
                Text("빌드 \(AppVersion.build) · \(AppVersion.bundleID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            Divider().frame(maxWidth: 300)

            expirySection

            HStack(spacing: 14) {
                Button {
                    NSWorkspace.shared.open(AppVersion.releasesURL)
                } label: { Label("릴리스", systemImage: "shippingbox") }
                Button { openWindow(id: "madi-update") } label: {
                    Label("업데이트 확인", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .buttonStyle(.bordered)

            Text("© companyjupiter · 온-디바이스 회의 기록. 오디오는 Mac을 떠나지 않습니다.")
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
                          title: "베타 사용 가능",
                          detail: "\(Self.expiryText)까지")
            case .expiringSoon(let days):
                statusRow(icon: "exclamationmark.triangle.fill", tint: Theme.Colors.overlapMarker,
                          title: days <= 0 ? "오늘 베타가 종료됩니다" : "베타 종료 D-\(days)",
                          detail: "\(Self.expiryText) 종료 · 정식판 준비를 권장합니다")
            case .expired:
                statusRow(icon: "hourglass.bottomhalf.filled", tint: Theme.Colors.recording,
                          title: "베타 기간 종료됨",
                          detail: "\(Self.expiryText) 종료 · 정식판을 받아 주세요")
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

    static var expiryText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일"
        return f.string(from: AppVersion.betaExpiryDate)
    }
}
