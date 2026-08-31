// SummaryTemplate.swift — the "one spine, three templates" summary taxonomy and
// the single source of truth for section-tag rules. Foundation-only (no SwiftUI/
// AppKit) so it joins SovereignCore + XCTest like MeetingMode. Design:
// docs/SUMMARY_TEMPLATES.md.
//
// Spine (shared by every template): a [요약] 2–4 sentence head + two more tagged
// sections + "- " bullets. Templates differ ONLY in which two sections follow —
// the parser (SummaryDeck), recap card (RecapData), and open-loop extraction
// (OpenLoopsAggregator) all read section meaning from THIS registry instead of
// hardcoding tag literals.
//
// PR-A wires the registry + consumers with byte-identical output for today's
// meeting summaries; the engine-side prompts thread through in PR-B.

import Foundation

/// The user-facing summary category. rawValue is the STABLE persistence key —
/// never rename a case's rawValue.
enum SummaryTemplate: String, CaseIterable, Identifiable, Codable {
    case meeting, lecture, interview
    var id: String { rawValue }

    /// Segmented-picker label (요약 시트). Japanese resolves through
    /// L10nJa.table on the English key, like MeetingMode's labels.
    func label(_ lang: UILanguage) -> String {
        switch self {
        case .meeting:   return lang("회의", "Meeting")
        case .lecture:   return lang("강의", "Lecture")
        case .interview: return lang("인터뷰", "Interview")
        }
    }

    /// One-line caption under the picker: WHICH sections this template produces.
    /// Hand-written per language rather than joined from `sections`, because the
    /// registry's canon titles are parsed model output (content, always Korean)
    /// while this line is UI chrome.
    func summaryDescription(_ lang: UILanguage) -> String {
        switch self {
        case .meeting:   return lang("요약 · 액션 · 결정", "Summary · actions · decisions")
        case .lecture:   return lang("요약 · 핵심 요점 · 용어", "Summary · key points · terms")
        case .interview: return lang("요약 · 문답 · 후속 조치", "Summary · Q&A · follow-ups")
        }
    }
}

/// One summary section's tag rules — the registry entry every consumer reads.
struct SummarySection: Equatable {
    /// Consumer semantics: what a section MEANS, decoupled from its display
    /// title. The recap card buckets by kind; open-loop extraction tracks
    /// decision/action kinds only.
    enum Kind: Equatable { case gist, decision, action, qa, keypoint, term }

    let kind: Kind
    /// The short literal the model emits in brackets ("요약", "후속"). Short
    /// nouns only — a 2B model drifts on long/punctuated literals like
    /// "핵심 요점" or "용어·개념".
    let tag: String
    /// Tolerant parser keys (SummaryDeck.matchHeader prefix-matches these).
    let aliases: [String]
    /// Canonical display title ("액션 아이템", "핵심 요점" …) — what
    /// SummaryDeck.parseSections emits as the section title.
    let canon: String
    /// Max bullets SummaryReplySanitizer keeps under this section's header.
    /// 2B-probed (2026-08-31): the model ignores in-prompt count limits and
    /// pads sections with hallucinated tails ([용어] grew to 65 terms, [문답]
    /// invented pairs past the source) — the cap enforces the format contract
    /// the small model can't hold. First bullets are the grounded ones.
    let bulletCap: Int
}

extension SummarySection {
    /// The shared gist head every template starts with.
    static let gist = SummarySection(
        kind: .gist, tag: "요약",
        aliases: ["요약", "summary", "개요"], canon: "요약", bulletCap: 12)
    static let action = SummarySection(
        kind: .action, tag: "액션",
        aliases: ["액션", "할 일", "할일", "action", "to-do", "todo"], canon: "액션 아이템",
        bulletCap: 12)
    static let decision = SummarySection(
        kind: .decision, tag: "결정",
        aliases: ["결정", "decision"], canon: "결정 사항", bulletCap: 12)
    static let keypoint = SummarySection(
        kind: .keypoint, tag: "요점",
        aliases: ["요점", "핵심 요점", "takeaway", "key point"], canon: "핵심 요점",
        bulletCap: 5)
    static let term = SummarySection(
        kind: .term, tag: "용어",
        aliases: ["용어", "개념", "term"], canon: "용어·개념", bulletCap: 5)
    static let qa = SummarySection(
        kind: .qa, tag: "문답",
        aliases: ["문답", "q&a", "질의응답"], canon: "문답", bulletCap: 10)   // 5쌍 × Q/A 2줄
    /// Interview follow-ups. Kind is .action ON PURPOSE: that one assignment
    /// routes them into the recap card's action slot and the open-loops tracker
    /// with zero extra wiring.
    static let followUp = SummarySection(
        kind: .action, tag: "후속",
        aliases: ["후속", "follow-up", "followup"], canon: "후속 조치", bulletCap: 6)

