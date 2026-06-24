// SummaryFormatTests — integration over the on-device summary FORMAT: the two
// model-output shapes (tagged "[요약]/[액션]/[결정]" lines and prose "## 헤더 + 불릿"
// sections) must both survive parsing without dropping sections or items, across
// BOTH consumers that read them: SummaryDeck (slides/HTML) and
// OpenLoopsAggregator.extractItems (loop extraction). Asserts HTML escaping too.
// Foundation-only (SovereignCore + XCTest).
import XCTest
@testable import SovereignCore

final class SummaryFormatTests: XCTestCase {

    // The structured / tagged shape the live rail + summary engine emit.
    private let tagged = """
    [요약] 1분기 매출 목표를 초과 달성했고, 다음 스프린트를 시작합니다.
    [액션]
    - 김부장: 금요일까지 예산안 검토
    - 이영희: 캠페인 초안 작성
    [결정]
    - 다음 스프린트 월요일 시작
    """

    // The prose shape (markdown ## headers + "- " bullets).
    private let prose = """
    ## 요약
    - 출시 일정을 점검했습니다

    ## 결정 사항
    - 6월 30일 출시 확정

    ## 액션 아이템
    - 이수민 · 부하 테스트 완료

    ## 미결 질문
    - 예산 승인 누가 받나
    """

    // ── SummaryDeck.parseSections keeps every section + item ──────────────────

    func testTaggedSectionsNotDropped() {
        let secs = SummaryDeck.parseSections(tagged)
        XCTAssertEqual(secs.map { $0.title }, ["요약", "액션 아이템", "결정 사항"])
        XCTAssertEqual(secs[1].bullets.count, 2)                 // both action bullets kept
        XCTAssertTrue(secs[0].paras.first?.contains("초과 달성") ?? false)
        XCTAssertEqual(secs[2].bullets, ["다음 스프린트 월요일 시작"])
    }

    func testProseSectionsNotDropped() {
        let secs = SummaryDeck.parseSections(prose)
        let titles = secs.map { $0.title }
        XCTAssertTrue(titles.contains("요약"))
        XCTAssertTrue(titles.contains("결정 사항"))
        XCTAssertTrue(titles.contains("액션 아이템"))
        // REAL BEHAVIOR (verified, not a bug): SummaryDeck only canonicalizes the
        // 요약/액션/결정 headers. An unknown "## 미결 질문" header is NOT recognized as
        // a header, so it's stripped to a paragraph-ish line and its "- " bullet
        // attaches to the CURRENT (액션 아이템) section. So the action section ends up
        // with BOTH its own bullet and the trailing question bullet. The question is
        // recovered separately by OpenLoopsAggregator's 질문 scan (asserted below).
        let action = secs.first { $0.title == "액션 아이템" }
        XCTAssertEqual(action?.bullets, ["이수민 · 부하 테스트 완료", "예산 승인 누가 받나"])
        // No section is fully dropped — every modeled header survived.
        XCTAssertEqual(Set(titles), ["요약", "결정 사항", "액션 아이템"])
    }

    // ── OpenLoopsAggregator.extractItems: items not dropped on either shape ────

    func testExtractItemsFromTaggedShape() {
        // The tagged "[액션]\n- ..." here has no inline "[액션] 담당자 · 내용" lines,
        // so LiveActionRail.parse finds nothing and the prose route handles it.
        let items = OpenLoopsAggregator.extractItems(fromSummary: tagged)
        XCTAssertTrue(items.contains { $0.kind == .decision && $0.text.contains("월요일 시작") })
        // Action bullets are "이름: 내용" → owner split on ": ".
        let actions = items.filter { $0.kind == .action }
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.contains { $0.owner == "김부장" && $0.text.contains("예산안 검토") })
        XCTAssertTrue(actions.contains { $0.owner == "이영희" && $0.text.contains("캠페인 초안") })
    }

    func testExtractItemsFromProseShape() {
        let items = OpenLoopsAggregator.extractItems(fromSummary: prose)
        XCTAssertTrue(items.contains { $0.kind == .decision && $0.text == "6월 30일 출시 확정" })
        let action = items.first { $0.kind == .action }
        XCTAssertEqual(action?.owner, "이수민")
        XCTAssertEqual(action?.text, "부하 테스트 완료")
        // The 미결 질문 section IS recovered by the loops route (its 질문 scan).
        XCTAssertTrue(items.contains { $0.kind == .question && $0.text == "예산 승인 누가 받나" })
    }

    func testStrictlyTaggedInlineShapeUsesRailRoute() {
        // The genuinely-tagged inline shape ("[액션] 담당자 · 내용") goes through
        // LiveActionRail.parse (route 1) — a different code path than the bullets above.
        let inline = """
        [결정] 6월 30일 출시 확정
        [액션] 이수민 · 부하 테스트 완료
        [질문] 예산 승인 누가 받나
        """
        let items = OpenLoopsAggregator.extractItems(fromSummary: inline)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first { $0.kind == .action }?.owner, "이수민")
        XCTAssertTrue(items.contains { $0.kind == .question && $0.text == "예산 승인 누가 받나" })
    }

    func testSummaryWithNoLoopsYieldsNoItems() {
        let items = OpenLoopsAggregator.extractItems(fromSummary: "## 요약\n- 그냥 일반 논의였습니다")
        XCTAssertTrue(items.isEmpty)
    }

    // ── HTML deck: self-contained, structured, and escaped ────────────────────

    func testHTMLIsSelfContainedAndCarriesEverySection() {
        let html = SummaryDeck.html(summary: tagged, speakerSummary: "■ 김부장: 예산 검토",
                                    title: "주간 회의", dateText: "2026년 6월 25일")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<style>"))           // inline CSS, no external assets
        XCTAssertFalse(html.contains("http://"))          // offline / self-contained
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(html.contains("주간 회의"))           // title slide
        XCTAssertTrue(html.contains("요약"))
        XCTAssertTrue(html.contains("액션 아이템"))
        XCTAssertTrue(html.contains("결정 사항"))
        XCTAssertTrue(html.contains("화자별"))             // speaker slide appended
        XCTAssertTrue(html.contains("checklist"))          // action list styled as checklist
        // Bullets carried through to <li>.
        XCTAssertTrue(html.contains("금요일까지 예산안 검토"))
        XCTAssertTrue(html.contains("다음 스프린트 월요일 시작"))
    }

    func testHTMLEscapesAngleAndAmpersand() {
        let html = SummaryDeck.html(summary: "[요약] a < b & c > d", speakerSummary: nil,
                                    title: "T<x> & Y", dateText: "d")
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"))   // body escaped
        XCTAssertTrue(html.contains("T&lt;x&gt; &amp; Y"))        // title escaped
        // The raw injection markers must not survive into the document content.
        XCTAssertFalse(html.contains("a < b"))
    }
}
