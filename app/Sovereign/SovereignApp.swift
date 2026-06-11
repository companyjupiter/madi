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

@main
struct SovereignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var downloader = ModelDownloader()
    @State private var session = SessionController()

    var body: some Scene {
        WindowGroup("Sovereign Whisper") {
            ContentView(session: session, downloader: downloader)
                .frame(minWidth: Theme.Size.windowMinW, minHeight: Theme.Size.windowMinH)
                .task { downloader.ensureModel() }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Settings { SettingsView(session: session, downloader: downloader) }
    }
}
