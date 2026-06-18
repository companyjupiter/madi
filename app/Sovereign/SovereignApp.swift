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
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup("Sovereign Whisper") {
            ContentView(session: session, downloader: downloader)
                .frame(minWidth: Theme.Size.windowMinW, minHeight: Theme.Size.windowMinH)
                .preferredColorScheme(appearance.colorScheme)
                .task { downloader.ensureModel() }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)

        Settings { SettingsView(session: session, downloader: downloader, translateDownloader: translateDownloader) }
    }
}
