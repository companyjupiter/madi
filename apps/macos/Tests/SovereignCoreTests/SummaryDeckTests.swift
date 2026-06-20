// SummaryDeckTests — parsing the structured summary into slides + safe HTML.
import XCTest
@testable import SovereignCore

final class SummaryDeckTests: XCTestCase {

    private let sample = """
    [요약] 1분기 매출 목표를 초과 달성했고, 다음 스프린트를 시작합니다.
    [액션]
    - 김부장: 금요일까지 예산안 검토
    - 이영희: 캠페인 초안 작성
    [결정]
    - 다음 스프린트 월요일 시작
    """

    func testParsesThreeSections() {
        let secs = SummaryDeck.parseSections(sample)
        XCTAssertEqual(secs.map { $0.title }, ["요약", "액션 아이템", "결정 사항"])
        XCTAssertEqual(secs[1].bullets.count, 2)
        XCTAssertTrue(secs[0].paras.first?.contains("초과 달성") ?? false)
        XCTAssertEqual(secs[2].bullets, ["다음 스프린트 월요일 시작"])
    }

    func testHTMLIsSelfContainedAndStructured() {
        let html = SummaryDeck.html(summary: sample, speakerSummary: "■ 김부장: 예산 검토",
                                    title: "주간 회의", dateText: "2026년 6월 19일")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<style>"))            // inline CSS, no external assets
        XCTAssertFalse(html.contains("http://"))           // offline / self-contained
        XCTAssertTrue(html.contains("주간 회의"))           // title slide
        XCTAssertTrue(html.contains("액션 아이템"))          // action slide
        XCTAssertTrue(html.contains("화자별"))              // speaker slide appended
        XCTAssertTrue(html.contains("checklist"))          // action list styled as checklist
    }

    func testHTMLEscapesAngleBrackets() {
        let html = SummaryDeck.html(summary: "[요약] a < b & c > d", speakerSummary: nil,
                                    title: "T<x>", dateText: "d")
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"))
        XCTAssertTrue(html.contains("T&lt;x&gt;"))
        XCTAssertFalse(html.contains("a < b"))             // raw injected markup must not survive
    }

    func testFilenamePattern() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let name = SummaryDeck.filename(in: tmp, date: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertTrue(name.hasPrefix("summary-"))
        XCTAssertTrue(name.hasSuffix(".html"))
        XCTAssertTrue(name.contains("-1.")) // first non-colliding index
    }
}
