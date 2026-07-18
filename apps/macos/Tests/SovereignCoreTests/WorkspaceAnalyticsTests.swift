// WorkspaceAnalyticsTests — the workspace 통계 rollup. Builds parsed transcript
// fixtures with injected dates + a fixed `now`/UTC calendar, and asserts counts,
// words, distinct speakers, duration, and the recent-weeks trend bucketing.
// GUI-free (SovereignCore + XCTest).
import XCTest
@testable import SovereignCore

final class WorkspaceAnalyticsTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_784_000_000)   // fixed reference

    private func parsed(_ t: String) -> TranscriptArchive.Parsed { TranscriptArchive.parse(text: t)! }

    // 3 words + 3 words + 1 word = 7; speakers 김부장·이대리 = 2; last line [01:00] = 60 s.
    private let m1 = """
    # Transcript

    - **[00:00] 김부장** 안건 시작합니다 오늘
    - **[00:30] 이대리** 네 준비 됐습니다
    - **[01:00] 김부장** 좋습니다
    """

    func testEmptyYieldsZeroedTrend() {
        let s = WorkspaceAnalytics.aggregate(meetings: [], now: now, calendar: cal)
        XCTAssertEqual(s.meetingCount, 0)
        XCTAssertEqual(s.weeklyTrend.count, WorkspaceAnalytics.trendWeeks)
        XCTAssertTrue(s.weeklyTrend.allSatisfy { $0 == 0 })
        XCTAssertEqual(s.avgSeconds, 0)
        XCTAssertEqual(s.avgSpeakers, 0)
    }

    func testCountsWordsSpeakersDuration() {
        let s = WorkspaceAnalytics.aggregate(meetings: [(now, parsed(m1))], now: now, calendar: cal)
        XCTAssertEqual(s.meetingCount, 1)
        XCTAssertEqual(s.totalWords, 7)
        XCTAssertEqual(s.speakerSum, 2)
        XCTAssertEqual(s.avgSpeakers, 2, accuracy: 1e-9)
        XCTAssertEqual(s.totalSeconds, 60, accuracy: 1e-6)
        XCTAssertEqual(s.avgSeconds, 60, accuracy: 1e-6)
    }

    func testThisWeekAndTrendBucketing() {
        let twoWeeksAgo = cal.date(byAdding: .weekOfYear, value: -2, to: now)!
        let s = WorkspaceAnalytics.aggregate(
            meetings: [(now, parsed(m1)), (twoWeeksAgo, parsed(m1)), (now, parsed(m1))],
            now: now, calendar: cal)
        XCTAssertEqual(s.meetingCount, 3)
        XCTAssertEqual(s.thisWeekCount, 2)
        XCTAssertEqual(s.weeklyTrend.last, 2)                                    // this week
        XCTAssertEqual(s.weeklyTrend[WorkspaceAnalytics.trendWeeks - 1 - 2], 1)  // 2 weeks ago
        XCTAssertEqual(s.weeklyTrend.reduce(0, +), 3)
    }

    func testOldMeetingsStillCountButLeaveTrend() {
        let old = cal.date(byAdding: .weekOfYear, value: -20, to: now)!
        let s = WorkspaceAnalytics.aggregate(meetings: [(old, parsed(m1))], now: now, calendar: cal)
        XCTAssertEqual(s.meetingCount, 1)               // still in totals
        XCTAssertEqual(s.thisWeekCount, 0)
        XCTAssertEqual(s.weeklyTrend.reduce(0, +), 0)   // outside the window
    }

    func testUnknownBucketNotCountedAsSpeaker() {
        let withUnknown = """
        # Transcript

        - **[00:00] 김부장** 안녕하세요
        - **[00:20] \(SpeakerID.unknownLabel)** 잡음
        - **[00:40] 김부장** 다음
        """
        let s = WorkspaceAnalytics.aggregate(meetings: [(now, parsed(withUnknown))], now: now, calendar: cal)
        XCTAssertEqual(s.speakerSum, 1)   // only 김부장; 미확인 excluded
    }
}
