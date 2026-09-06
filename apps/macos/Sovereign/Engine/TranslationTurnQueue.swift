// TranslationTurnQueue.swift — pure scheduling policy for live translation.
//
// The DNA process is serial, so queue order is the product behavior: committed
// captions must beat disposable interim previews, and a newer revision must not
// leave an older pending revision consuming Metal time. Kept separate from the
// process driver so these invariants are headless-testable.

import Foundation

enum TranslationTurnKind: Equatable {
    case interim
    case committed
}

struct TranslationTurn: Equatable {
    let id: UUID
    let lang: String
    let source: String
    let prompt: String
    let prefix: String?
    let body: String?
    var retries: Int
    let kind: TranslationTurnKind
    /// P10-1: this interim turn holds the starvation-guarantee slot. It bypasses
    /// the committed block, survives a committed turn's interim eviction, and is
    /// served before pending committed work — once, so the caption cannot be
    /// starved for longer than the guarantee interval under a committed backlog.
    var reserved: Bool = false
    /// T1: an already-displayed, AGREED translation prefix for this (line, lang)
    /// — the engine prefills it as forced assistant tokens and generates only
    /// the tail, instead of re-decoding text the viewer is already looking at.
    /// Interim turns only; nil = free decode (committed turns, retries).
    var forced: String? = nil
    /// T5/P2: the example TARGET this turn's prompt carried, so the output
    /// sanitizer can strip a replayed copy of it (see stripExampleEcho).
    var exampleTarget: String? = nil
}

/// T5 (2026-09-02): the per-turn prompt body. The instruction head is the cached
/// `%%PFX` prefix ("…Example — "); the body carries the EXAMPLE and the source.
/// The example is the previous committed (source => translation) pair for this
/// target when one exists — Korean drops subjects, and a lone sentence cannot
/// recover them. Measured on a 40-item null-subject probe (PERF_LOG T5): 4B
/// pronoun hit 15→22/40, chrF++ 54.7→57.8 (+38 ms prefill); 2B chrF++ 47.8→53.1
/// and the "Hello => Hello" identity example's think-leak rambling gone
/// (304→148 ms/turn). Without a usable pair it falls back to the in-target
/// anchor, which reproduces the previous prompt byte for byte.
enum TranslatePrompt {
    struct Example: Equatable { let source: String; let target: String }

    /// Layout: "<src> => <tgt> . <text> =>". The former "Now:" marker between the
    /// example and the text is gone: with a real example pair the 4B rendered it
    /// into the target language ("现在：", "이제:") or folded it into the sentence
    /// ("我们现在经常…"), and the leaked line then became the next example. Measured
    /// on the 40-item probe without the marker: 4B pronoun 21/40, chrF++ 58.9 (with
    /// it: 22/40, 57.8); 2B chrF++ 51.0 vs 47.8 anchor-only; marker leaks 0/6 in
    /// EN→KO/ZH/JA and KO→EN on the 4B. The output sanitizer still strips any echo.
    static func body(text: String, example: Example?, anchor: String) -> String {
        let ex = example.map { "\($0.source) => \($0.target)" } ?? "Hello => \(anchor)"
        return "\(ex) . \(text) =>"
    }

    /// An example is usable when both halves are single-line, non-empty and short
    /// enough to keep the prefill in the fixed-cost regime, and it is not the very
    /// sentence being translated (a repeat phrase would otherwise be its own
    /// example and invite echo).
    static func usableExample(_ ex: Example?, for text: String, maxChars: Int = 200) -> Example? {
        guard let ex, !ex.source.isEmpty, !ex.target.isEmpty,
              ex.source.count <= maxChars, ex.target.count <= maxChars,
              !ex.source.contains("\n"), !ex.target.contains("\n"),
              ex.source != text else { return nil }
        return ex
    }
}

struct TranslationQueueEnqueueResult {
    let accepted: Bool
    let displaced: [TranslationTurn]
}

struct TranslationTurnQueue {
    private(set) var turns: [TranslationTurn] = []

    var count: Int { turns.count }
    var isEmpty: Bool { turns.isEmpty }
    var hasCommitted: Bool { turns.contains { $0.kind == .committed } }

