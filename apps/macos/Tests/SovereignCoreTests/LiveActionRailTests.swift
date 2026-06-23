// LiveActionRailTests — the live decisions/actions/questions extractor parse. GUI-free.
import XCTest
@testable import SovereignCore

final class LiveActionRailTests: XCTestCase {

    func testParsesEachKindAndActionOwner() {
        let reply = """
        [결정] 결제 안정화를 Q3 최우선으로
        [액션] 이수민 · 부하 테스트 시나리오 작성
        [질문] SDK 릴리스 일정 미정
        """
        let items = LiveActionRail.parse(reply)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].kind, .decision)
        XCTAssertEqual(items[0].text, "결제 안정화를 Q3 최우선으로")
        XCTAssertEqual(items[1].kind, .action)
        XCTAssertEqual(items[1].owner, "이수민")
        XCTAssertEqual(items[1].text, "부하 테스트 시나리오 작성")
        XCTAssertEqual(items[2].kind, .question)
        XCTAssertNil(items[2].owner)
    }

    func testIgnoresJunkAndBareNone() {
        XCTAssertTrue(LiveActionRail.parse("없음").isEmpty)
        XCTAssertTrue(LiveActionRail.parse("그냥 잡담 한 줄\n또 다른 줄").isEmpty)
        // mixed: only the tagged line is kept
        let items = LiveActionRail.parse("서론입니다\n[결정] 채택\n맺음말")
        XCTAssertEqual(items.map(\.text), ["채택"])
    }

    func testDedupesIdenticalItems() {
        let items = LiveActionRail.parse("[결정] 같은 결정\n[결정] 같은 결정")
        XCTAssertEqual(items.count, 1)
    }

    func testActionWithoutOwnerStaysWhole() {
        let items = LiveActionRail.parse("[액션] 문서 정리하기")
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].owner)
        XCTAssertEqual(items[0].text, "문서 정리하기")
    }

    func testPromptEmbedsTranscript() {
        let p = LiveActionRail.prompt("화자1: 안녕하세요")
        XCTAssertTrue(p.contains("화자1: 안녕하세요"))
        XCTAssertTrue(p.contains("[결정]"))
    }
}
