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
    var displayWords: [Word] { displayWords(from: 0) }

    /// P2: the same view from a committed-prefix offset — the live rebuild only
    /// regroups words past the frozen prefix, so it must not copy every
    /// committed word of the session per event.
    func displayWords(from: Int) -> [Word] {
        var out = Array(committed[min(from, committed.count)...])
        var live = segBuffer.filter { $0.t0 >= emitted - eps }
        // X1 (2026-09-07): the view applies the SAME seam rules merge() will —
        // virtually. Before this, the held word AND the current segment's
        // re-decode of it were both shown for the ~5 s until the next segment
        // boundary ("thoughts thoughts", "race race escalates, escalates,"),
        // the store decided a line boundary BETWEEN them (the held word is the
        // window-edge decode — "implications." conf 0.24 — so it usually
        // carries a hallucinated period) and recorded that verdict in the P15
        // ledger under the held word's id, which the re-decode then inherited:
        // the break outlived the period. 0.3.18 live: 35 of 136 breaks (26 %)
        // had this signature (next word starting before the previous ended),
        // 31 doubled words, 37 of 110 rows translated twice.
        if let h = held {
            if Self.replacesHeld(h, incoming: live, eps: eps) {
                live.removeAll { $0.t1 <= h.t0 + eps }
                if live.isEmpty { out.append(h) }
                else { live[0] = Word(id: h.id, t0: live[0].t0, t1: live[0].t1, text: live[0].text, conf: live[0].conf) }
            } else {
                out.append(h)
            }
        }
        if let last = out.last, let f = live.first, Self.isSeamDuplicate(f, after: last) { live.removeFirst() }
        out.append(contentsOf: live)
        return out
    }

    /// Does the new segment's first word take the held word's place? Yes when
    /// it covers it (t0 ≤ held.t1 + eps: the overlap re-decoded the same audio
    /// with right context) — and, X2 (2026-09-07), when the held word is a
    /// window-tail STUB and speech simply continues: the decoder closes the
    /// audio edge with a token that is not a word ("…company with AI." — 40 ms,
    /// conf 0.24, the next window's "the" starting 0.16 s later). A stub before
    /// a real pause is kept: nothing re-decodes it, so it may be speech.
    static let tailStubMaxDuration = 0.06
    static let tailStubMaxConf = 0.35
    static let stubContinuation = 0.3
    static func isTailStub(_ w: Word) -> Bool {
        w.t1 - w.t0 < tailStubMaxDuration && w.conf < tailStubMaxConf
    }
    static func replacesHeld(_ h: Word, incoming: [Word], eps: Double) -> Bool {
        guard let f = incoming.first else { return false }
        if f.t0 <= h.t1 + eps { return true }
        return isTailStub(h) && f.t0 - h.t1 < stubContinuation
    }

    /// The held word's id (nil = none): a line ending with it is still one
    /// re-decode away from its final text (SessionController defers its
    /// translation while the preview is live).
    var heldWordID: UUID? { held?.id }
    /// Held word text (nil = none) and the committed watermark — what the live
    /// preview must not repeat (PreviewTrim).
    var heldWordText: String? { held?.text }
    var heldWord: Word? { held }
    var committedEnd: Double { emitted }
    /// Committed words starting at or after `t` (the tail — a reverse scan).
    func committed(since t: Double) -> [Word] {
        var i = committed.count
        while i > 0, committed[i - 1].t0 >= t { i -= 1 }
        return Array(committed[i...])
    }
    /// DISPLAYED words starting at or after `t`: committed + held + the current
    /// segment's words, exactly what the transcript shows in black (PreviewTrim:
    /// the preview must not repeat any of them).
    func displayed(since t: Double) -> [Word] {
        var i = committed.count
        while i > 0, committed[i - 1].t0 >= t { i -= 1 }
        return displayWords(from: i).filter { $0.t0 >= t }
    }

    mutating func add(_ w: Word) { segBuffer.append(w) }

    /// A new segment's word section began: merge the previous segment's buffer.
    mutating func segmentBreak() { merge(final: false) }

    /// FLUSH: merge the last buffer and release the held word.
    mutating func finish() { merge(final: true) }

    private mutating func merge(final: Bool) {
        let rawCount = segBuffer.count
        var incoming = segBuffer.filter { $0.t0 >= emitted - eps }
        segBuffer = []
        let heldBefore = held?.text
        let seamBefore = seamDuplicatesDropped, instantBefore = sameInstantDuplicatesDropped
        let committedBefore = committed.count
        defer {
            DebugLog.shared?.emit("store", "merge", [
                "final": final, "raw": rawCount, "pastWatermark": incoming.count + (held == nil ? 0 : 0),
                "held": heldBefore ?? "", "heldAfter": held?.text ?? "",
                "committed": committed.count - committedBefore,
                "seamDropped": seamDuplicatesDropped - seamBefore,
                "sameInstantDropped": sameInstantDuplicatesDropped - instantBefore,
                "emitted": emitted])
        }

        if let h = held {
            held = nil
            // The new segment re-decoded the held word's region with full right
            // context — prefer its version. Only keep the held word if the new
            // segment starts clearly AFTER it (no re-decode coverage).
            let replaced = Self.replacesHeld(h, incoming: incoming, eps: eps)
            if !replaced { commit(h) }
            else {
                incoming.removeAll { $0.t1 <= h.t0 + eps } // drop pre-held strays
                // Only strays came: nothing re-decoded the held word — keep
                // holding it (it used to vanish here).
                if incoming.isEmpty { held = h; return }
                // P1 (2026-09-03): the re-decode REPLACES the held word, so it
                // inherits the held word's identity. Line ids, the P15 boundary
                // ledger and per-line translations are keyed by the first word's
                // id — a fresh UUID here changed the line's id at every segment
                // boundary (rows torn down, translations orphaned, boundaries
                // re-decided → post-commit merges).
                if let f = incoming.first {
                    incoming[0] = Word(id: h.id, t0: f.t0, t1: f.t1, text: f.text, conf: f.conf)
                }
            }
        }

        guard !incoming.isEmpty else { return }
        // L2 (2026-09-06): seam re-decode duplicate. The overlap re-decodes the
        // previous window's last word with DRIFTED timestamps — "that." [4.6–4.9]
        // comes back as "that." [4.95–5.2] — so it passes the watermark and the
        // held-word replacement (which needs t0 ≤ held.t1 + eps) and commits as a
        // second word; live it then opened its own row ("…center of that." /
        // "that.", "Is it still 50 years?" ×2). Measured on the 0.3.14 live
        // events: 18 adjacent identical words in 10 minutes, 8 of them rows.
        // At the seam only — the first incoming word against the last committed
        // one — same text (case/punctuation-insensitive) starting within
        // `seamDuplicateGap` of the previous word's end is the same audio, not a
        // stutter (a stutter is decoded inside ONE window and never sits exactly
        // on the seam). Drop it and advance the watermark past it.
        // The window may also open with the re-decode AND a stub copy of it
        // ("you? You …" — the second 20 ms long), so the first TWO words are
        // checked, each against the word that will precede it.
        if let last = committed.last, Self.isSeamDuplicate(incoming[0], after: last) {
            seamDuplicatesDropped += 1
            emitted = max(emitted, incoming[0].t1)
            incoming.removeFirst()
        }
        // …and a stub copy right after the re-decode ("you? You", the copy 20 ms
        // long). Only a copy that could not be a spoken word — shorter than
        // `stubMaxDuration` or overlapping the word before it — is dropped; a
        // real backchannel repeat ("네 네 네", each 0.3 s, abutting) stays.
        if incoming.count >= 2, Self.isSeamDuplicate(incoming[1], after: incoming[0]),
           incoming[1].t1 - incoming[1].t0 < Self.stubMaxDuration || incoming[1].t0 < incoming[0].t1 - 0.05 {
            seamDuplicatesDropped += 1
            incoming.remove(at: 1)
        }
        guard !incoming.isEmpty else { return }
        if !final { held = incoming.removeLast() }
        for w in incoming { commit(w) }
        if final, let h = held { commit(h); held = nil }
    }
    static let seamDuplicateGap = 0.6
    static let stubMaxDuration = 0.12
    private(set) var seamDuplicatesDropped = 0
    private(set) var sameInstantDuplicatesDropped = 0
    private static func seamKey(_ w: Word) -> String {
        w.text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func isSeamDuplicate(_ w: Word, after prev: Word) -> Bool {
        let k = seamKey(w)
        return !k.isEmpty && k == seamKey(prev) && w.t0 - prev.t1 < seamDuplicateGap
    }
    /// Two words cannot occupy the same instant: an identical word whose start
    /// sits within 0.1 s of the previous word's start is the decoder emitting
    /// the same token twice ("and" ×5 with identical spans, "What" twice),
    /// not speech. Dropped at commit, any position.
    private func isSameInstantDuplicate(_ w: Word) -> Bool {
        guard let last = committed.last else { return false }
        let k = Self.seamKey(w)
        return !k.isEmpty && k == Self.seamKey(last) && abs(w.t0 - last.t0) < 0.1
    }

    /// Degenerate-repeat guard. The engine resets decode state per chunk, so the
    /// in-decode no_repeat_ngram can't see across chunks — a hallucinated short
    /// phrase repeating across segments ("ndo.com. ndo.com. ndo.com…") slips
    /// through and the merged line explodes. Once the SAME 1–6-word phrase has
    /// repeated `maxPhraseRepeats` times at the tail, drop further repeats.
    /// (5+ verbatim repeats of a short phrase is degenerate, not real speech.)
    static let maxPhraseRepeats = 4

    private func normWord(_ w: Word) -> String {
        w.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Would appending `w` extend a tail run of an identical p-word phrase beyond
    /// the cap? Scans only the recent tail (bounded work per commit).
    private func isRunawayRepeat(adding w: Word) -> Bool {
        let cap = Self.maxPhraseRepeats
        let window = 6 * (cap + 1)                      // enough tail for any p≤6 run
        var hist = committed.suffix(window).map(normWord)
        hist.append(normWord(w))
        let n = hist.count
        for p in 1...6 {
            guard n >= 2 * p else { continue }
            // count contiguous identical p-grams ending at the (hypothetical) tail
            var reps = 1
            var i = n - p
            while i - p >= 0, Array(hist[(i - p)..<i]) == Array(hist[i..<(i + p)]) {
                reps += 1; i -= p
            }
            if reps > cap { return true }
        }
        return false
    }

    private mutating func commit(_ w: Word) {
        // advance the watermark even when dropped, so the overlap dedup stays
        // consistent and later segments don't re-introduce the same repeat.
        if isSameInstantDuplicate(w) { sameInstantDuplicatesDropped += 1; emitted = max(emitted, w.t1); return }
        if isRunawayRepeat(adding: w) { emitted = max(emitted, w.t1); return }
        committed.append(w)
        emitted = max(emitted, w.t1)
    }
}
