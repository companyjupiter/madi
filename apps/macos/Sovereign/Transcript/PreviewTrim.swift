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
///  · visibleTail — the forced prefix's echo is stripped from the preview text
///    (by text, not time: forced tokens get fake timestamps).
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

    /// The preview's words minus the forced prefix the app sent for that job.
    /// Text, not time: the engine assigns teacher-forced tokens fake 20 ms
    /// timestamps that squeeze the real tail earlier (0.3.18 bundle:
    /// "no|interest|in|it." at 0.00–0.10 s, then "I was" at 0.66 s for audio
    /// that sat 1.5 s in), so a time cut would drop new words. The echo is
    /// verbatim (37/37 in the 0.3.23 bundle); when it is not, the same number
    /// of words is dropped instead.
    static func visibleTail(words: [TimedWord], forced: String) -> String {
        let text = join(words.map(\.text))
        let f = forced.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return text }
        if text.hasPrefix(f) { return String(text.dropFirst(f.count)).trimmingCharacters(in: .whitespaces) }
        let k = f.split(separator: " ", omittingEmptySubsequences: true).count
        return trimByCount(text, dropping: k)
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
