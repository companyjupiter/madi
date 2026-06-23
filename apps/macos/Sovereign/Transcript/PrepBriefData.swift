// PrepBriefData.swift — pure value model for the Meeting Prep Brief. Mirrors
// RecapData (Foundation-only, deterministic, .markdown export) but is forward-
// looking instead of retrospective: built BEFORE recording from an upcoming
// calendar event's attendees + the archived workspace transcripts, it carries
// the prior decisions and still-open action items tied to those attendees so the
// host walks in prepared.
//
// Holds NO logic of its own beyond formatting + ordering — MeetingPrepBrief is the
// aggregator that fills these arrays from parsed .md files. Kept separate (its own
// file) so the value model is testable without the matcher and the matcher is
// testable producing this struct.
//
// Snapshot semantics: a PrepBriefData is valid only at the moment it is built. If
// the user edits an old meeting's .md after the brief is shown, the brief does NOT
// refresh — re-request it (rebuild) to reflect the change. Determinism: every array
// is ordered by (meeting name, in-meeting line order), never by wall-clock, so the
// brief renders identically across app launches with no flicker.

import Foundation

/// One attendee surfaced for the upcoming meeting, with how present they've been in
/// the prior workspace history. `pastMeetings` is the count of archived transcripts
/// they appear in (by name match); `role` is an optional parenthetical pulled from
/// the matched speaker label (e.g. "(PM)" in "김부장(PM)") when one exists.
struct PrepAttendee: Identifiable, Hashable {
    let name: String
    let role: String?
    let pastMeetings: Int
    var id: String { name }
}

/// A prior decision or open item attributed to an attendee, tagged with the meeting
/// (transcript file base name) it came from. `meetingOrder` is the line index inside
/// that meeting — kept only as a stable tie-break, never displayed.
struct PrepItem: Identifiable, Hashable {
    let speaker: String
    let text: String
    let meeting: String
    let meetingOrder: Int
    var id: String { "\(meeting)#\(meetingOrder)" }
}

/// The fully-aggregated brief. `decisions` are lines that read like settled calls,
/// `openItems` are lines that read like unresolved actions; `relatedTalks` is the
/// deduped list of meeting names that contributed any context (so the UI can show
/// "drawn from N past meetings").
struct PrepBriefData {
    var meetingTitle: String
    var attendees: [PrepAttendee]
    var decisions: [PrepItem]
    var openItems: [PrepItem]
    var relatedTalks: [String]

    /// True when no attendee, decision, or open item was found — the UI renders a
    /// graceful "no prior context" state instead of empty sections.
    var isEmpty: Bool {
        attendees.isEmpty && decisions.isEmpty && openItems.isEmpty
    }

    /// Empty brief for a title with no resolvable context (new user / new meeting).
    static func empty(title: String) -> PrepBriefData {
        PrepBriefData(meetingTitle: title.isEmpty ? "회의" : title,
                      attendees: [], decisions: [], openItems: [], relatedTalks: [])
    }

    /// One-page Markdown — what the brief's "복사"/"내보내기" emit. H2 sections,
    /// bullet lists, attendee meeting counts, and a generated-at date stamp.
    func markdown(date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy년 M월 d일 (EEE)"
        df.locale = Locale(identifier: "ko_KR")

        var s = "# \(meetingTitle) — 회의 준비 브리핑\n\n_\(df.string(from: date)) 생성_\n"

        if !attendees.isEmpty {
            s += "\n## 회의 참석자\n"
            for a in attendees {
                let role = a.role.map { " \($0)" } ?? ""
                s += "- \(a.name)\(role) — 지난 회의 \(a.pastMeetings)회\n"
            }
        }
        if !decisions.isEmpty {
            s += "\n## 지난 결정\n"
            for d in decisions { s += "- [\(d.meeting)] \(d.speaker): \(d.text)\n" }
        }
        if !openItems.isEmpty {
            s += "\n## 미해결 액션\n"
            for o in openItems { s += "- [ ] [\(o.meeting)] \(o.speaker): \(o.text)\n" }
        }
        if decisions.isEmpty && openItems.isEmpty {
            s += "\n_지난 결정이나 미해결 액션을 찾지 못했습니다._\n"
        }
        if !relatedTalks.isEmpty {
            s += "\n## 관련 논의\n"
            for m in relatedTalks { s += "- \(m)\n" }
        }
        return s
    }
}
