// MeetingPrepBrief.swift — pure aggregator for the Meeting Prep Brief. Given the
// upcoming calendar event's title + attendee names and the workspace's archived
// transcript .md files, it surfaces the prior decisions and still-open action items
// attributed to those attendees, so the host walks into the meeting already knowing
// what was settled and what's still hanging.
//
// Design echoes PeopleAnalytics (parse every .md, fold per matched person) and
// WorkspaceRetrieval (lexical keyword scoring, char-budgeted, deterministic ties),
// reusing the SAME building blocks: TranscriptArchive.parse and the both-ways
// substring attendee↔speaker match that CalendarBridge.matchToSpeakers uses — so a
// "김부장" attendee lines up with a "김부장(PM)" speaker exactly as it does post-
// session, and the role "(PM)" is recovered from the parenthetical.
//
// Decision vs open-item classification is lexical and Korean-aware (결정/확정/합의
// → decision; 액션/TODO/미정/검토 등 → open item). It is intentionally simple and
// on-device — no engine, no network. The optional "search workspace for more
// context" LLM pass lives in the view (SummaryEngine.askPreselected); this core is
// headless retrieval only, so it unit-tests without the model loaded.
//
// Foundation-only + deterministic: every result array is ordered by (meeting name,
// in-meeting line order), capped per person, so the brief is identical across app
// launches (no flicker). Snapshot semantics — see PrepBriefData.

import Foundation

enum MeetingPrepBrief {

    /// Korean + English cue words. A line whose speaker is an attendee and whose text
    /// contains a DECISION cue is surfaced as a prior decision; an OPEN cue surfaces it
    /// as an unresolved action. A line can match both (e.g. "결정했지만 검토 필요");
    /// decision wins so a settled-but-flagged item isn't double-counted as still open.
    private static let decisionCues: [String] = [
        "결정", "확정", "합의", "승인", "채택", "최종", "정했", "하기로",
        "decided", "decision", "agreed", "approved", "finalize", "conclusion"
    ]
    private static let openCues: [String] = [
        "액션", "todo", "to-do", "할 일", "미정", "보류", "검토", "확인 필요", "다음", "이슈",
        "팔로업", "follow-up", "followup", "pending", "open", "action item", "action", "tbd"
    ]

    /// Per-person cap so one chatty meeting can't flood the brief (risk #3 — keep the
    /// budget tight; top N decisions + N open items per attendee).
    private static let perPersonCap = 10

    /// Build a brief for `title` + `attendees` from the workspace transcript URLs.
    /// Unreadable / unparseable files are skipped gracefully; an empty workspace or
    /// no attendee match yields `PrepBriefData.empty(title:)`.
    static func aggregate(title: String, attendees: [String], mdFiles: [URL]) -> PrepBriefData {
        // Sort files so the global ordering is stable regardless of directory-walk
        // order (same guard WorkspaceRetrieval uses).
        let files = mdFiles.sorted { $0.path < $1.path }
        let parsed: [(meeting: String, parsed: TranscriptArchive.Parsed)] = files.compactMap { url in
            guard let p = TranscriptArchive.parse(url) else { return nil }
            return (meeting: url.deletingPathExtension().lastPathComponent, parsed: p)
        }
        return aggregate(title: title, attendees: attendees, parsed: parsed)
    }

