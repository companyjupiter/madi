import Foundation

/// Pure follow-mode state machine for the live transcript (P0, 2026-09-03).
///
/// Invariants the view used to violate:
/// - Follow is released ONLY by user intent (upward wheel/trackpad, scrollbar
///   drag, an explicit jump elsewhere). Geometry NEVER releases it: content that
///   grows above the viewport (late translations, speaker regroups, merges) moves
///   the bottom gap without any user action, and that used to flip follow off —
///   the "view sits at 00:05:41 while the session is at 17:39" bug.
/// - The "N new" count is derived from line identity/time, not from
///   `lines.count` deltas: the live tail legitimately shrinks on merges, and a
///   count-delta counter reset to 0 on every merge (47 → 53 → 4).
/// - Reaching the bottom (by the user or by the pill) re-arms follow and clears
///   the count in one place.
///
/// Foundation-only so it compiles into the headless test package; the view is a
/// thin adapter that feeds it events and executes the returned action.
struct TranscriptFollowModel: Equatable {
    struct LineRef: Equatable {
        let id: UUID
        let end: Double
        init(id: UUID, end: Double) { self.id = id; self.end = end }
    }
    enum Action: Equatable {
        case none
        /// Snap the viewport to the live tail (un-animated): follow holds but the
        /// content drifted (growth above or below the viewport).
        case pinToTail
    }

    /// The reader wants to stay glued to the newest line.
    private(set) var following = true
    /// Viewport bottom is within `nearZone` of the content bottom.
    private(set) var atBottom = true
    /// Lines that landed since the reader last saw the tail (pill count).
    private(set) var unseen = 0
    /// Identity/time of the last line the reader has seen at the tail.
    private(set) var seenTailID: UUID? = nil
    private(set) var seenTailEnd: Double = -1

    /// Gap (pt) at which the view counts as "at the bottom" for the pill.
    var nearZone: Double = 120
    /// Gap (pt) beyond which a following view is snapped back to the tail.
    var pinTolerance: Double = 2
    /// A downward wheel within this gap re-arms follow.
    var rearmZone: Double = 160
    /// Wheel deltas at or below this magnitude are jitter, not intent.
    var wheelDeadband: Double = 2

    // MARK: inputs

    /// New scroll geometry. `gap` = content bottom − viewport bottom (0 = glued).
    /// Never changes `following`; only refreshes `atBottom` and asks for a pin.
    mutating func geometry(gap: Double, isLive: Bool, lines: [LineRef]) -> Action {
        atBottom = gap <= nearZone
        if atBottom { markSeen(lines) }
        return (following && isLive && gap > pinTolerance) ? .pinToTail : .none
    }

    /// A wheel/trackpad scroll over the transcript. Positive `deltaY` = the
    /// reader scrolls UP (away from the tail) — the only ordinary release.
    mutating func userScrolled(deltaY: Double, gap: Double) {
        if deltaY > wheelDeadband { following = false }
        else if deltaY < -wheelDeadband, gap <= rearmZone { following = true }
    }

    /// The reader asked to look elsewhere (review jump, find match): explicit
    /// intent, so follow releases without a wheel event.
    mutating func programmaticJump() { following = false }

    /// Lines changed (append, merge, relabel). Recomputes the pill count from
    /// identity; a merge that removes the seen tail id falls back to time.
    mutating func linesChanged(_ lines: [LineRef]) {
        if lines.isEmpty { reset(); return }
        if atBottom || following { markSeen(lines); return }
        if let id = seenTailID, let idx = lines.firstIndex(where: { $0.id == id }) {
            unseen = lines.count - idx - 1
        } else if seenTailEnd >= 0 {
            unseen = lines.filter { $0.end > seenTailEnd + 0.001 }.count
        } else {
            markSeen(lines)
        }
    }

    /// "N new" pill tapped: jump to the tail and follow again.
    mutating func pillTapped(_ lines: [LineRef]) -> Action {
        following = true
        markSeen(lines)
        return .pinToTail
    }

    mutating func reset() {
        following = true; atBottom = true; unseen = 0; seenTailID = nil; seenTailEnd = -1
    }

    private mutating func markSeen(_ lines: [LineRef]) {
        unseen = 0
        if let last = lines.last { seenTailID = last.id; seenTailEnd = last.end }
    }
}