    /// Union registry for parsers. ORDER MATTERS: the first three entries are
    /// the legacy 요약/액션/결정 set in their historical order, so
    /// SummaryDeck's prefix-matching precedence — and thus every existing
    /// meeting summary's parse — stays byte-for-byte identical. New sections
    /// only append.
    static let registry: [SummarySection] = [gist, action, decision, keypoint, term, qa, followUp]

    /// Kind for a canonical section title parseSections produced. nil for
    /// titles outside the registry (callers treat that as the 기타 bucket,
    /// matching today's else-branches).
    static func kind(forCanon title: String) -> Kind? {
        registry.first { $0.canon == title }?.kind
    }
}

extension SummaryTemplate {
    /// Ordered sections (gist first) — what the template's prompt asks for and
    /// what its output parses into.
    var sections: [SummarySection] {
        switch self {
        case .meeting:   return [.gist, .action, .decision]
        case .lecture:   return [.gist, .keypoint, .term]
        case .interview: return [.gist, .qa, .followUp]
        }
    }

    // ── engine prompts (PR-B) ─────────────────────────────────────────────────
    // Wording is CLI-probed on both shipped models (2026-08-31, DNA3.0-2B/4B —
    // docs/SUMMARY_TEMPLATES.md §7). Probe-driven choices:
    //  · [문답] asks for the model's NATURAL two-line shape (- Q: / next line
    //    - A:) — demanding one-line "Q → A" pairs made the 2B copy the example's
    //    quotes verbatim and drop the arrow.
    //  · "따옴표 없이" because the 2B copied quoted format examples as literal
    //    quotes into its output.
    //  · Count limits ("최대 5쌍", "3개만") are nudges the 2B ignores — the hard
    //    ceiling is SummaryReplySanitizer's per-section bulletCap.

    /// The final-format prompt for a transcript that fits one request.
    /// `.meeting` is byte-for-byte today's baseline prompt (golden-tested).
    func finalPrompt(transcript t: String, styleSuffix: String) -> String {
        switch self {
        case .meeting:
            return "다음 회의록을 요약하세요. 회의록과 같은 언어로 답하세요. "
                + "형식: [요약] 핵심을 2-4문장. [액션] 각 줄 '- 담당자: 할 일'(없으면 생략). "
                + "[결정] 각 줄 '- 결정사항'(없으면 생략). 다른 말 없이 이 형식만. 회의록: \(t)" + styleSuffix
        case .lecture:
            return "다음 강의/발표 전사를 요약하세요. 전사와 같은 언어로 답하세요. "
                + "형식: [요약] 핵심을 2-4문장. [요점] 각 줄을 - 요점 형태로 3-5개. "
                + "[용어] 전사에 등장한 용어 중 가장 중요한 3개만 각 줄 - 용어: 한 줄 설명"
                + "(없으면 생략). 따옴표 없이, 다른 말 없이 이 형식만. 전사: \(t)" + styleSuffix
        case .interview:
            return "다음 인터뷰/상담 전사를 요약하세요. 전사와 같은 언어로 답하세요. "
                + "형식: [요약] 핵심을 2-4문장. [문답] 주요 문답 최대 5쌍, 질문은 - Q: 로 쓰고 "
                + "바로 아랫줄에 답변을 - A: 로. [후속] 앞으로 하기로 한 일만 각 줄 - 이름: 할 일"
                + "(없으면 생략). 따옴표 없이, 다른 말 없이 이 형식만. 전사: \(t)" + styleSuffix
        }
    }

    /// Intermediate map-reduce "condense" prompt — what each over-budget chunk
    /// must PRESERVE is template-shaped (the meeting wording would fold a 2-hr
    /// lecture down to decisions/to-dos and lose 요점·용어). `.meeting` is
    /// byte-for-byte today's condense prompt.
    func condensePrompt(chunk t: String) -> String {
        switch self {
        case .meeting:
            return "다음 회의 내용을 화자(이름)·핵심·결정·할 일을 보존하며 간결히 요약하세요. "
                + "회의록과 같은 언어로, 군더더기 없이. 내용: \(t)"
        case .lecture:
            return "다음 강의 내용을 주제·핵심 요점·용어(정의)를 보존하며 간결히 요약하세요. "
                + "전사와 같은 언어로, 군더더기 없이. 내용: \(t)"
        case .interview:
            return "다음 인터뷰 내용을 질문·답변 짝(누가 물었고 뭐라 답했는지)·후속 조치를 "
                + "보존하며 간결히 요약하세요. 전사와 같은 언어로, 군더더기 없이. 내용: \(t)"
        }
    }
}

extension MeetingMode {
    /// Default template derived from the meeting shape. The summary sheet can
    /// override per session (PR-C); the mode is the durable signal.
    var defaultSummaryTemplate: SummaryTemplate {
        switch self {
        case .general, .oneOnOne, .standup: return .meeting
        case .lecture:   return .lecture
        case .interview: return .interview
        }
    }
}
