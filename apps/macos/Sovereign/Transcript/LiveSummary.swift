// LiveSummary.swift — live key-point notes DURING a recording (the right-side 요약 tab).
// Pure prompt/parse logic (Foundation only) → SovereignCore + XCTest; scheduling lives in
// SessionController.
//
// Redesign (2026-10-08, docs/LIVE_SUMMARY.md). The previous design re-summarized its own last
// summary every 30 s (a rolling "carry"). Replayed on a real 40-minute Korean meeting it
// flipped to English (the carry then locked that in), stopped changing after 20 minutes, and
// kept 2-3 of 15 key facts; tripling its budget kept only the last 10 minutes and doubled the
// time a request holds the engine. Rewriting a summary from a summary loses detail every
// round — the same loss the post-session fold has.
//
// So a request now reads only NEW lines, once, and returns at most one note that is APPENDED.
// Earlier notes are never rewritten, so nothing drifts, and every note keeps the ids of the
// exact lines it came from. Same replay: 14-15 of 15 facts, in-flight p50 ~1.0 s / max 1.4 s
// (the carry's was 2.4 s / 4.3 s — a request can only delay a caption while it runs).

import Foundation

enum LiveSummary {

    // ── scheduling knobs (SessionController's tick and the tests agree on these) ──
    static let tickSeconds: TimeInterval = 30
    /// A request needs this many new lines — about a minute of speech, enough for one real point.
    static let minNewLines = 10
    /// New speech per request, in characters, taken OLDEST first; the rest waits for the next
    /// tick. Bounds prefill — and with a one-line answer, the whole in-flight time.
    static let windowCap = 1000
    /// More unsent speech than this means the lane was starved for minutes; jump to the newest
    /// window rather than trail the meeting.
    static let maxBacklogChars = 3 * windowCap
    /// Display grouping only — no model call summarizes a section (that step crammed several
    /// points into one comma list and was the slowest request).
    static let sectionSeconds: Double = 300
    static let minNoteChars = 6
    /// A reply this long copied the speech instead of noting it.
    static let maxNoteChars = 140

    enum Language: String, Equatable {
        case ko, en, ja, zh
        var promptName: String {
            switch self {
            case .ko: return "한국어"
            case .en: return "영어"
            case .ja: return "일본어"
            case .zh: return "중국어"
            }
        }
    }

    struct Note: Equatable {
        let text: String
        let start: Double          // first source line's start, seconds into the session
        let end: Double
        let lineIDs: [UUID]        // provenance — the exact lines this note was read from
    }

    struct Section: Equatable {
        let index: Int
        let notes: [Note]
        var startSeconds: Double { Double(index) * LiveSummary.sectionSeconds }
    }

    struct WindowLine: Equatable {
        let id: UUID
        let start: Double
        let end: Double
        let speaker: String        // as displayed; anonymous ones too (see `window`)
        let text: String
    }

    // ── template nudge (auto-derived from the session's template) ──
    static func hint(_ template: SummaryTemplate) -> String {
        switch template {
        case .meeting:   return ""
        case .lecture:   return " 강의이므로 핵심 개념과 요점 위주로."
        case .interview: return " 인터뷰이므로 질문과 답변의 요지 위주로."
        }
    }

    // ── language: decided by the transcript's dominant script, enforced on the output ──
    // "반드시 발언과 같은 언어로" was not enough: a Korean meeting with English fragments
    // ("Q.", "So, you can see the search tool.") came back in English, with stray hanzi.

