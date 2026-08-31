// LiveSummary.swift — rolling on-device core summary DURING a live recording
// (the right-side 요약 tab; docs/BACKLOG.md 2026-08-11 우측 패널 방향). Pure
// prompt/parse logic (Foundation only) → SovereignCore + XCTest; scheduling
// lives in SessionController (forked from the live-rail pattern, per the
// AI-first per-feature-fork philosophy).
//
// Design (docs/LIVE_SUMMARY.md):
//  · ROLLING CARRY — each update feeds the PREVIOUS summary (carry) plus only
//    the NEW lines since the last update. Old transcript text leaves the live
//    loop once folded into the carry; the full transcript stays in
//    TranscriptStore for export/post-session summary (사용자 지시: 오래된 원문은
//    export만 온전하면 된다).
//  · NO-DEGRADATION ENVELOPE — same as the live rail, but stricter: requests
//    ride the LOWEST broker lane (.postSession 10, below the rail's 30, far
//    below captions 80/100), are only enqueued while the caption lane is idle
//    (P11 gate in the tick), one in flight, input hard-capped below, output is
//    a short bullet list. CLI-probed 2026-08-31 on the 4B (the only model the
//    ≥16 GB gate admits): per-request totals 1.2–3.5 s (n=6, KO/EN, carry
//    round-trips included) = the worst-case caption blocking bound; 4/4 format
//    pass, carry accumulation verified. (The 2B ran away — 79 bullets, 8.9 s —
//    which is exactly why the gate exists; 2B machines get the post-session
//    summary instead.)

import Foundation

enum LiveSummary {

    /// Input caps — these bound the request's prefill, and with the short
    /// bullet output they bound the whole in-flight time (the only way a
    /// live-summary request can delay a caption turn).
    static let carryCap = 400        // previous summary fed back in
    static let windowCap = 700       // new spoken lines (suffix — newest wins)

    /// Scheduling knobs (used by SessionController's tick; here so the pure
    /// tests and the scheduler agree). Slower than the rail's 18 s / 3 lines —
    /// a core summary drifts slower than actions do.
    static let tickSeconds: TimeInterval = 30
    static let minNewLines = 6

    /// Template nudge, auto-derived from the session's template (사용자 지시:
    /// 템플릿은 자동판단). A nudge only — the live output stays a flat bullet
    /// list in every template (sections belong to the post-session summary).
    static func hint(_ template: SummaryTemplate) -> String {
        switch template {
        case .meeting:   return ""
        case .lecture:   return " 강의이므로 핵심 개념과 요점 위주로."
        case .interview: return " 인터뷰이므로 질문과 답변의 요지 위주로."
        }
    }

    /// One update request. `carry` nil/empty ⇒ the first summary of the session.
    /// Wording CLI-probed (2026-08-31, 4B 4/4 pass — docs/LIVE_SUMMARY.md).
    static func prompt(carry: String?, window: String, template: SummaryTemplate) -> String {
        let w = String(window.replacingOccurrences(of: "\n", with: " ").suffix(windowCap))
        let h = hint(template)
        let c = carry?.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces) ?? ""
        // "반드시 발언과 같은 언어로만" — A/B probed: the softer "전사와 같은
        // 언어로" leaked Korean/kana into an English meeting's summary on the
        // 4B (63 hangul chars); this wording produced 0.
        if c.isEmpty {
            return "다음은 진행 중인 회의의 최근 발언입니다. 지금까지의 핵심을 3-5개 불릿으로 요약하세요. "
                + "반드시 발언과 같은 언어로만 답하세요(발언이 영어면 영어로). "
                + "각 줄을 - 로 시작, 다른 말 없이 불릿만.\(h) 발언: \(w)"
        }
        return "다음은 진행 중인 회의의 기존 요약과 새 발언입니다. 새 발언을 반영해 핵심 요약을 "
            + "3-6개 불릿으로 갱신하세요. 여전히 중요한 항목은 유지하고 새 내용을 반영하세요. "
            + "반드시 발언과 같은 언어로만 답하세요(발언이 영어면 영어로). "
            + "각 줄을 - 로 시작, 다른 말 없이 불릿만.\(h) "
            + "기존 요약: \(String(c.prefix(carryCap))) 새 발언: \(w)"
    }

    /// Display parse: sanitized reply → bullet texts. Tolerant of the bullet
    /// marks SummaryDeck tolerates; non-bullet lines are kept as bullets too
    /// (a dropped dash must not hide a line from the panel).
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
}
