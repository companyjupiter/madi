// BetaGate.swift — runtime observable around AppVersion's beta-expiry logic.
// Holds the current ExpiryStatus, persists/advances the clock-rollback high-water
// mark (AppVersion.evaluateExpiry), and re-checks hourly so a running app crosses
// into "expiring soon" / "expired" without needing a relaunch. The blocking
// screen (ExpiredGateView) and the warning banner both read this.

import Foundation
import Observation

@Observable
@MainActor
final class BetaGate {
    private(set) var status: ExpiryStatus

    var isExpired: Bool { status == .expired }

    /// The hard expiry date, surfaced for the Info window.
    var expiryDate: Date { AppVersion.betaExpiryDate }

    // Internal plumbing (not observed). Written once in init (main actor),
    // cancelled once in the nonisolated deinit → no concurrent access.
    @ObservationIgnored private nonisolated(unsafe) var ticker: Task<Void, Never>?

    init() {
        status = AppVersion.evaluateExpiry()
        // Re-evaluate hourly. Cheap; catches the midnight rollover of a
        // long-running clinic display and the day the warning window opens.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                await MainActor.run { self?.refresh() }
            }
        }
    }

    deinit { ticker?.cancel() }

    func refresh() {
        status = AppVersion.evaluateExpiry()
    }
}