    private static func scriptCounts(_ s: String) -> (hangul: Int, kana: Int, han: Int, latin: Int) {
        var h = 0, k = 0, z = 0, l = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: h += 1
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: k += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: z += 1
            case 0x41...0x5A, 0x61...0x7A: l += 1
            default: break
            }
        }
        return (h, k, z, l)
    }

    static func dominantLanguage(of text: String) -> Language {
        let c = scriptCounts(text)
        let total = Double(c.hangul + c.kana + c.han + c.latin)
        guard total > 0 else { return .en }
        if c.hangul > 0, Double(c.hangul) >= 0.3 * total { return .ko }
        if c.kana > 0, Double(c.kana + c.han) >= 0.3 * total { return .ja }
        if c.han > 0, Double(c.han) >= 0.3 * total { return .zh }
        return .en
    }

    /// Korean notes may carry Latin product names and acronyms (GPT, AWS), but no kana/hanzi;
    /// an English note carries no CJK at all.
    static func scriptMatches(_ line: String, _ lang: Language) -> Bool {
        let c = scriptCounts(line)
        let total = c.hangul + c.kana + c.han + c.latin
        guard total > 0 else { return false }
        switch lang {
        case .ko: return Double(c.hangul) >= 0.4 * Double(total) && c.han == 0 && c.kana == 0
        case .en: return c.hangul == 0 && c.kana == 0 && c.han == 0
        case .ja: return c.kana > 0 && c.hangul == 0
        case .zh: return c.han > 0 && c.hangul == 0 && c.kana == 0
        }
    }

    // ── request ──

    /// The window for one request: lines from the front, oldest first, until `cap` characters.
    /// Every speaker is labeled as displayed — anonymous "화자3" included. Labeling only the
    /// named ones made the model attribute everyone else's words to them; anonymous labels
    /// are removed from the NOTE instead (`parseNote`).
    /// Returns the rendered text and how many lines it used (≥ 1 whenever lines remain).
    static func takeWindow(_ lines: [WindowLine], cap: Int = windowCap) -> (text: String, used: Int) {
        var parts: [String] = []
        var size = 0
        var used = 0
        for l in lines {
            let piece = "\(l.speaker): \(l.text)".replacingOccurrences(of: "\n", with: " ")
            let add = piece.count + (parts.isEmpty ? 0 : 3)
            if !parts.isEmpty, size + add > cap { break }
            parts.append(parts.isEmpty && piece.count > cap ? String(piece.prefix(cap)) : piece)
            size += add
            used += 1
        }
        return (parts.joined(separator: " / "), used)
    }

    /// Wording replayed on the shipped 4B (KO 40-min meeting, KO 13-min talk, EN clip): one
    /// note, concrete, no invented decisions, '없음' for chatter, language named outright.
    static func notePrompt(window: String, language: Language, template: SummaryTemplate) -> String {
        let w = window.replacingOccurrences(of: "\n", with: " ")
        return "다음은 진행 중인 회의의 새 발언입니다. 이 발언에서 가장 중요한 구체적인 내용 하나만 50자 안팎의 한 문장으로 쓰세요. "
            + "이름·수치·금액·제품명처럼 구체적인 것을 살리세요. "
            + "'결정'이나 '합의'는 발언에서 분명히 정했다고 말한 경우에만 쓰고, 아니면 '논의'나 '제안'으로 쓰세요. "
            + "잘못 들린 듯 뜻이 통하지 않는 말은 쓰지 말고, 인사·잡담뿐이면 '없음'이라고만 답하세요.\(hint(template)) "
            + "반드시 \(language.promptName)로만 답하세요. - 로 시작, 다른 말 없이. 새 발언: \(w)"
    }

    // ── reply ──

    private static let anonymousLead = try! NSRegularExpression(
        pattern: "^(?:Speaker|화자)\\s*\\d+\\s*[:：]\\s*", options: [.caseInsensitive])
    private static let anonymousMention = try! NSRegularExpression(
        pattern: "(?:Speaker|화자)\\s*\\d+\\s*(?:님)?(?:은|는|이|가|께서|의)?\\s*", options: [.caseInsensitive])
    private static let promptEcho = try! NSRegularExpression(
        pattern: "^(?:이\\s*)?발언에서\\s*(?:가장\\s*)?(?:중요한\\s*)?(?:구체적인\\s*)?내용은\\s*")

    private static func strip(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    /// Display parse: sanitized reply → bullet texts (marks stripped; a dropped dash still shows).
    static func bullets(_ reply: String) -> [String] {
        reply.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            for mark in ["- ", "* ", "• ", "· ", "-", "•"] where line.hasPrefix(mark) {
                line = String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return line.isEmpty ? nil : line
        }
    }

    /// One note from a sanitized reply, or nil for '없음', a fragment or a copied run-on.
    static func parseNote(_ reply: String) -> String? {
        guard var s = bullets(reply).first else { return nil }
        s = strip(anonymousLead, s)
        s = strip(promptEcho, s)
        s = strip(anonymousMention, s).trimmingCharacters(in: .whitespaces)
        if let f = s.first, f.isASCII, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        let bare = s.filter { !$0.isWhitespace && !".。!-".contains($0) }.lowercased()
        if bare == "없음" || bare == "none" || bare.isEmpty { return nil }
        guard s.count >= minNoteChars, s.count <= maxNoteChars else { return nil }
        return s
    }

    private static func trigrams(_ s: String) -> Set<String> {
        let c = Array(s.lowercased().filter { !$0.isWhitespace })
        guard c.count >= 3 else { return [] }
        return Set((0...(c.count - 3)).map { String(c[$0..<$0 + 3]) })
    }

    /// Near-identical, or one mostly contained in the other (a split or echo of an earlier note).
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let A = trigrams(a), B = trigrams(b)
        guard !A.isEmpty, !B.isEmpty else { return false }
        let inter = Double(A.intersection(B).count)
        return inter / Double(A.union(B).count) >= 0.5 || inter / Double(min(A.count, B.count)) >= 0.8
    }

    /// The note joins the pane only in the session's language and only if it says something new.
    static func accepts(_ note: String, language: Language, existing: [Note]) -> Bool {
        scriptMatches(note, language) && !existing.contains { isNearDuplicate($0.text, note) }
    }

    static func sections(_ notes: [Note]) -> [Section] {
        Dictionary(grouping: notes) { Int($0.start / sectionSeconds) }
            .map { Section(index: $0.key, notes: $0.value) }
            .sorted { $0.index < $1.index }
    }
}
