// SpeakerDisplayNumber.swift — stable display numbers for acoustic speaker ids.
//
// Engine speaker ids are raw acoustic cluster indices, NOT display numbers. They
// are minted with gaps, the periodic live recluster can move a window from id 0
// to id 7, and SPKFIX relabels arrive retroactively (transcribe.zig
// liveVisibleSpeaker → SPKFIX). Rendering those ids straight to the user is what
// makes ONE person appear as "Speaker 1" and then, several revisions later, as
// "Speaker 8".
//
// This assigns each id a number in first-seen order and NEVER reassigns it, so
// the dominant speaker — the first one heard, by definition — keeps number 1 for
// the whole session no matter how the clustering is revised underneath. The
// engine ids stay untouched: they remain the keys for voiceprints (.last/spk<id>.vec),
// exports and the LLM reconciler. This is a display mapping only.

import Foundation

struct SpeakerDisplayNumber: Equatable {
    /// id → display number (1-based). Append-only within a session.
    private(set) var numbers: [Int: Int] = [:]
    private var next = 1

    /// Number for `id`, minting the next one on first sight. Unknown (255) never
    /// gets one — it renders as 미확인 and is not a nameable person.
    @discardableResult
    mutating func assign(_ id: Int) -> Int? {
        guard id != SpeakerID.unknown else { return nil }
        if let n = numbers[id] { return n }
        numbers[id] = next
        next += 1
        return next - 1
    }

    func number(_ id: Int) -> Int? { numbers[id] }

    /// Mint numbers for any newcomers, in the order given. Callers pass ids in
    /// transcript (time) order, which is what makes number 1 the first speaker.
    /// Idempotent: an already-numbered id keeps the number it was given.
    mutating func assignAll<S: Sequence>(_ ids: S) where S.Element == Int {
        for id in ids { assign(id) }
    }

    /// A merge folded `from` into `into` (over-split fix, acoustic or LLM). The
    /// survivor keeps the LOWER of the two numbers, so discovering that Speaker 1
    /// and Speaker 4 are the same person leaves them as Speaker 1 — never as 4.
    /// `from` intentionally keeps its entry: frozen lines can still carry the old
    /// id until the overlays resolve, and having it map to the same number is
    /// exactly the behaviour we want while that settles.
    mutating func merge(from: Int, into: Int) {
        switch (numbers[from], numbers[into]) {
        case let (a?, b?):
            let survivor = min(a, b)
            numbers[into] = survivor
            numbers[from] = survivor
        case let (a?, nil):
            numbers[into] = a
        default:
            break   // `into` keeps whatever it has; nothing to fold in
        }
    }

    mutating func reset() {
        numbers.removeAll()
        next = 1
    }
}
