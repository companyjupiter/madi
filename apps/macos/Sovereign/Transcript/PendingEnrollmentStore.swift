// PendingEnrollmentStore — a tiny Foundation-only buffer for speaker-name →
// voiceprint enrollments that must be DEFERRED until after the engine flushes.
//
// WHY THIS EXISTS (the enrollment-timing bug):
//   The engine dumps each speaker's centroid to `voiceprintsDir/.last/spk<id>.vec`
//   only AFTER it receives "FLUSH" (i.e. at SessionController.stop() → engineDidFlush).
//   But the user names a speaker MID-session (renameSpeaker, called while recording).
//   At that moment no `.last/spk<id>.vec` exists yet, so enrollVoiceprint() silently
//   no-ops and the name never enrolls.
//
//   Fix: buffer every mid-session name here (id → name). When the session finalizes
//   — AFTER the engine has flushed its centroids — drain this buffer and enroll each
//   one for real. Last-write-wins per speaker id (renaming the same speaker twice in
//   one session keeps only the final name), matching the live speakerNames map.
//
// No SwiftUI / AppKit — pure value logic so it unit-tests headless in SovereignCore.
import Foundation

/// Buffers mid-session speaker names so their voiceprints enroll once the engine
/// has dumped this session's centroids. Reset per session.
struct PendingEnrollmentStore {

    /// id → most-recent name the user assigned to that speaker this session.
    /// Trimmed; an empty/whitespace name REMOVES the pending entry (the user
    /// cleared the name back to "화자 N", so there is nothing to enroll).
    private(set) var names: [Int: String] = [:]

    init() {}

    /// Buffer (or update) a pending enrollment. Empty/whitespace name clears the
    /// entry for that id — mirrors renameSpeaker() clearing speakerNames[id].
    mutating func add(id: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { names[id] = nil; return }
        names[id] = trimmed
    }

    /// Remove a single pending entry (e.g. the user cleared one speaker's name).
    mutating func remove(id: Int) { names[id] = nil }

    /// True when there is nothing to enroll.
    var isEmpty: Bool { names.isEmpty }

    /// Number of buffered enrollments.
    var count: Int { names.count }

    /// Snapshot the buffered (id, name) pairs for draining at finalize-time.
    /// Sorted by id so enrollment order is deterministic (testable).
    func pending() -> [(id: Int, name: String)] {
        names.keys.sorted().map { (id: $0, name: names[$0]!) }
    }

    /// Merge the buffered names into a final id→name map (e.g. to reconcile with
    /// the live speakerNames before persisting). Buffered names win on conflict
    /// (the buffer is the user's explicit, most-recent intent). Non-mutating.
    func flushed(into base: [Int: String]) -> [Int: String] {
        var out = base
        for (id, name) in names { out[id] = name }
        return out
    }

    /// Drop every buffered entry — call at session reset.
    mutating func clear() { names.removeAll() }
}
