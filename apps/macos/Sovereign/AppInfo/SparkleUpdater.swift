// SparkleUpdater.swift — thin app-owned wrapper around Sparkle 2's standard
// self-updater. The legacy UpdateChecker remains as a manual DMG fallback; this
// path is the real one-click app replacement flow.

import Foundation
import Sparkle

@MainActor
final class SparkleUpdater {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }
}
