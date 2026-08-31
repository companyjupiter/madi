// RecapDataTests — the recap card's pure model, now registry-kind bucketed:
// meeting summaries keep today's TL;DR/결정/액션 layout byte-for-byte, lecture
// sections (핵심 요점/용어·개념) land in `extras`, and interview 후속 조치 joins
// the action slot (kind .action). Foundation-only (SovereignCore + XCTest).
import XCTest
@testable import SovereignCore

final class RecapDataTests: XCTestCase {

    private func make(_ summary: String?) -> RecapData {
        RecapData.make(lines: [], names: [:], summary: summary,
                       title: "테스트 회의", date: Date(timeIntervalSince1970: 1_756_600_000))
    }

    // ── meeting = legacy baseline ─────────────────────────────────────────────

    func testMeetingSummaryBucketsAsToday() {
        let d = make("""
        [요약] 출시 일정을 확정했습니다.
        [액션]
        - 김부장: 예산안 검토
        [결정]
        - 6월 30일 출시
        """)
        XCTAssertEqual(d.tldr, ["출시 일정을 확정했습니다."])
        XCTAssertEqual(d.actions, ["김부장: 예산안 검토"])
        XCTAssertEqual(d.decisions, ["6월 30일 출시"])
        XCTAssertTrue(d.extras.isEmpty)
    }

    func testMeetingMarkdownKeepsLegacyLayout() {
        let d = make("[요약] 개요.\n[액션]\n- A: 할일\n[결정]\n- 결정1")
        XCTAssertEqual(d.markdown,
            "# 테스트 회의\n\n_\(d.dateText)_\n\n## TL;DR\n- 개요.\n\n## 결정\n- 결정1\n\n## 액션\n- [ ] A: 할일\n")
    }

    // ── lecture → extras ──────────────────────────────────────────────────────

    func testLectureSectionsLandInExtrasInSummaryOrder() {
        let d = make("""
        [요약] 분산 시스템의 합의 알고리즘을 다뤘습니다.
        [요점]
        - 리더 선출은 과반 투표로 결정된다
        [용어]
        - 쿼럼: 합의에 필요한 최소 노드 수
        """)
        XCTAssertEqual(d.tldr, ["분산 시스템의 합의 알고리즘을 다뤘습니다."])
        XCTAssertTrue(d.actions.isEmpty)
        XCTAssertTrue(d.decisions.isEmpty)
        XCTAssertEqual(d.extras.map(\.title), ["핵심 요점", "용어·개념"])
        XCTAssertEqual(d.extras.first?.items, ["리더 선출은 과반 투표로 결정된다"])
        XCTAssertEqual(d.extras.last?.items, ["쿼럼: 합의에 필요한 최소 노드 수"])
    }

    func testLectureMarkdownRendersExtrasAfterTldr() {
        let d = make("[요약] 개요.\n[요점]\n- 요점1\n[용어]\n- 용어1: 정의")
        let md = d.markdown
        let tldr = md.range(of: "## TL;DR")
        let kp = md.range(of: "## 핵심 요점")
        let term = md.range(of: "## 용어·개념")
        XCTAssertNotNil(tldr); XCTAssertNotNil(kp); XCTAssertNotNil(term)
        XCTAssertTrue(tldr!.lowerBound < kp!.lowerBound && kp!.lowerBound < term!.lowerBound)
        XCTAssertFalse(md.contains("## 결정"))
        XCTAssertFalse(md.contains("## 액션"))
    }

    // ── interview: 문답 → extras, 후속 → actions ──────────────────────────────

    func testInterviewFollowUpsJoinActions() {
        let d = make("""
        [요약] 채용 인터뷰를 진행했습니다.
        [문답]
        - Q: 장애 대응 경험은? → A: 대규모 장애 3건 주도 복구
        [후속]
        - 김부장: 레퍼런스 체크
        """)
        XCTAssertEqual(d.extras.map(\.title), ["문답"])
        XCTAssertEqual(d.extras.first?.items, ["Q: 장애 대응 경험은? → A: 대규모 장애 3건 주도 복구"])
        XCTAssertEqual(d.actions, ["김부장: 레퍼런스 체크"])   // 후속 조치 = action kind
        XCTAssertTrue(d.decisions.isEmpty)
    }

    func testInterviewMarkdownPlacesQaBeforeActions() {
        let d = make("[요약] 개요.\n[문답]\n- Q: q → A: a\n[후속]\n- 담당: 조치")
        let md = d.markdown
        let qa = md.range(of: "## 문답")
        let act = md.range(of: "## 액션")
        XCTAssertNotNil(qa); XCTAssertNotNil(act)
        XCTAssertTrue(qa!.lowerBound < act!.lowerBound)
        XCTAssertTrue(md.contains("- [ ] 담당: 조치"))   // 후속 renders as checkbox
    }

    // ── degenerate inputs ─────────────────────────────────────────────────────

    func testNilOrBlankSummaryYieldsEmptyBuckets() {
        for s in [nil, "", "  \n "] as [String?] {
            let d = make(s)
            XCTAssertTrue(d.tldr.isEmpty && d.decisions.isEmpty
                          && d.actions.isEmpty && d.extras.isEmpty)
        }
    }
}