    /// Enqueue one target turn. A committed turn evicts all pending interim work;
    /// a newer revision replaces an older pending turn for the same line+language.
    /// Interim work is rejected while committed work is queued or in flight.
    mutating func enqueue(_ turn: TranslationTurn, blockInterim: Bool = false,
                          replaceExisting: Bool = true)
        -> TranslationQueueEnqueueResult {
        if turn.kind == .interim, !turn.reserved, blockInterim || hasCommitted {
            return TranslationQueueEnqueueResult(accepted: false, displaced: [])
        }

        var displaced: [TranslationTurn] = []
        if turn.kind == .committed {
            // A reserved interim survives: evicting it would re-open the
            // starvation window the reservation exists to close.
            displaced.append(contentsOf: removeAll { $0.kind == .interim && !$0.reserved })
        }
        if !replaceExisting,
           turns.contains(where: { $0.id == turn.id && $0.lang == turn.lang }) {
            return TranslationQueueEnqueueResult(accepted: false, displaced: displaced)
        }
        displaced.append(contentsOf: removeAll { $0.id == turn.id && $0.lang == turn.lang })
        turns.append(turn)
        return TranslationQueueEnqueueResult(accepted: true, displaced: displaced)
    }

    /// Highest semantic priority first; newest-first within a lane preserves the
    /// existing live-caption behavior during a backlog.
    var next: TranslationTurn? {
        if let i = turns.lastIndex(where: { $0.reserved }) { return turns[i] }
        if let i = turns.lastIndex(where: { $0.kind == .committed }) { return turns[i] }
        return turns.last
    }

    mutating func popNext() -> TranslationTurn? {
        if let i = turns.lastIndex(where: { $0.reserved }) { return turns.remove(at: i) }
        if let i = turns.lastIndex(where: { $0.kind == .committed }) {
            return turns.remove(at: i)
        }
        return turns.popLast()
    }

    /// Shed oldest queued work to a live cap. The caller decides whether shed
    /// turns need stop-time backfill; superseded turns use `displaced` instead.
    mutating func shedOldest(to maxCount: Int) -> [TranslationTurn] {
        guard maxCount > 0, turns.count > maxCount else { return [] }
        let excess = turns.count - maxCount
        let shed = Array(turns.prefix(excess))
        turns.removeFirst(excess)
        return shed
    }

    mutating func removeAll() { turns.removeAll() }

    private mutating func removeAll(where predicate: (TranslationTurn) -> Bool)
        -> [TranslationTurn] {
        var removed: [TranslationTurn] = []
        turns.removeAll { turn in
            if predicate(turn) {
                removed.append(turn)
                return true
            }
            return false
        }
        return removed
    }
}