    /// In-memory seam (the unit-test entry — build fixtures without temp files) reused
    /// by the URL path above so both routes share one extraction rule. Each tuple is a
    /// (meeting name, parsed transcript).
    static func aggregate(title: String,
                          attendees rawAttendees: [String],
                          parsed: [(meeting: String, parsed: TranscriptArchive.Parsed)]) -> PrepBriefData {
        // De-dup + drop blank attendees, preserving first-seen order for display.
        var seenAtt = Set<String>()
        var attendeeOrder: [String] = []
        for raw in rawAttendees {
            let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty, seenAtt.insert(a).inserted else { continue }
            attendeeOrder.append(a)
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // No attendees, OR an entirely empty workspace (no archived meetings to draw
        // from) → an empty brief. An attendee is only surfaced when there is at least
        // one past meeting to contextualize against.
        guard !attendeeOrder.isEmpty, !parsed.isEmpty else { return .empty(title: cleanTitle) }

        // Per attendee: their meeting count, the best-matched speaker label (for role),
        // and their decision / open lines.
        var pastMeetings: [String: Int] = [:]
        var roleFor: [String: String?] = [:]
        var decisions: [PrepItem] = []
        var openItems: [PrepItem] = []
        var relatedSet = Set<String>()

        for (meeting, p) in parsed {
            // Which attendees appear (by name) in THIS meeting, and under which speaker
            // label — both-ways substring, exactly like CalendarBridge.matchToSpeakers.
            // attendee → the speaker label it matched (for role extraction).
            var attendeeLabelInMeeting: [String: String] = [:]
            for label in p.names.values {
                for att in attendeeOrder where label.contains(att) || att.contains(label) {
                    // First match wins for the role label (deterministic via names sort below).
                    if attendeeLabelInMeeting[att] == nil { attendeeLabelInMeeting[att] = label }
                }
            }
            guard !attendeeLabelInMeeting.isEmpty else { continue }
            relatedSet.insert(meeting)

            for (att, label) in attendeeLabelInMeeting {
                pastMeetings[att, default: 0] += 1
                if roleFor[att] == nil { roleFor[att] = extractRole(from: label) }
            }

            // speaker id → attendee (only ids whose name matched an attendee). One id can
            // map to at most one attendee here; pick deterministically (sorted attendees).
            var attForId: [Int: String] = [:]
            for (id, name) in p.names {
                let hit = attendeeOrder
                    .filter { name.contains($0) || $0.contains(name) }
                    .sorted()
                    .first
                if let hit { attForId[id] = hit }
            }

            for (i, line) in p.lines.enumerated() {
                guard let att = attForId[line.speaker] else { continue }
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 2 else { continue }
                let low = text.lowercased()
                let isDecision = decisionCues.contains { low.contains($0.lowercased()) }
                let isOpen = openCues.contains { low.contains($0.lowercased()) }
                if isDecision {
                    decisions.append(PrepItem(speaker: att, text: text, meeting: meeting, meetingOrder: i))
                } else if isOpen {
                    openItems.append(PrepItem(speaker: att, text: text, meeting: meeting, meetingOrder: i))
                }
            }
        }

        // Stable ordering: (meeting name, in-meeting line order). No timestamps.
        let order: (PrepItem, PrepItem) -> Bool = {
            $0.meeting != $1.meeting ? $0.meeting < $1.meeting : $0.meetingOrder < $1.meetingOrder
        }
        let cappedDecisions = capPerPerson(decisions.sorted(by: order))
        let cappedOpen = capPerPerson(openItems.sorted(by: order))

        // Attendees: keep every requested attendee (even 0-meeting ones surface
        // "참석자, 이력 없음"), ordered by pastMeetings desc then first-seen order.
        let attendees: [PrepAttendee] = attendeeOrder
            .enumerated()
            .map { idx, att in
                PrepAttendee(name: att,
                             role: roleFor[att] ?? nil,
                             pastMeetings: pastMeetings[att, default: 0])
            }
            .sorted {
                if $0.pastMeetings != $1.pastMeetings { return $0.pastMeetings > $1.pastMeetings }
                // tie-break by original first-seen index → stable
                let li = attendeeOrder.firstIndex(of: $0.name) ?? 0
                let ri = attendeeOrder.firstIndex(of: $1.name) ?? 0
                return li < ri
            }

        let related = relatedSet.sorted()

        return PrepBriefData(meetingTitle: cleanTitle.isEmpty ? "회의" : cleanTitle,
                             attendees: attendees,
                             decisions: cappedDecisions,
                             openItems: cappedOpen,
                             relatedTalks: related)
    }

    /// A grounded LLM query string for the optional "search workspace for more
    /// context" toggle. The view feeds this (plus retrieved excerpts) to
    /// SummaryEngine.askPreselected — kept here so the prompt wording is one place
    /// and unit-testable, not buried in the view.
    static func contextQuery(title: String, attendees: [String]) -> String {
        let who = attendees
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if who.isEmpty {
            return "\(t.isEmpty ? "이번 회의" : t)와 관련해 아직 해결되지 않은 결정이나 액션은 무엇입니까?"
        }
        return "\(t.isEmpty ? "이번 회의" : t)에 대해 \(who)와(과) 관련된 미해결 결정 또는 액션은 무엇입니까?"
    }

    // MARK: - helpers

    /// Pull a parenthetical role from a matched speaker label: "김부장(PM)" → "(PM)".
    /// Returns nil when the label has no trailing parenthetical.
    private static func extractRole(from label: String) -> String? {
        guard let open = label.lastIndex(of: "("),
              label.hasSuffix(")") else { return nil }
        let role = String(label[open...]).trimmingCharacters(in: .whitespaces)
        return role.count >= 3 ? role : nil   // at least "(x)"
    }

    /// Keep at most `perPersonCap` items per speaker while preserving the incoming
    /// (already deterministic) order.
    private static func capPerPerson(_ items: [PrepItem]) -> [PrepItem] {
        var count: [String: Int] = [:]
        var out: [PrepItem] = []
        for it in items {
            let c = count[it.speaker, default: 0]
            guard c < perPersonCap else { continue }
            count[it.speaker] = c + 1
            out.append(it)
        }
        return out
    }
}
