// BetaGateView.swift — the two surfaces of the beta-expiry lifecycle:
//   • ExpiredGateView   — full-window BLOCK shown at/after the expiry date. It
//     replaces the entire session UI (mirrors ModelGateView's gating role), so
//     the beta genuinely stops working and only points at the Official build.
//   • BetaWarningBanner — a slim strip shown during the final `warningDays`
//     before expiry, so users aren't surprised.

import SwiftUI
import AppKit

/// Full-window blocking screen for an expired beta. No path back into the app.
struct ExpiredGateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.Colors.recording)
                .frame(width: 108, height: 108)
                .background(Circle().fill(Theme.Colors.recording.opacity(0.10)))

            VStack(spacing: 6) {
                Text("Madi").font(Theme.Fonts.appTitle).foregroundStyle(Theme.Colors.brandMark)
                Text("베타 기간이 종료되었습니다")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            Text("이 베타(\(AppVersion.full))는 \(Self.expiryText) 사용 기간이 끝났습니다.\n계속 사용하려면 정식판을 내려받아 주세요.")
                .font(Theme.Fonts.status)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            Button {
                NSWorkspace.shared.open(AppVersion.releasesURL)
            } label: {
                Label("정식판 받기", systemImage: "arrow.down.circle.fill")
                    .font(Theme.Fonts.cta)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Colors.accent)

            Text(AppVersion.releasesURL.absoluteString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Colors.textTertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surfaceSunken)
        .padding(40)
    }

    static var expiryText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일"
        return f.string(from: AppVersion.betaExpiryDate)
    }
}

/// Slim advance-warning strip for the final stretch before expiry.
struct BetaWarningBanner: View {
    let daysLeft: Int
    /// Opens the in-app update window (Help → 업데이트 설치).
    var onCheckUpdate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.overlapMarker)
            Text(dDayText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("정식판으로 이전을 준비해 주세요")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer(minLength: 8)
            Button("업데이트 확인", action: onCheckUpdate)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.overlapMarker.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.separator).frame(height: 0.5)
        }
    }

    private var dDayText: String {
        daysLeft <= 0 ? "베타 종료 D-Day" : "베타 종료 D-\(daysLeft)"
    }
}
