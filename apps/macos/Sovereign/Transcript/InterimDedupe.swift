import Foundation

/// P2 (2026-09-03): the gray live hypothesis is rendered INLINE after the last
/// committed line, so the part of it that is already committed must be dropped
/// or the reader sees the same words twice. The previous rule accepted only an
/// EXACT suffix/prefix overlap (last m committed tokens == first m hypothesis
/// tokens). Live 0.3.5 showed the two ways that fails:
///
///   1. boundary rewrite — the preview re-decodes the boundary word differently
///      ("… goes the wrong way and" vs "goes the wrong way. A lot of …",
///      "… peacock gets yes" vs "peacock gets espn gets …"): one token differs
///      at the seam, no m matches, the whole sentence is shown again in gray;
///   2. window spanning lines — the open window covers several committed lines
///      ("Where's your ring? They didn't give you. They didn't yet. No, I'm
///      going to." vs hypothesis "… Where's your ring? They didn't give you…
///      They didn't yet. No, I'm gonna"): the hypothesis head sits in the
///      MIDDLE of the committed tail, again no suffix/prefix match.
///
/// Rule: find the longest common contiguous token block between the committed
/// tail and the hypothesis (normalized: lowercased, punctuation trimmed). Accept
/// it as the alignment when it is at least `minAnchor` tokens AND ends close to
/// the tail's end (the tail tokens after the block are no more than the block
/// itself, capped at 6 — a repeated trigram in the middle of the tail is speech,
/// not a re-decode). Everything in the hypothesis up to the block end plus one
/// token per remaining tail token is committed audio → dropped. The old exact
/// suffix/prefix rule then runs on the remainder (it still catches the plain
/// append-only case and the leftover after a 1:1 consumption).
enum InterimDedupe {
    static func norm(_ s: Substring) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func continuation(committedTail: String, hypothesis: String, minAnchor: Int = 3) -> String {
        let tailToks = committedTail.split(separator: " ").map(norm).filter { !$0.isEmpty }
        let hypRaw = hypothesis.split(separator: " ")
        let hypToks = hypRaw.map(norm)
        guard !tailToks.isEmpty, !hypToks.isEmpty else { return hypothesis }

        var start = 0   // hypothesis tokens already accounted for
        if let block = longestCommonBlock(tailToks, hypToks), block.length >= minAnchor {
            let tailRemaining = tailToks.count - (block.tailEnd + 1)
            let slack = min(6, block.length)
            if tailRemaining <= slack {
                start = min(hypToks.count, block.hypEnd + 1 + tailRemaining)
            }
        }
        // Exact suffix/prefix pass on what is left (the original rule).
        let rest = Array(hypToks[start...])
        if !rest.isEmpty {
            let maxM = min(tailToks.count, rest.count)
            for m in stride(from: maxM, through: 1, by: -1) {
                if Array(tailToks.suffix(m)) == Array(rest.prefix(m)) { start += m; break }
            }
        }
        return hypRaw.dropFirst(start).joined(separator: " ")
    }

    struct Block { let length: Int; let tailEnd: Int; let hypEnd: Int }

    /// Longest common contiguous block; ties prefer the one ending latest in the
    /// tail (closest to the live seam), then earliest in the hypothesis.
    static func longestCommonBlock(_ a: [String], _ b: [String]) -> Block? {
        var best: Block? = nil
        var prev = [Int](repeating: 0, count: b.count + 1)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 0..<a.count {
            for j in 0..<b.count {
                if a[i] == b[j] {
                    let l = prev[j] + 1
                    cur[j + 1] = l
                    if let bb = best {
                        if l > bb.length || (l == bb.length && i > bb.tailEnd) {
                            best = Block(length: l, tailEnd: i, hypEnd: j)
                        }
                    } else {
                        best = Block(length: l, tailEnd: i, hypEnd: j)
                    }
                } else {
                    cur[j + 1] = 0
                }
            }
            swap(&prev, &cur)
            for k in cur.indices { cur[k] = 0 }
        }
        return best
    }
}
