import Foundation

/// P1 (2026-09-03): load-shedding policy for the committed translation lane.
/// Pure (Foundation-only) so it is unit-tested in the core package.
enum TranslationShedPolicy {
    /// With `committedBacklog` committed turns already queued at or beyond
    /// `threshold`, translate a new committed line into the priority language
    /// only; the other requested targets are shed (they backfill at stop).
    /// `threshold` 0 disables shedding.
    static func committedTargets(requested: [String], priority: String?, committedBacklog: Int,
                                 threshold: Int) -> (send: [String], shed: [String]) {
        guard threshold > 0, committedBacklog >= threshold, requested.count > 1,
              let p = priority, requested.contains(p) else { return (requested, []) }
        return ([p], requested.filter { $0 != p })
    }
}
