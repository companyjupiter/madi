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
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// App appearance override. System follows macOS; Light/Dark force it.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { self == .system ? "시스템" : self == .light ? "라이트" : "다크" }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

@main
struct SovereignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var downloader = ModelDownloader()
    @State private var session = SessionController()
    @State private var translateDownloader = TranslateModelDownloader()
    @State private var dictation = DictationController()
    @State private var betaGate = BetaGate()
    @State private var updateChecker = UpdateChecker()
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup("Madi") {
            ContentView(session: session, downloader: downloader, betaGate: betaGate)
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
                Button("명령 팔레트") { session.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            // Replace the empty default Help menu: bundled user manual +
            // update / info (the latter two open dedicated windows).
            CommandGroup(replacing: .help) {
                Button("Madi 사용자 매뉴얼") { Self.openManual() }
                    .keyboardShortcut("?", modifiers: .command)
                Divider()
                HelpMenuExtras()
            }
        }

        // Info window (Help → 정보) — version, channel, beta lifecycle.
        Window("Madi 정보", id: Self.infoWindowID) {
            InfoView(betaGate: betaGate)
                .preferredColorScheme(appearance.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Update window (Help → 업데이트 설치) — GitHub Releases check + install.
        Window("Madi 업데이트", id: Self.updateWindowID) {
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
    private static func openManual() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "manual") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The two Help-menu items that open windows. Split into its own View so it can
/// read `@Environment(\.openWindow)` (menu Buttons in `.commands` otherwise have
/// no scene-opening environment).
private struct HelpMenuExtras: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("업데이트 설치…") { openWindow(id: SovereignApp.updateWindowID) }
        Button("정보") { openWindow(id: SovereignApp.infoWindowID) }
    }
}
