// MeetingPrepBriefTests — the pre-meeting prep aggregator + its value model.
// Builds transcript fixtures (parsed in-memory AND via temp .md files), asserts
// decision/open-item extraction for a SUBSET of attendees, cross-meeting
// aggregation, deterministic ordering, role extraction, and the Markdown export.
// GUI-free (SovereignCore + XCTest). Pattern: PeopleAnalyticsTests + WorkspaceRetrievalTests.
import XCTest
@testable import SovereignCore

final class MeetingPrepBriefTests: XCTestCase {

    // Meeting 1: 김부장(PM) and 이대리 each make a decision and leave an open item;
    // an un-attending Speaker 2 also speaks (must never leak into an attendee's items).
    private let meeting1 = """
    # Transcript

    - **[00:00] 김부장(PM)** 출시 일정을 6월로 확정합니다
    - **[00:20] 이대리** 디자인 검토가 아직 미정입니다
    - **[00:40] 김부장(PM)** 예산은 다음 회의에서 확인 필요
    - **[01:00] 이대리** 마케팅 예산을 승인하기로 합의했습니다
    - **[01:20] Speaker 2** 저는 그냥 잡담입니다
    """

    // Meeting 2: 김부장 appears again (so pastMeetings=2) with one open item; 박과장
    // (not an attendee of our query) makes a decision — must be excluded.
    private let meeting2 = """
    # Transcript

    - **[00:00] 김부장** 서버 이전은 보류합니다
    - **[00:30] 박과장** 채용은 확정되었습니다
    """

    private func parsed(_ pairs: [(String, String)]) -> [(meeting: String, parsed: TranscriptArchive.Parsed)] {
        pairs.compactMap { name, text in
            guard let p = TranscriptArchive.parse(text: text) else { return nil }
            return (meeting: name, parsed: p)
        }
    }

    // MARK: - extraction for an attendee SUBSET

    func testDecisionsAndOpenItemsForSubsetAttendees() {
        // Query only 김부장 + 이대리 — 박과장's decision in meeting2 must be excluded.
        let brief = MeetingPrepBrief.aggregate(
            title: "스프린트 회의",
            attendees: ["김부장", "이대리"],
            parsed: parsed([("회의A", meeting1), ("회의B", meeting2)]))

        // Decisions: 김부장 "6월로 확정", 이대리 "승인하기로 합의" — both cue-matched.
        let decTexts = brief.decisions.map(\.text)
        XCTAssertTrue(decTexts.contains { $0.contains("확정합니다") }, "확정 decision missing")
        XCTAssertTrue(decTexts.contains { $0.contains("합의했습니다") }, "합의 decision missing")
        // 박과장's "채용은 확정되었습니다" must NOT appear (not a queried attendee).
        XCTAssertFalse(decTexts.contains { $0.contains("채용") }, "non-attendee decision leaked")

        // Open items: "검토가 아직 미정", "다음 회의에서 확인 필요", "서버 이전은 보류".
        let openTexts = brief.openItems.map(\.text)
        XCTAssertTrue(openTexts.contains { $0.contains("미정") })
        XCTAssertTrue(openTexts.contains { $0.contains("확인 필요") })
        XCTAssertTrue(openTexts.contains { $0.contains("보류") })

        // Speaker 2 jabber is neither a decision nor an open item.
        XCTAssertFalse(decTexts.contains { $0.contains("잡담") })
        XCTAssertFalse(openTexts.contains { $0.contains("잡담") })
    }

    // MARK: - cross-meeting aggregation

    func testPastMeetingCountAndRelatedTalks() {
        let brief = MeetingPrepBrief.aggregate(
            title: "스프린트 회의",
            attendees: ["김부장", "이대리"],
            parsed: parsed([("회의A", meeting1), ("회의B", meeting2)]))

        let by = Dictionary(uniqueKeysWithValues: brief.attendees.map { ($0.name, $0) })
        XCTAssertEqual(by["김부장"]?.pastMeetings, 2)   // both meetings (both-ways substring)
        XCTAssertEqual(by["이대리"]?.pastMeetings, 1)   // meeting1 only
        // Both meetings contributed an attendee → both are related talks.
        XCTAssertEqual(brief.relatedTalks, ["회의A", "회의B"])
    }

    func testRoleExtractedFromParenthetical() {
        let brief = MeetingPrepBrief.aggregate(
            title: "스프린트 회의",
            attendees: ["김부장"],
            parsed: parsed([("회의A", meeting1)]))
        let kim = brief.attendees.first { $0.name == "김부장" }
        XCTAssertEqual(kim?.role, "(PM)")   // recovered from "김부장(PM)" label
    }

    // MARK: - determinism / stability

