// OpenLoopsAggregatorTests — the cross-meeting commitment tracker. Builds
// MeetingLoops fixtures in-memory (no temp files) and asserts: summary-section
// extraction (tagged + prose routes), age math, re-mention detection (keyword
// overlap, ≥2 hits), deterministic unresolved-first/oldest-first sort, and
// graceful handling of empty / summary-less input. GUI-free (SovereignCore + XCTest).
import XCTest
@testable import SovereignCore

final class OpenLoopsAggregatorTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // ── summary section extraction ────────────────────────────────────────────

    func testSummarySectionPullsBlockBetweenHeaderAndRule() {
        let md = """
        # Transcript

        ## 회의 요약

        [요약] 출시 일정 점검
        [결정] 6월 30일 출시 확정
        [액션] 이수민 · 부하 테스트 완료

        ---

        > *기울임* 표시…
        - **[00:00] 김부장** 회의 시작
        """
        let block = OpenLoopsAggregator.summarySection(md)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("[결정] 6월 30일 출시 확정"))
        XCTAssertFalse(block!.contains("회의 시작"))   // stops at the --- rule
    }

    func testSummarySectionNilWhenAbsent() {
        XCTAssertNil(OpenLoopsAggregator.summarySection("# Transcript\n\n- **[00:00] A** 안녕"))
    }

    func testExtractTaggedRoute() {
        let items = OpenLoopsAggregator.extractItems(fromSummary: """
        [결정] 6월 30일 출시 확정
        [액션] 이수민 · 부하 테스트 완료
        [질문] 예산 승인 누가 받나
        """)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].kind, .decision)
        let action = items.first { $0.kind == .action }
        XCTAssertEqual(action?.owner, "이수민")
        XCTAssertEqual(action?.text, "부하 테스트 완료")
        XCTAssertTrue(items.contains { $0.kind == .question && $0.text == "예산 승인 누가 받나" })
    }

    func testExtractProseRouteFallback() {
        // No tagged lines → SummaryDeck header+bullet route, plus a 질문 header.
        let items = OpenLoopsAggregator.extractItems(fromSummary: """
        ## 결정 사항
        - 6월 30일 출시 확정

        ## 액션 아이템
        - 이수민 · 부하 테스트 완료

        ## 미결 질문
        - 예산 승인 누가 받나
        """)
        XCTAssertTrue(items.contains { $0.kind == .decision && $0.text == "6월 30일 출시 확정" })
        let action = items.first { $0.kind == .action }
        XCTAssertEqual(action?.owner, "이수민")
        XCTAssertEqual(action?.text, "부하 테스트 완료")
        XCTAssertTrue(items.contains { $0.kind == .question && $0.text == "예산 승인 누가 받나" })
    }

    func testExtractEmptyForSummaryWithNoLoops() {
        let items = OpenLoopsAggregator.extractItems(fromSummary: "## 요약\n- 그냥 일반 논의였습니다")
        XCTAssertTrue(items.isEmpty)
    }

    // ── age math ──────────────────────────────────────────────────────────────

    func testAgeDaysWholeDays() {
        let item = OpenLoopItem(kind: .action, owner: nil, text: "x",
                                meetingName: "m", meetingDate: day(2026, 6, 11))
        XCTAssertEqual(item.ageDays(now: day(2026, 6, 23), calendar: cal), 12)
        XCTAssertEqual(item.ageDays(now: day(2026, 6, 11), calendar: cal), 0)
        // Future meeting date never goes negative.
        XCTAssertEqual(item.ageDays(now: day(2026, 6, 1), calendar: cal), 0)
    }

    // ── re-mention detection ──────────────────────────────────────────────────

    func testReMentionNeedsTwoKeywords() {
        let kws = OpenLoopsAggregator.loopKeywords(owner: "이수민", text: "부하 테스트 완료")
        // Later text repeats two distinct content words → re-mentioned.
        XCTAssertTrue(OpenLoopsAggregator.reMentions("이수민 부하 테스트 다시 진행", kws))
        // Only one shared word → not enough (conservative).
        XCTAssertFalse(OpenLoopsAggregator.reMentions("부하만 잠깐 언급", kws))
    }

    func testCrossMeetingFollowUpFlagged() {
        let m1 = MeetingLoops(
            name: "회의1", date: day(2026, 6, 1),
            items: [(.action, "이수민", "부하 테스트 완료")],
            searchText: "[액션] 이수민 · 부하 테스트 완료")
        let m2 = MeetingLoops(
            name: "회의2", date: day(2026, 6, 8),
            items: [],
            searchText: "이수민이 부하 테스트 결과를 공유했습니다")
        let loops = OpenLoopsAggregator.aggregate(meetings: [m1, m2], now: day(2026, 6, 23))
        XCTAssertEqual(loops.count, 1)
        XCTAssertTrue(loops[0].isResolved)
        XCTAssertEqual(loops[0].followedUpInMeeting, "회의2")
        XCTAssertEqual(loops[0].followUpAfterDays, 7)
    }

    func testEarlierMeetingDoesNotResolveLaterLoop() {
        // Re-mention only counts in a STRICTLY later meeting; an earlier one with
        // the same words must not resolve a later loop.
        let early = MeetingLoops(name: "이전", date: day(2026, 6, 1),
                                 items: [], searchText: "이수민 부하 테스트 얘기")
        let late = MeetingLoops(name: "이후", date: day(2026, 6, 10),
                                items: [(.action, "이수민", "부하 테스트 완료")],
                                searchText: "[액션] 이수민 · 부하 테스트 완료")
        let loops = OpenLoopsAggregator.aggregate(meetings: [early, late], now: day(2026, 6, 23))
        XCTAssertEqual(loops.count, 1)
        XCTAssertFalse(loops[0].isResolved)
    }

    // ── sorting ───────────────────────────────────────────────────────────────

    func testUnresolvedFirstThenOldest() {
        let old = MeetingLoops(name: "오래된", date: day(2026, 6, 1),
                               items: [(.decision, nil, "예산 동결 결정")],
                               searchText: "[결정] 예산 동결 결정")
        let recent = MeetingLoops(name: "최근", date: day(2026, 6, 20),
                                  items: [(.question, nil, "채용 계획 미정")],
                                  searchText: "[질문] 채용 계획 미정")
        // A meeting that re-mentions nothing here, so both stay unresolved.
        let loops = OpenLoopsAggregator.aggregate(meetings: [recent, old], now: day(2026, 6, 23))
        XCTAssertEqual(loops.map(\.meetingName), ["오래된", "최근"])  // oldest first
    }

    func testResolvedSinkBelowUnresolved() {
        let resolved = MeetingLoops(name: "해결됨", date: day(2026, 6, 1),
                                    items: [(.action, "박과장", "서버 증설 진행")],
                                    searchText: "[액션] 박과장 · 서버 증설 진행")
        let followUp = MeetingLoops(name: "후속", date: day(2026, 6, 5),
                                    items: [(.question, nil, "디자인 시안 미확정")],
                                    searchText: "박과장 서버 증설 완료 보고")
        let loops = OpenLoopsAggregator.aggregate(meetings: [resolved, followUp], now: day(2026, 6, 23))
        XCTAssertEqual(loops.count, 2)
        XCTAssertFalse(loops[0].isResolved)              // unresolved on top
        XCTAssertTrue(loops.last!.isResolved)            // resolved sinks
    }

    func testDeterministicAcrossInputOrder() {
        let a = MeetingLoops(name: "A", date: day(2026, 6, 1),
                             items: [(.decision, nil, "loop A")], searchText: "x")
        let b = MeetingLoops(name: "B", date: day(2026, 6, 1),
                             items: [(.decision, nil, "loop B")], searchText: "y")
        let one = OpenLoopsAggregator.aggregate(meetings: [a, b], now: day(2026, 6, 23))
        let two = OpenLoopsAggregator.aggregate(meetings: [b, a], now: day(2026, 6, 23))
        XCTAssertEqual(one.map(\.id), two.map(\.id))     // same-date tie-break stable
    }

    // ── graceful empties ──────────────────────────────────────────────────────

    func testEmptyInputYieldsNoLoops() {
        XCTAssertTrue(OpenLoopsAggregator.aggregate(meetings: []).isEmpty)
    }

    func testMeetingWithoutLoopsContributesNothing() {
        let m = MeetingLoops(name: "잡담", date: day(2026, 6, 1), items: [], searchText: "별 내용 없음")
        XCTAssertTrue(OpenLoopsAggregator.aggregate(meetings: [m]).isEmpty)
    }
}
