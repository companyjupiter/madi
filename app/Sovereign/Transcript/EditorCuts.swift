// EditorCuts.swift — editor-facing cut analysis over the per-word transcript.
// Pure post-process on the existing Word/Line model (timestamps + text); no
// engine change. The building blocks for the one-click "tighten" cut-list:
//   · fillers  (E1) — disfluency words to ripple-delete
//   · silences (E2) — dead-air gaps to tighten
// A CutRange is a [start,end) span the editor can remove from the timeline.

import Foundation

struct CutRange: Equatable {
    var start: Double
    var end: Double
    var kind: String        // "filler" | "silence"
    var label: String       // the filler word, or "" for silence
    var duration: Double { max(0, end - start) }
}

enum EditorCuts {
    /// Unambiguous disfluencies only. Content-ambiguous words (like, you know,
    /// 그, 저, 뭐, 막, 이제, ah) are deliberately EXCLUDED — a false positive here
    /// means a wrong cut, so the lexicon errs toward precision over recall.
    static let fillerLexicon: Set<String> = [
        // English
        "um", "umm", "ummm", "uhm", "uh", "uhh", "uhhh", "er", "err", "erm",
        "hmm", "hm", "hmmm", "mm", "mmm", "mhm", "uh-huh", "huh",
        // Korean
        "음", "으음", "음음", "어", "어어", "엄", "에", "흠",
    ]

    /// Lowercase, trim whitespace, strip surrounding punctuation (so "Um," and
    /// "uh…" still match). Internal characters are kept.
    static func normalize(_ s: String) -> String {
        let punct = CharacterSet(charactersIn: ",.!?…\"'`’”“()-—· ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punct)
            .lowercased()
    }

    /// Filler-word occurrences as removable cut ranges, in transcript order.
    static func fillers(_ lines: [Line]) -> [CutRange] {
        var out: [CutRange] = []
        for l in lines {
            for w in l.words where fillerLexicon.contains(normalize(w.text)) {
                out.append(CutRange(start: w.t0, end: w.t1, kind: "filler",
                                    label: w.text.trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }
}
