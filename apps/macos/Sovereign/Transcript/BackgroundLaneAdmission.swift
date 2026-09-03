import Foundation

/// P4 (2026-09-03, live 0.3.6 KO→EN·日): the two periodic background lanes —
/// the rolling live summary (30 s tick) and the action rail (18 s tick) — were
/// admitted only while the caption lane was completely idle
/// (`translateQueueDepth == 0, translateBacklog == 0`). That reads as "wait for
/// a quiet moment", but on a fast speaker with two targets the committed queue
/// never reaches zero: the observed session held a backlog from 00:01:30
/// onward and the summary pane stayed frozen at its first three bullets for the
/// next nine minutes. "Only when idle" and "never" are the same rule whenever
/// the machine is at capacity, which is exactly when a rolling summary is most
/// useful.
///
/// The fix is the shape P1 already used for the preview lane: keep the idle
/// fast path, and add a starvation valve. A lane that has made no progress for
/// `starvedAfter` seconds submits anyway. It cannot jump the queue by doing so —
/// background work sits at `DNAEngineBroker.Priority.postSession`/`.liveRail`,
/// below both caption lanes, and the broker only releases it once the caption
/// pressure clears or the request itself ages past
/// `DNAEngineBroker.backgroundAgingSeconds`. So the valve changes *whether* the
/// work is ever queued, not the order in which the engine serves it.
enum BackgroundLaneAdmission {
    /// No progress for this long ⇒ waiting for an idle caption lane has become
    /// indistinguishable from never running. Matches the broker's own aging
    /// valve (`DNAEngineBroker.backgroundAgingSeconds`), so a request admitted
    /// here waits at most one more valve period before it is served.
    static let starvedAfter: TimeInterval = 90

    /// - Parameters:
    ///   - queueDepth: pending + in-flight committed translation turns.
    ///   - backlog: work shed by the live cap, to be backfilled after stop.
    ///   - secondsSinceProgress: since this lane's last landed result, or since
    ///     the lane started when nothing has landed yet. Never negative.
    static func admits(queueDepth: Int,
                       backlog: Int,
                       secondsSinceProgress: Double,
                       starvedAfter: TimeInterval = BackgroundLaneAdmission.starvedAfter) -> Bool {
        if queueDepth == 0 && backlog == 0 { return true }
        return secondsSinceProgress >= starvedAfter
    }
}