/// Conservative output guard for the smaller realtime model. It never rewrites
/// wording: it only removes control-token leakage / exact consecutive loops and
/// identifies replies that are observably in the wrong script so the engine can
/// regenerate them with a source→target-specific prompt.
enum TranslationOutputPolicy {
    // T7 (2026-09-06): runaway generation. Live 0.3.15 showed a 9-word line
    // ("I was actually more into reading and arts.") translated into a
    // ~500-token cycling list of school subjects: the engine decodes greedily
    // with no repetition penalty and the app passed a flat 512-token cap, so a
    // slide into list mode ran to the cap, was painted live, and — because a
    // committed translation becomes the next turn's example — poisoned the next
    // turn. Two bounds, both proportional to the SOURCE: a per-turn token cap
    // sent to the engine (%%MAX) and a character limit on the reply.
    /// Tokens the engine may generate for this source (DNA3 tokenizer: KO/JA/ZH
    /// ≈ 1.3 chars per token, EN ≈ 4). 1.5 × source chars + 24 leaves a
    /// 28-word English line ~250 tokens; the floor covers one-word replies.
    static func tokenCap(source: String) -> Int {
        min(512, max(48, Int(Double(source.count) * 1.5) + 24))
    }
    /// Reply characters beyond which the turn is a runaway, not a translation.
    static func runawayLimit(source: String) -> Int {
        max(80, source.count * 3)
    }
    /// Cut a runaway reply at its last sentence end inside the limit (or hard
    /// at the limit) so the row shows the part that was still a translation.
    static func truncateRunaway(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        if let cut = head.lastIndex(where: { enders.contains($0) }), head.distance(from: head.startIndex, to: cut) >= 8 {
            return String(head[...cut]).trimmingCharacters(in: .whitespaces)
        }
        return head.trimmingCharacters(in: .whitespaces)
    }

    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // DNA has thinking disabled, but the 2B quant can still emit a stray
        // `<think>` frame. Prefer the answer after the final closing tag; remove
        // a complete/incomplete frame when no answer follows it.
        if let close = text.range(of: "</think>", options: .backwards) {
            let suffix = text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty { text = suffix }
            else { text.removeSubrange(close) }
        }
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }

        text = stripPromptMarkerEcho(text)
        return collapseConsecutiveSentences(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The turn body was "<example> . Now: <text> =>" until 0.3.2. With a real
    /// example pair in the slot (T5) the model treated the "Now:" marker as part of
    /// the text and rendered it in the target language ("现在：", "이제:", "今："), or
    /// echoed the separator / the trailing arrow. The marker is gone from the body
    /// now; this strip stays as the second line of defence. Seen live on 0.3.1 (EN→ZH/KO);
    /// once leaked, the committed line becomes the next example and the marker
    /// self-reinforces for the rest of the session. Strip those echoes here — the
    /// single sanitizer both the streaming and the final path go through, so the
    /// stored example pair is clean too.
    static func stripPromptMarkerEcho(_ raw: String) -> String {
        var text = raw
        // P2 (live 0.3.5): a one-letter source ("a") came back as "目标中文：" — the
        // model labelled the reply with the target language. Label echoes end in
        // a colon, so the list is safe to extend with the target-language names.
        let markers = ["Now", "now", "现在", "現在", "이제", "지금", "현재", "今", "いま", "Text", "텍스트", "文本",
                       "Translation", "translation", "Translated", "翻译", "翻譯", "翻訳", "번역", "目标中文", "目标语言", "目標語言",
                       "Chinese", "Korean", "Japanese", "English", "中文", "한국어", "日本語", "英语", "英語", "영어", "中国語", "韓国語"]
        var changed = true
        while changed {
            changed = false
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for m in markers {
                for colon in [":", "："] {
                    if t.hasPrefix(m + colon) {
                        text = String(t.dropFirst(m.count + colon.count))
                        changed = true
                        break
                    }
                }
                if changed { break }
            }
            if changed { continue }
            // separator echo: a leading ". " / "; " / "。 " before the actual translation
            if let first = t.first, ".;。；".contains(first), t.count > 1,
               t.dropFirst().first.map({ $0 == " " || $0 == "\u{3000}" }) == true {
                text = String(t.dropFirst(2)); changed = true; continue
            }
            if t.hasSuffix("=>") { text = String(t.dropLast(2)); changed = true; continue }
            // P5 (live 0.3.7): the arrow also surfaces MID-sentence — "우리가 세계와
            // 함께 많은 종교적 그리고 우리가 어떻게 ->". Only a whitespace-delimited
            // arrow is removed, so "a->b" in real text survives.
            let stripped = Self.stripInlineArrows(t)
            if stripped != t { text = stripped; changed = true; continue }
            text = t
        }
        return text
    }

    /// P2 (live 0.3.5, 2026-09-03): with a real pair in the T5 example slot the
    /// 4B sometimes REPLAYS the example translation before — or instead of — the
    /// requested one: "Yeah. => 是的。" then "是的。因为你被放到了29号位，对吧?", a whole
    /// earlier Korean paragraph ahead of "…알지, 아침 3시에 화장실 갈 때 이 약을 복용해.",
    /// and for "only." the previous line's long Chinese translation verbatim.
    /// Strip a leading copy of the example target (normalized: case, spacing and
    /// punctuation ignored; the cut is made in the raw text). A whole-output echo
    /// is dropped only when it is implausibly long for the source — "Yes." →
    /// "是的。" after "Yeah. => 是的。" is a legitimate repeat and is kept.
    static func stripExampleEcho(_ text: String, exampleTarget: String?, source: String) -> String {
        guard let ex = exampleTarget else { return text }
        let exKeys = echoKeys(ex)
        guard exKeys.count >= 2 else { return text }
        var pos = 0
        var idx = text.startIndex
        while pos < exKeys.count, idx < text.endIndex {
            if let k = echoKey(text[idx]) {
                if k != exKeys[pos] { return text }     // diverged: not an echo
                pos += 1
            }
            idx = text.index(after: idx)
        }
        guard pos == exKeys.count else { return text }  // output shorter than the example
        // Drop the separator the model put between the replay and the real reply
        // (leading side only — the reply's own terminal punctuation stays).
        let seam = CharacterSet(charactersIn: " \t\n.。,，;；:：!?！？…-—")
        let rest = String(text[idx...].drop(while: { $0.unicodeScalars.allSatisfy(seam.contains) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { return rest }
        // Whole output == example target. Keep it unless it cannot be a translation
        // of this source (far longer than the source could yield).
        let srcKeys = echoKeys(source).count
        return exKeys.count > 3 * srcKeys + 6 ? "" : text
    }

    /// True while `partial` is still a (normalized) prefix of the example target
    /// — the stream may be replaying the example, so hold it off screen.
    static func mayBeExampleEcho(_ partial: String, exampleTarget: String?) -> Bool {
        guard let ex = exampleTarget else { return false }
        let p = echoKeys(partial), e = echoKeys(ex)
        guard !p.isEmpty, e.count >= 2, p.count < e.count else { return false }
        return Array(e.prefix(p.count)) == p
    }

    /// Remove standalone "=>" / "->" / "→" tokens (whitespace-delimited) and
    /// collapse the whitespace they leave behind.
    static func stripInlineArrows(_ text: String) -> String {
        let arrows: Set<String> = ["=>", "->", "→", "=>.", "->."]
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.contains(where: { arrows.contains(String($0)) }) else { return text }
        return parts.filter { !arrows.contains(String($0)) }
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func echoKey(_ c: Character) -> Character? {
        guard c.isLetter || c.isNumber else { return nil }
        return Character(c.lowercased())
    }
    private static func echoKeys(_ s: String) -> [Character] { s.compactMap(echoKey) }

    static func shouldRetry(_ output: String, source: String, target: String) -> Bool {
        let cleaned = clean(output)
        guard !cleaned.isEmpty else { return !output.isEmpty }
        if norm(cleaned) == norm(source) { return true }
        return containsForbiddenScript(cleaned, target: target)
    }

    static func sourceLanguageName(for text: String) -> String {
        var hangul = 0, kana = 0, han = 0
        for scalar in text.unicodeScalars {
            if isHangul(scalar.value) { hangul += 1 }
            else if isKana(scalar.value) { kana += 1 }
            else if isHan(scalar.value) { han += 1 }
        }
        if hangul > 0 { return "Korean" }
        if kana > 0 { return "Japanese" }
        if han > 0 { return "Chinese" }
        return "English"
    }

    private static func containsForbiddenScript(_ text: String, target: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch target {
            case "Korean":
                if isKana(value) { return true }
            case "Japanese":
                if isHangul(value) { return true }
            case "Chinese":
                if isHangul(value) || isKana(value) { return true }
            case "English":
                if isHangul(value) || isKana(value) || isHan(value) { return true }
            default:
                break
            }
        }
        return false
    }

    private static func collapseConsecutiveSentences(_ text: String) -> String {
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        var units: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                appendNonempty(current, to: &units)
                current = ""
            }
        }
        appendNonempty(current, to: &units)

        var result: [String] = []
        var i = 0
        while i < units.count {
            var end = i + 1
            while end < units.count, norm(units[end]) == norm(units[i]) { end += 1 }
            // Preserve a deliberate two-sentence repetition ("Yes. Yes."); only
            // collapse the 3+ exact loops observed in 2B runaway generation.
            if end - i >= 3 { result.append(units[i]) }
            else { result.append(contentsOf: units[i..<end]) }
            i = end
        }
        return result.joined(separator: " ")
    }

    private static func appendNonempty(_ value: String, to units: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        units.append(trimmed)
    }

    private static func norm(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.。!?！？\"'"))
    }

    private static func isHangul(_ v: UInt32) -> Bool {
        (0x1100...0x11ff).contains(v) || (0x3130...0x318f).contains(v) ||
        (0xa960...0xa97f).contains(v) || (0xac00...0xd7af).contains(v) ||
        (0xd7b0...0xd7ff).contains(v)
    }

    private static func isKana(_ v: UInt32) -> Bool {
        (0x3040...0x30ff).contains(v) || (0x31f0...0x31ff).contains(v)
    }

    private static func isHan(_ v: UInt32) -> Bool {
        (0x3400...0x4dbf).contains(v) || (0x4e00...0x9fff).contains(v) ||
        (0xf900...0xfaff).contains(v)
    }
}
