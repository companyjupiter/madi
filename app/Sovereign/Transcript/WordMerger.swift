// WordMerger.swift — overlap dedup + trailing-word holdback for the live
// word stream. Pure struct (no UI deps) so it is unit-testable, mirroring
// metal/merge_seg.awk semantics:
//
//   Each live segment is transcribed with OVERLAP seconds of left context, so
//   words in the overlap region are decoded TWICE (often with different text:
//   "소버린"/"수버림"). The runner deduped with an `emitted` watermark — only
//   words starting at/after the watermark are accepted — and HELD BACK each
//   segment's trailing word for one round: a word cut by the segment boundary
//   decodes badly, and the next segment's overlap re-decodes it with full
//   right context, so the re-decode wins.
//
// Engine words arrive with GLOBAL times (already offset). Segment boundaries
// are the `=== WORD TIMESTAMPS ===` markers (EngineEvent.wordSectionBegin).

import Foundation

struct WordMerger {
    /// Dedup guard: a word starting >= eps before the watermark is a re-decode
    /// of already-committed audio (matches merge_seg.awk eps=0.05).
    var eps: Double = 0.05

    private(set) var committed: [Word] = []
    private var held: Word?            // trailing word awaiting confirmation
    private var emitted: Double = 0    // exclusive watermark: end of committed text
    private var segBuffer: [Word] = []

    /// Words for display: committed + held + current segment preview (filtered),
    /// so the live view shows fresh words immediately, not one segment late.
    var displayWords: [Word] {
        var out = committed
        if let h = held { out.append(h) }
        out.append(contentsOf: segBuffer.filter { $0.t0 >= emitted - eps })
        return out
    }

    mutating func add(_ w: Word) { segBuffer.append(w) }

    /// A new segment's word section began: merge the previous segment's buffer.
    mutating func segmentBreak() { merge(final: false) }

    /// FLUSH: merge the last buffer and release the held word.
    mutating func finish() { merge(final: true) }

    private mutating func merge(final: Bool) {
        var incoming = segBuffer.filter { $0.t0 >= emitted - eps }
        segBuffer = []

        if let h = held {
            held = nil
            // The new segment re-decoded the held word's region with full right
            // context — prefer its version. Only keep the held word if the new
            // segment starts clearly AFTER it (no re-decode coverage).
            let replaced = incoming.first.map { $0.t0 <= h.t1 + eps } ?? false
            if !replaced { commit(h) }
            else { incoming.removeAll { $0.t1 <= h.t0 + eps } } // drop pre-held strays
        }

        guard !incoming.isEmpty else { return }
        if !final { held = incoming.removeLast() }
        for w in incoming { commit(w) }
        if final, let h = held { commit(h); held = nil }
    }

    private mutating func commit(_ w: Word) {
        committed.append(w)
        emitted = max(emitted, w.t1)
    }
}
