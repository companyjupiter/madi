// SparkleUpdater.swift — thin app-owned wrapper around Sparkle 2's standard
// self-updater. The legacy UpdateChecker remains as a manual DMG fallback; this
// path is the real one-click app replacement flow.

import Foundation

#if canImport(Sparkle)
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
#else
// SPARKLE_ENABLED=0 builds compile without Sparkle.framework on the search
// path; the updater becomes inert (menu item disabled) and the manual
// UpdateChecker remains the only update path.
@MainActor
final class SparkleUpdater {
    var canCheckForUpdates: Bool { false }
    func checkForUpdates() {}
    func checkForUpdatesInBackground() {}
}
#endif
