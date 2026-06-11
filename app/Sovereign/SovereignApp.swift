// SovereignApp.swift — app entry. Standalone window app (per product decision).
// On launch: ensure the model is downloaded+valid, then enable the session UI.

import SwiftUI

@main
struct SovereignApp: App {
    @State private var downloader = ModelDownloader()
    @State private var session = SessionController()

    var body: some Scene {
        WindowGroup("Sovereign Whisper") {
            ContentView(session: session, downloader: downloader)
                .frame(minWidth: 720, minHeight: 480)
                .task { downloader.ensureModel() }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Settings { SettingsView(session: session, downloader: downloader) }
    }
}
