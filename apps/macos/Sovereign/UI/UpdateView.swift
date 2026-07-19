// UpdateView.swift — Help → 업데이트 설치 window. Drives UpdateChecker: checks
// GitHub Releases on open, then shows one of {up-to-date, newer available with
// notes + install, downloading, downloaded, failed}. "설치" downloads the DMG and
// opens it so Finder mounts the drag-to-Applications volume.

import SwiftUI
import AppKit

struct UpdateView: View {
    @Bindable var checker: UpdateChecker
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.Colors.accent)
                Text(uiLang("업데이트", "Update"))
                    .font(Theme.Fonts.appTitle)
                    .foregroundStyle(Theme.Colors.brandMark)
                Text(uiLang("현재 버전 \(AppVersion.full)", "Current version \(AppVersion.full)"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            content

            if !isBusy {
                Button(uiLang("다시 확인", "Check again")) { checker.check() }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Theme.Colors.surface)
        .onAppear {
            if case .idle = checker.state { checker.check() }
        }
    }

    private var isBusy: Bool {
        switch checker.state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch checker.state {
        case .idle, .checking:
            ProgressView(uiLang("업데이트 확인 중…", "Checking for updates…"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

        case .upToDate:
            infoBlock(icon: "checkmark.seal.fill", tint: Theme.Colors.meterFill,
                      title: uiLang("최신 버전입니다", "You’re up to date"),
                      body: uiLang("설치된 \(AppVersion.full)보다 새로운 릴리스가 없습니다.", "There’s no release newer than the installed \(AppVersion.full)."))

        case .available(let rel):
            availableBlock(rel)

        case .downloading(let p):
            VStack(spacing: 10) {
                ProgressView(value: p) {
                    Text(uiLang("다운로드 중 (\(Int(p * 100))%)", "Downloading (\(Int(p * 100))%)"))
                        .font(Theme.Fonts.status)
                }
                .tint(Theme.Colors.accent)
                if let s = downloadSizeText { Text(s).font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textSecondary) }
            }
            .padding(.vertical, 4)

        case .downloaded(let url):
            infoBlock(icon: "checkmark.circle.fill", tint: Theme.Colors.meterFill,
                      title: uiLang("다운로드 완료", "Download complete"),
                      body: uiLang("Finder에서 열린 디스크 이미지의 Madi를 응용 프로그램 폴더로 끌어다 놓아 설치를 마치세요.", "In the disk image Finder opened, drag Madi into your Applications folder to finish installing."))
            Button(uiLang("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .buttonStyle(.bordered)

        case .failed(let msg):
            infoBlock(icon: "exclamationmark.triangle.fill", tint: Theme.Colors.recording,
                      title: uiLang("업데이트 확인 실패", "Update check failed"), body: msg)
            Button(uiLang("릴리스 페이지 열기", "Open releases page")) { checker.openReleasesPage() }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .buttonStyle(.bordered)
        }
    }

    private func availableBlock(_ rel: ReleaseInfo) -> some View {
        VStack(spacing: 12) {
            infoBlock(icon: "sparkles", tint: Theme.Colors.accent,
                      title: uiLang("새 버전 \(rel.version)", "New version \(rel.version)"),
                      body: rel.dmgURL != nil
                            ? uiLang("설치를 누르면 DMG를 내려받아 Finder에서 엽니다.", "Tap Install to download the DMG and open it in Finder.")
                            : uiLang("이 릴리스에는 DMG가 없어 릴리스 페이지를 엽니다.", "This release has no DMG, so the releases page opens instead."))
            if !rel.notes.isEmpty {
                ScrollView {
                    Text(rel.notes)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.surfaceSunken))
            }
            HStack(spacing: 10) {
                Button(uiLang("릴리스 페이지", "Releases page")) { NSWorkspace.shared.open(rel.pageURL) }
                    .buttonStyle(.bordered)
                Button(rel.dmgURL != nil ? uiLang("설치", "Install") : uiLang("열기", "Open")) { checker.installPending() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.accent)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }

    private func infoBlock(icon: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(body)
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

    private var downloadSizeText: String? {
        guard let bytes = checker.pending?.dmgSize, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
