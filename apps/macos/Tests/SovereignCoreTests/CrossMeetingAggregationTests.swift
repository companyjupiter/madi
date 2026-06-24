// CrossMeetingAggregationTests — END-TO-END cross-meeting aggregation through the
// FILE-URL route. Writes 3 saved transcript .md files into a FileManager temp dir
// (each carrying an inline "## 회의 요약" loop block + speaker-attributed bullets),
// then asserts the three workspace aggregators agree across them:
//   · WorkspaceRetrieval.relevantExcerpts  — pulls the right lines from the right
//     meetings, deterministically.
//   · PeopleAnalytics.aggregate            — per-person meeting counts + summed
//     talk-time + deterministic sort, by NAME match across files.
//   · OpenLoopsAggregator.aggregate        — loop extraction, age, cross-meeting
//     re-mention follow-up, unresolved-first/oldest-first sort.
// OpenLoops age math uses a FIXED `now` (never Date()) so it is deterministic.
// Foundation-only (SovereignCore + XCTest); the only I/O is the temp .md files.
import XCTest
@testable import SovereignCore

final class CrossMeetingAggregationTests: XCTestCase {

    private var dir: URL!
    private var urls: [String: URL] = [:]   // basename → file url

    private let cal = Calendar(identifier: .gregorian)
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    // Fixed "now" so OpenLoopsAggregator age math is deterministic.
    private lazy var now = day(2026, 6, 25)

    // ── three saved meetings as real .md files ─────────────────────────────────
    // 회의1 (oldest): 김부장 commits 이수민 to a load test (an action loop).
    // 회의2 (middle): 김부장 + 이대리; re-mentions the load test → resolves 회의1's loop.
    // 회의3 (newest): 이대리 only; an unresolved decision.

    private let m1 = """
    # Transcript

    ## 회의 요약

    [결정] 6월 30일 출시 확정
    [액션] 이수민 · 부하 테스트 완료

    ---

    > *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.

    - **[00:00] 김부장** 출시 일정을 점검합시다
    - **[00:30] 이대리** 부하 테스트는 이수민이 맡기로 했습니다
    - **[01:00] Speaker 2** 확인했습니다
    """

    private let m2 = """
    # Transcript

    ## 회의 요약

    [질문] 마케팅 예산 누가 승인하나

    ---

    > *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.

    - **[00:00] 김부장** 이수민이 부하 테스트 결과를 공유했습니다
    - **[00:45] 이대리** 다음은 마케팅 예산 얘기입니다
    """