    func testDeterministicOrdering() {
        let p = parsed([("회의A", meeting1), ("회의B", meeting2)])
        let a = MeetingPrepBrief.aggregate(title: "회의", attendees: ["이대리", "김부장"], parsed: p)
        let b = MeetingPrepBrief.aggregate(title: "회의", attendees: ["이대리", "김부장"], parsed: p)
        XCTAssertEqual(a.decisions.map(\.id), b.decisions.map(\.id))
        XCTAssertEqual(a.openItems.map(\.id), b.openItems.map(\.id))
        XCTAssertEqual(a.attendees.map(\.name), b.attendees.map(\.name))
        // Decisions ordered by (meeting, line order): 회의A items precede 회의B.
        let meetings = a.decisions.map(\.meeting)
        XCTAssertEqual(meetings, meetings.sorted())
    }

    func testAttendeesSortedByMeetingCountDescending() {
        let brief = MeetingPrepBrief.aggregate(
            title: "회의",
            attendees: ["이대리", "김부장"],   // input order: 이대리 first
            parsed: parsed([("회의A", meeting1), ("회의B", meeting2)]))
        // 김부장 (2 meetings) leads 이대리 (1) regardless of input order.
        XCTAssertEqual(brief.attendees.first?.name, "김부장")
    }

    // MARK: - empty / graceful

    func testEmptyWorkspaceYieldsEmptyBrief() {
        let brief = MeetingPrepBrief.aggregate(
            title: "신규 회의", attendees: ["김부장"], parsed: [])
        XCTAssertTrue(brief.isEmpty)
        XCTAssertEqual(brief.meetingTitle, "신규 회의")
    }

    func testNoAttendeesYieldsEmptyBrief() {
        let brief = MeetingPrepBrief.aggregate(
            title: "회의", attendees: ["  ", ""],
            parsed: parsed([("회의A", meeting1)]))
        XCTAssertTrue(brief.isEmpty)
    }

    func testNonMatchingAttendeeStillListedWithZeroMeetings() {
        let brief = MeetingPrepBrief.aggregate(
            title: "회의", attendees: ["김부장", "최사원"],
            parsed: parsed([("회의A", meeting1)]))
        let by = Dictionary(uniqueKeysWithValues: brief.attendees.map { ($0.name, $0) })
        XCTAssertEqual(by["최사원"]?.pastMeetings, 0)   // enrolled-but-unseen survives
        XCTAssertEqual(by["김부장"]?.pastMeetings, 1)
    }

    // MARK: - URL path

    func testURLPathParsesTempFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingPrepBriefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let u1 = dir.appendingPathComponent("회의A.md")
        let u2 = dir.appendingPathComponent("회의B.md")
        try meeting1.write(to: u1, atomically: true, encoding: .utf8)
        try meeting2.write(to: u2, atomically: true, encoding: .utf8)

        let brief = MeetingPrepBrief.aggregate(
            title: "스프린트 회의", attendees: ["김부장", "이대리"], mdFiles: [u2, u1])
        // Order-independent of input file order (sorted by path internally).
        XCTAssertEqual(brief.relatedTalks, ["회의A", "회의B"])
        XCTAssertFalse(brief.decisions.isEmpty)
        XCTAssertFalse(brief.openItems.isEmpty)
    }

    // MARK: - context query (LLM toggle prompt)

    func testContextQueryMentionsTitleAndAttendees() {
        let q = MeetingPrepBrief.contextQuery(title: "출시 회의", attendees: ["김부장", "이대리"])
        XCTAssertTrue(q.contains("출시 회의"))
        XCTAssertTrue(q.contains("김부장"))
        XCTAssertTrue(q.contains("이대리"))
    }

    // MARK: - value model

    func testMarkdownExportFormatting() {
        let brief = MeetingPrepBrief.aggregate(
            title: "스프린트 회의",
            attendees: ["김부장", "이대리"],
            parsed: parsed([("회의A", meeting1), ("회의B", meeting2)]))
        let fixed = DateComponents(calendar: .current, year: 2026, month: 6, day: 23).date!
        let md = brief.markdown(date: fixed)

        XCTAssertTrue(md.hasPrefix("# 스프린트 회의 — 회의 준비 브리핑"))
        XCTAssertTrue(md.contains("## 회의 참석자"))
        XCTAssertTrue(md.contains("## 지난 결정"))
        XCTAssertTrue(md.contains("## 미해결 액션"))
        XCTAssertTrue(md.contains("- [ ] "))            // open items as checkboxes
        XCTAssertTrue(md.contains("지난 회의 2회"))     // 김부장's count rendered
        XCTAssertTrue(md.contains("(PM)"))              // role rendered
    }

    func testEmptyBriefMarkdownShowsNoContextLine() {
        let md = PrepBriefData.empty(title: "신규 회의").markdown()
        XCTAssertTrue(md.contains("지난 결정이나 미해결 액션을 찾지 못했습니다"))
    }
}
