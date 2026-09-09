import Foundation

/// PreviewTrim (2026-09-10): what of the live preview may be shown.
///
/// The preview window is overlapTail + pending — it opens 1.5 s BEFORE the
/// committed text ends, so every preview (and every closed segment's in-decode
/// partial) starts by re-decoding words the transcript already shows, usually
/// in another spelling. Live 0.3.23 Korean: at every 5 s boundary the gray
/// text restarted 3–5 words back ("…별이 파편이 사방" → "별 파편이 사방으로 …"),
/// which read as constant rewriting. Three pure rules, unit-tested:
///  · forcedPrefix — the committed words inside the window are teacher-forced
///    (S2 `%%FP`), so the preview's echo of the overlap equals the transcript;
///    the interim gate's agreed text rides on top when it extends them.
///  · visibleTail — preview words whose (window-relative) time ends before the
///    committed watermark are dropped; a first word equal to the held word too.
///  · trimByCount — a closed segment's token-level partial has no times: drop
///    as many leading words as the transcript committed inside that segment.
enum PreviewTrim {
    struct TimedWord: Equatable {
        let t0: Double, t1: Double, text: String
    }

    static let eps = 0.05

    static func forcedPrefix(committed: [String], gate: String) -> String {
        let base = committed.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let g = gate.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { return g }
        return g.hasPrefix(base) && g.count > base.count ? g : base
    }

    /// `heldEnd`: end time of the merger's held word (nil = none). A preview
    /// word that STARTS before the committed watermark re-decodes committed
    /// audio; one that starts inside the held word's span re-decodes the held
    /// word ("사방" → "사방으로") — the merger will replace it, the view must
    /// not show both.
    static func visibleTail(words: [TimedWord], windowStart: Double, committedEnd: Double,
                            heldEnd: Double?) -> String {
        let cut = max(committedEnd, heldEnd ?? committedEnd)
        let tail = words.drop { windowStart + $0.t0 < cut - eps }
        return join(tail.map(\.text))
    }

    static func trimByCount(_ text: String, dropping k: Int) -> String {
        guard k > 0 else { return text }
        let w = text.split(separator: " ", omittingEmptySubsequences: true)
        return w.count > k ? w.dropFirst(k).joined(separator: " ") : ""
    }

    /// Same join the preview text used to get: a space before every word
    /// except trailing punctuation tokens.
    static func join(_ words: [String]) -> String {
        var out = ""
        for t in words {
            if !out.isEmpty, t.first.map({ !",.!?…".contains($0) }) ?? true { out += " " }
            out += t
        }
        return out
    }

    private static func seamKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