    private let m3 = """
    # Transcript

    ## 회의 요약

    [결정] 디자인 시안 A안으로 확정

    ---

    > *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.

    - **[00:00] 이대리** 디자인 시안은 A안으로 갑니다
    """

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmeeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func write(_ name: String, _ text: String, date: Date) throws -> URL {
            let url = dir.appendingPathComponent("\(name).md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            // Stamp creation+modification dates so OpenLoopsAggregator's age + "later
            // meeting" ordering is driven by our fixtures, not the write order.
            try FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        urls["회의1"] = try write("회의1", m1, date: day(2026, 6, 1))
        urls["회의2"] = try write("회의2", m2, date: day(2026, 6, 8))
        urls["회의3"] = try write("회의3", m3, date: day(2026, 6, 20))
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private var allFiles: [URL] { ["회의1", "회의2", "회의3"].map { urls[$0]! } }

    // ── WorkspaceRetrieval across files ────────────────────────────────────────

    func testWorkspaceRetrievalPullsRightLinesFromRightMeetings() {
        let hits = WorkspaceRetrieval.relevantExcerpts("부하 테스트 누가 맡나", mdFiles: allFiles, budget: 4000)
        XCTAssertFalse(hits.isEmpty)
        // The matching lines live in 회의1 and 회의2, never 회의3 (design only).
        XCTAssertTrue(hits.contains { $0.meeting == "회의1" })
        XCTAssertTrue(hits.contains { $0.text.contains("부하 테스트") })
        XCTAssertFalse(hits.contains { $0.meeting == "회의3" })
    }

    func testWorkspaceRetrievalDeterministicAndBudgeted() {
        let q = "부하 테스트"
        let a = WorkspaceRetrieval.relevantExcerpts(q, mdFiles: allFiles, budget: 4000)
        // Same query, reversed input order → identical result (deterministic).
        let b = WorkspaceRetrieval.relevantExcerpts(q, mdFiles: allFiles.reversed(), budget: 4000)
        XCTAssertEqual(a.map { "\($0.meeting)|\($0.text)" }, b.map { "\($0.meeting)|\($0.text)" })
        // A zero budget yields nothing.
        XCTAssertTrue(WorkspaceRetrieval.relevantExcerpts(q, mdFiles: allFiles, budget: 0).isEmpty)
    }

    // ── PeopleAnalytics across files ───────────────────────────────────────────

    func testPeopleAnalyticsCountsAndTalkTimeAcrossFiles() {
        let people = PeopleAnalytics.aggregate(
            voiceprintNames: ["김부장", "이대리", "박과장"], mdFiles: allFiles)
        let by = Dictionary(uniqueKeysWithValues: people.map { ($0.name, $0) })

        // 김부장 speaks in 회의1 + 회의2; 이대리 in all three.
        XCTAssertEqual(by["김부장"]?.meetings, 2)
        XCTAssertEqual(by["이대리"]?.meetings, 3)
        // 박과장 enrolled but unseen → kept with zero meetings.
        XCTAssertEqual(by["박과장"]?.meetings, 0)
        XCTAssertEqual(by["박과장"]?.totalTalk, 0)

        // Talk-time is the derived span Σ(line.end − line.start) over a person's
        // lines; everyone who spoke has > 0.
        XCTAssertGreaterThan(by["이대리"]!.totalTalk, 0)
        XCTAssertGreaterThan(by["김부장"]!.totalTalk, 0)

        // Deterministic sort: totalTalk desc, then name. Reversing input is stable.
        let rev = PeopleAnalytics.aggregate(
            voiceprintNames: ["박과장", "이대리", "김부장"], mdFiles: allFiles.reversed())
        XCTAssertEqual(people.map(\.name), rev.map(\.name))
        // Unseen person sorts last (zero talk).
        XCTAssertEqual(people.last?.name, "박과장")
    }

    // ── OpenLoopsAggregator across files (fixed `now`) ─────────────────────────

    func testOpenLoopsAggregateWithFollowUpAndDeterministicSort() {
        let loops = OpenLoopsAggregator.aggregate(mdFiles: allFiles, now: now)
        XCTAssertFalse(loops.isEmpty)

        // 회의1's "이수민 · 부하 테스트" action is re-mentioned in the LATER 회의2
        // ("이수민이 부하 테스트 결과를 공유") → resolved, followed up 7 days later.
        let loadTest = loops.first { $0.kind == .action && $0.text.contains("부하 테스트") }
        XCTAssertNotNil(loadTest)
        XCTAssertEqual(loadTest?.owner, "이수민")
        XCTAssertTrue(loadTest!.isResolved)
        XCTAssertEqual(loadTest?.followedUpInMeeting, "회의2")
        XCTAssertEqual(loadTest?.followUpAfterDays, 7)             // 6/1 → 6/8

        // 회의3's decision is unresolved (no later meeting).
        let design = loops.first { $0.kind == .decision && $0.text.contains("디자인 시안") }
        XCTAssertNotNil(design)
        XCTAssertFalse(design!.isResolved)

        // Deterministic age math off the FIXED `now`: 회의1 loop is 24 days old.
        XCTAssertEqual(loadTest?.ageDays(now: now, calendar: cal), 24)   // 6/1 → 6/25

        // Sort contract: unresolved items lead, resolved sink to the bottom.
        XCTAssertFalse(loops.first!.isResolved)
        XCTAssertTrue(loops.last!.isResolved)

        // Fully deterministic across input order.
        let rev = OpenLoopsAggregator.aggregate(mdFiles: allFiles.reversed(), now: now)
        XCTAssertEqual(loops.map(\.id), rev.map(\.id))
    }

    func testOpenLoopsUnreadableFilesSkippedGracefully() {
        let missing = dir.appendingPathComponent("does-not-exist.md")
        let loops = OpenLoopsAggregator.aggregate(mdFiles: allFiles + [missing], now: now)
        // Same result as without the bogus URL — unreadable files are skipped.
        let base = OpenLoopsAggregator.aggregate(mdFiles: allFiles, now: now)
        XCTAssertEqual(loops.map(\.id), base.map(\.id))
    }
}
