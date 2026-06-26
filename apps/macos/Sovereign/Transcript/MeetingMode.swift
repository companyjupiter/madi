// MeetingMode.swift — one-click meeting-shape presets. Foundation-only logic core
// (no SwiftUI/AppKit) so it is SovereignCore-eligible and XCTest-covered.
//
// A meeting mode is pure ORCHESTRATION over knobs Madi already has:
//   • diarization  — a default fixed-speaker-count hint (rawValue matches
//                    SessionController.SpeakerCount.rawValue: 0=자동,1,2,3,4=4명 이상)
//                    so the controller can apply it WITHOUT importing this enum's
//                    coupling to SpeakerCount (decoupled by raw Int).
//   • summary style — a short prompt suffix the SummaryEngine appends to nudge
//                    (not force) section re-weighting per meeting shape.
//   • action emphasis — a hint string for live/extracted action weighting.
//
// No new models, no architecture change. Unset/old sessions degrade cleanly to
// `.general` (raw "general"), whose config is the current baseline (자동 diarization,
// empty prompt suffix) — i.e. byte-for-byte today's behavior.

import Foundation

/// The shape of a meeting. rawValue is the STABLE persistence key (stored in
/// UserDefaults via SessionController) — never rename a case's rawValue.
enum MeetingMode: String, CaseIterable, Identifiable, Codable {
    case general   = "general"
    case oneOnOne  = "oneOnOne"
    case standup   = "standup"
    case interview = "interview"
    case lecture   = "lecture"

    var id: String { rawValue }

    /// Korean label for the picker.
    var label: String {
        switch self {
        case .general:   return "일반"
        case .oneOnOne:  return "1:1"
        case .standup:   return "스탠드업"
        case .interview: return "인터뷰"
        case .lecture:   return "강의"
        }
    }

    /// SF Symbol badge for the picker / confirmation.
    var sfSymbol: String {
        switch self {
        case .general:   return "person.3"
        case .oneOnOne:  return "person.2"
        case .standup:   return "figure.stand"
        case .interview: return "questionmark.bubble"
        case .lecture:   return "studentdesk"
        }
    }

    /// One-line description of what the preset does.
    var summaryDescription: String {
        switch self {
        case .general:   return "기본 설정 · 발화자 자동 감지"
        case .oneOnOne:  return "발화자 2명 · 결정과 후속 조치 강조"
        case .standup:   return "발화자 자동 · 액션과 블로커 강조"
        case .interview: return "발화자 2명 · 질문·답변 흐름 보존"
        case .lecture:   return "발화자 1명 · 핵심 요점 위주 정리"
        }
    }

    /// The full preset config for this mode.
    var config: MeetingModeConfig { MeetingModeConfig(mode: self) }
}

/// Immutable preset bundle derived from a MeetingMode. Plain value type — safe to
/// serialize/round-trip; all fields are deterministic functions of `mode`.
struct MeetingModeConfig: Equatable {
    let mode: MeetingMode

    /// SpeakerCount rawValue to apply on selection (0=자동,1,2,3,4=4명 이상). The
    /// controller maps this Int to its own SpeakerCount enum — this core stays
    /// free of any SessionController coupling.
    var defaultSpeakerCountRaw: Int {
        switch mode {
        case .general:   return 0   // 자동
        case .oneOnOne:  return 2
        case .standup:   return 0   // 자동 (team size varies)
        case .interview: return 2
        case .lecture:   return 1
        }
    }

    /// Prompt suffix the SummaryEngine appends to the final summarize prompt to
    /// re-weight sections for this shape. EMPTY for `.general` (baseline — appending
    /// "" must be a no-op so general stays byte-for-byte today's prompt). Korean,
    /// imperative, a nudge not a command.
    var summaryPromptSuffix: String {
        switch mode {
        case .general:   return ""
        case .oneOnOne:  return " 1:1 회의이므로 합의된 결정과 후속 조치를 특히 강조하세요."
        case .standup:   return " 스탠드업이므로 각자의 액션과 블로커를 특히 강조하세요."
        case .interview: return " 인터뷰이므로 핵심 질문과 답변을 짝지어 정리하세요."
        case .lecture:   return " 강의이므로 핵심 주제와 요점을 항목별로 정리하세요."
        }
    }

    /// Hint for action/rail emphasis. Empty for modes with no special weighting.
    var actionEmphasis: String {
        switch mode {
        case .general, .lecture: return ""
        case .oneOnOne:          return "decisions"
        case .standup:           return "blockers"
        case .interview:         return "questions"
        }
    }
}
