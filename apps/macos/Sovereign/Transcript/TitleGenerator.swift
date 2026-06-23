// TitleGenerator.swift — SMART AUTO-TITLE core (Foundation-only, deterministic).
//
// The on-device DNA3 engine (SummaryEngine.generateTitle) returns a raw, often
// noisy one-line meeting title — quoted, markdown-wrapped, trailing-punctuated,
// sometimes multi-line or padded with a "제목:" lead-in. This core SANITIZES that
// raw string into a safe, short, filesystem-legal meeting name used as the
// auto-saved .md base name, and provides the timestamped FALLBACK that mirrors
// SessionController.autoSaveMarkdown's "회의 yyyy-MM-dd HHmm" convention.
//
// Pure static API: no engine, no I/O — so it joins the SovereignCore test target
// and is fully unit-testable. The LLM call + onResult/finalize wiring live in
// SummaryEngine / SessionController (the lead writer applies those).

import Foundation

enum TitleGenerator {
    /// Hard cap on the sanitized title length (characters, grapheme-safe).
    /// ~24 keeps the .md filename short and the UI label tidy.
    static let maxLength = 24

    /// The Korean prompt for the title model — same chat-turn shape as
    /// SummaryEngine.summarize()'s prompts: one instruction + the transcript.
    /// Kept here so the prompt text is testable/inspectable Foundation-side.
    static func promptText(_ transcript: String) -> String {
        "다음 회의록을 대표하는 짧은 제목을 한 줄로만 답하세요. "
            + "24자 이내, 명사구로. 따옴표·마침표·설명 없이 제목만. "
            + "회의록: \(transcript)"
    }

    /// Timestamped fallback name, IDENTICAL to autoSaveMarkdown's live-recording
    /// base ("회의 yyyy-MM-dd HHmm"). Used when the model is absent or sanitize
    /// rejects the raw title as empty/garbage.
    static func fallbackTitle(date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        return "회의 \(df.string(from: date))"
    }

    /// Turn a raw LLM title into a safe short meeting name, or nil if it reduces
    /// to nothing usable. Steps, in order:
    ///   1. take the first non-empty line (models sometimes emit extra lines)
    ///   2. strip a leading "제목:" / "Title:" label the model may prepend
    ///   3. strip markdown emphasis (*, _, `, #) and surrounding quotes/brackets
    ///   4. collapse all internal whitespace runs to a single space + trim
    ///   5. remove filesystem-illegal / path-breaking characters (/ : \ etc.)
    ///   6. strip leading/trailing punctuation & separators
    ///   7. cap to maxLength graphemes (trim again so we never end on a space)
    ///   8. nil if the result is empty or has no letters/digits (pure garbage)
    static func sanitize(_ raw: String) -> String? {
        // 1. first non-empty line
        guard var s = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        // 2. drop a leading "제목:" / "title:" label (case-insensitive)
        s = stripLeadingLabel(s)

        // 3. strip markdown emphasis chars anywhere
        s = String(s.unicodeScalars.filter { !markdownChars.contains(Character($0)) })

        // 4. collapse whitespace runs → single space, then trim
        s = s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // 5. remove filesystem-illegal & path-breaking characters
        s = String(s.unicodeScalars.filter { !illegalChars.contains(Character($0)) })

        // 6. trim quotes / brackets / punctuation / separators off both ends
        s = s.trimmingCharacters(in: trimEnds)

        // re-collapse: removals in 5/6 can leave double spaces ("a / b" → "a  b")
        s = s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // 7. cap length (grapheme-safe), trim a trailing space the cut may leave
        if s.count > maxLength {
            s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }

        // 8. reject empties / pure punctuation (no letters or digits at all)
        guard !s.isEmpty,
              s.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return s
    }

    // ── internals ────────────────────────────────────────────────────────────

    /// Markdown emphasis / heading characters removed wholesale.
    private static let markdownChars: Set<Character> = ["*", "_", "`", "#", "~"]

    /// Filesystem-illegal (/, :, \, etc.) + control/path-breaking characters.
    /// `/` and `:` are the macOS/HFS path separators; the rest are illegal on
    /// other filesystems or break filenames — stripped so the title is always a
    /// safe single path component.
    private static let illegalChars: Set<Character> =
        ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\u{0000}"]

    /// Characters trimmed off both ends after sanitizing (quotes, brackets,
    /// trailing/leading punctuation & whitespace).
    private static let trimEnds: CharacterSet = {
        var cs = CharacterSet.whitespacesAndNewlines
        cs.insert(charactersIn: "\"'“”‘’`«»()[]{}<>.,!?;:…-–—~*_#/\\ \u{3000}")
        return cs
    }()

    /// Strip a leading "제목:" / "Title:" style label (and the separator after it).
    private static func stripLeadingLabel(_ s: String) -> String {
        let labels = ["제목:", "제목 :", "title:", "title :"]
        let lower = s.lowercased()
        for label in labels where lower.hasPrefix(label.lowercased()) {
            return String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
