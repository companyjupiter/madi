// SovereignApp.swift — app entry. Standalone window app (per product decision).
// On launch: ensure the model is downloaded+valid, then enable the session UI.
//
// AppDelegate forces foreground activation: a swiftc-assembled bundle (no
// Xcode build phases) can launch without becoming the active app, leaving the
// window buried behind others — observed in hardware test 3.

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        presentEightGBGuideIfNeeded()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func presentEightGBGuideIfNeeded() {
        // The model onboarding is the first-launch guide. Do not cover it with a
        // browser window; the detailed 8 GB manual can surface on a later launch.
        guard AssetManifest.modelIsValid() else { return }
        let defaults = UserDefaults.standard
        let revision = defaults.integer(forKey: LowMemoryGuidePolicy.presentedRevisionKey)
        guard LowMemoryGuidePolicy.shouldPresent(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            presentedRevision: revision) else { return }
        let lang = UILanguage(rawValue: defaults.string(forKey: "uiLanguage") ?? "") ?? .ko

        // Let the main window activate first, then surface the bundled offline
        // document. Mark it seen only when Launch Services accepted the URL.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if SovereignApp.openManual(
                sectionID: LowMemoryGuidePolicy.manualSectionID,
                language: lang) {
                UserDefaults.standard.set(
                    LowMemoryGuidePolicy.currentRevision,
                    forKey: LowMemoryGuidePolicy.presentedRevisionKey)
            }
        }
    }
}

/// App appearance override. System follows macOS; Light/Dark force it.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { label(.ko) }
    func label(_ lang: UILanguage) -> String {
        switch self {
        case .system: return lang("시스템", "System")
        case .light:  return lang("라이트", "Light")
        case .dark:   return lang("다크", "Dark")
        }
    }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

@main
struct SovereignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let sparkleUpdater = SparkleUpdater()
    @State private var downloader = ModelDownloader()
    @State private var session = SessionController()
    @State private var translateDownloader = TranslateModelDownloader()
    @State private var dictation = DictationController()
    @State private var betaGate = BetaGate()
    @State private var updateChecker = UpdateChecker()
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    var body: some Scene {
        WindowGroup("Madi") {
            ContentView(session: session, downloader: downloader,
                        translateDownloader: translateDownloader, betaGate: betaGate)
                .preferredColorScheme(appearance.colorScheme)
                .task { downloader.ensureModel() }
                .task { dictation.micBusy = { session.phase == .recording || session.phase == .paused } }
        }
        .windowStyle(.titleBar)
        // ContentView drives the window size imperatively (compact "Set to start"
        // frame ↔ expanded working layout), so leave resizing automatic here.
        .windowResizability(.automatic)
        .defaultSize(width: 500, height: 900)
        .commands {
            // ⌘K command palette. Registered as a scene command (not an in-view
            // Button) so the shortcut fires app-wide regardless of view focus/layout
            // — the old zero-size, zero-opacity in-view Button never registered its
            // ⌘K. Bonus: it now appears in the View menu, so ⌘K is discoverable.
            CommandGroup(after: .toolbar) {
                Button(uiLang("명령 팔레트", "Command Palette")) { session.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            // ⌘F — find within the current transcript (Edit menu). Scene command for
            // the same reliability reason as ⌘K; ContentView owns the find bar.
            CommandGroup(after: .textEditing) {
                Button(uiLang("전사문에서 찾기", "Find in Transcript")) { session.showFindBar = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            // Replace the empty default Help menu: bundled user manual +
            // update / info (the latter two open dedicated windows).
            CommandGroup(replacing: .help) {
                Button(uiLang("Madi 사용자 매뉴얼", "Madi User Manual")) {
                    Self.openManual(sectionID: "01-getting-started", language: uiLang)
                }
                    .keyboardShortcut("?", modifiers: .command)
                Divider()
                HelpMenuExtras(sparkleUpdater: sparkleUpdater)
            }
        }

        // Info window (Help → 정보) — version, channel, beta lifecycle.
        Window(uiLang("Madi 정보", "About Madi"), id: Self.infoWindowID) {
            InfoView(betaGate: betaGate, sparkleUpdater: sparkleUpdater)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Update window (Help → 업데이트 설치) — GitHub Releases check + install.
        Window(uiLang("Madi 업데이트", "Madi Update"), id: Self.updateWindowID) {
            UpdateView(checker: updateChecker)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings { SettingsView(session: session, downloader: downloader, translateDownloader: translateDownloader, dictation: dictation) }
    }

    static let infoWindowID = "madi-info"
    static let updateWindowID = "madi-update"

    /// Open the bundled, self-contained user manual (Resources/manual/index.html)
    /// in the default browser. Works fully offline.
    @discardableResult
    static func openManual(sectionID: String, language: UILanguage) -> Bool {
        guard let base = Bundle.main.url(
            forResource: "index", withExtension: "html", subdirectory: "manual"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.fragment = "\(language.rawValue)-\(sectionID)"
        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// The two Help-menu items that open windows. Split into its own View so it can
/// read `@Environment(\.openWindow)` (menu Buttons in `.commands` otherwise have
/// no scene-opening environment).
private struct HelpMenuExtras: View {
    @Environment(\.openWindow) private var openWindow
    let sparkleUpdater: SparkleUpdater
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko
    var body: some View {
        if LowMemoryGuidePolicy.isEightGBClass(
            physicalMemory: ProcessInfo.processInfo.physicalMemory) {
            Button(uiLang("8GB Mac 사용 가이드", "8 GB Mac Guide", "8 GB Mac 利用ガイド")) {
                SovereignApp.openManual(
                    sectionID: LowMemoryGuidePolicy.manualSectionID,
                    language: uiLang)
            }
            Divider()
        }
        Button(uiLang("업데이트 설치…", "Install Update…")) { sparkleUpdater.checkForUpdates() }
            .disabled(!sparkleUpdater.canCheckForUpdates)
        Button(uiLang("수동 업데이트 다운로드…", "Manual Update Download…")) {
            openWindow(id: SovereignApp.updateWindowID)
        }
        Button(uiLang("정보", "About")) { openWindow(id: SovereignApp.infoWindowID) }
    }
}
