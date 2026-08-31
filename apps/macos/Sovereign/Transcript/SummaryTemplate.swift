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
}

extension SummarySection {
    /// The shared gist head every template starts with.
    static let gist = SummarySection(
        kind: .gist, tag: "요약",
        aliases: ["요약", "summary", "개요"], canon: "요약")
    static let action = SummarySection(
        kind: .action, tag: "액션",
        aliases: ["액션", "할 일", "할일", "action", "to-do", "todo"], canon: "액션 아이템")
    static let decision = SummarySection(
        kind: .decision, tag: "결정",
        aliases: ["결정", "decision"], canon: "결정 사항")
    static let keypoint = SummarySection(
        kind: .keypoint, tag: "요점",
        aliases: ["요점", "핵심 요점", "takeaway", "key point"], canon: "핵심 요점")
    static let term = SummarySection(
        kind: .term, tag: "용어",
        aliases: ["용어", "개념", "term"], canon: "용어·개념")
    static let qa = SummarySection(
        kind: .qa, tag: "문답",
        aliases: ["문답", "q&a", "질의응답"], canon: "문답")
    /// Interview follow-ups. Kind is .action ON PURPOSE: that one assignment
    /// routes them into the recap card's action slot and the open-loops tracker
    /// with zero extra wiring.
    static let followUp = SummarySection(
        kind: .action, tag: "후속",
        aliases: ["후속", "follow-up", "followup"], canon: "후속 조치")

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
