// WorkspaceAnalytics.swift — pure aggregator for the workspace 통계 (stats) tab.
// Reduces every saved transcript into workspace-level activity metrics: meeting
// count, total & average length, total words, average distinct speakers, and a
// recent-weeks meeting trend. No LLM, no voiceprints — just the parsed .md files
// (summary siblings excluded by the caller). Deterministic + Foundation-only
// (calendar/now injected) so it joins SovereignCore + XCTest. WorkspaceStatsView
// renders what this produces.

import Foundation

/// Workspace-level activity rollup over saved transcripts. Duration per meeting is
/// the last line's timestamp (the meeting span); word counts sum per-line word
/// tokens. Distinct speakers exclude the reserved 미확인 bucket and non-speech.
struct WorkspaceStats: Equatable {
    var meetingCount = 0
    var totalSeconds = 0.0
    var totalWords = 0
    /// Σ (distinct real speakers) across meetings — divided by count for the average.
    var speakerSum = 0
    var thisWeekCount = 0
    /// Meetings per week for the last `WorkspaceAnalytics.trendWeeks` weeks,
    /// oldest → newest; the final element is the current (this) week.
    var weeklyTrend: [Int] = []

    var avgSeconds: Double { meetingCount > 0 ? totalSeconds / Double(meetingCount) : 0 }
    var avgSpeakers: Double { meetingCount > 0 ? Double(speakerSum) / Double(meetingCount) : 0 }
}

enum WorkspaceAnalytics {
    /// Weeks shown in the trend sparkline (includes the current week).
    static let trendWeeks = 6

    /// Aggregate saved meetings into workspace stats. `now`/`calendar` are injected
    /// so week bucketing is deterministic (tests pass fixed values).
    static func aggregate(meetings: [(date: Date, parsed: TranscriptArchive.Parsed)],
                          now: Date, calendar: Calendar = .current) -> WorkspaceStats {
        var s = WorkspaceStats()
        s.weeklyTrend = Array(repeating: 0, count: trendWeeks)
        guard !meetings.isEmpty else { return s }

        let nowWeek = startOfWeek(now, calendar)
        for (date, parsed) in meetings {
            s.meetingCount += 1
            s.totalSeconds += max(0, parsed.lines.last?.end ?? 0)
            s.totalWords += parsed.lines.reduce(0) { $0 + $1.words.count }
            let speakers = Set(parsed.lines.map(\.speaker).filter { $0 >= 0 && $0 != SpeakerID.unknown })
            s.speakerSum += speakers.count

            // weeks-ago bucketing: 0 = this week, up to trendWeeks-1 back.
            let ago = calendar.dateComponents([.weekOfYear], from: startOfWeek(date, calendar), to: nowWeek).weekOfYear ?? Int.max
            if ago == 0 { s.thisWeekCount += 1 }
            if ago >= 0, ago < trendWeeks { s.weeklyTrend[trendWeeks - 1 - ago] += 1 }
        }
        return s
    }

    /// First moment of the week containing `date` (respects the calendar's firstWeekday).
    private static func startOfWeek(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
    }
}
