// RetrievalTests — lexical transcript retrieval for long-meeting Q&A.
import XCTest
@testable import SovereignCore

final class RetrievalTests: XCTestCase {

    func testKeywordsDropInterrogativesAndStemKorean() {
        let kw = Retrieval.keywords("김부장이 맡은 일은?")
        // "일은" is a stopword; "김부장이" stays AND stems to "김부장"
        XCTAssertTrue(kw.contains("김부장이"))
        XCTAssertTrue(kw.contains("김부장"), "Korean particle stem must be indexed")
        XCTAssertFalse(kw.contains("일은"))
    }

    func testShortTranscriptReturnedWhole() {
        let lines = ["김부장: 안녕하세요", "이영희: 반갑습니다"]
        XCTAssertEqual(Retrieval.relevantLines("무엇을 결정했나요?", lines, budget: 1000), lines)
    }

    func testRetrievesRelevantLinesWithinBudget() {
        // 6 lines, only some about 예산; budget forces a subset; speaker-name match works
        let lines = [
            "김부장: 오늘 날씨가 좋네요",
            "이영희: 마케팅 예산이 부족합니다",
            "박철수: 점심은 김밥",
            "김부장: 예산안은 금요일까지 검토하겠습니다",
            "이영희: 캠페인 초안 작성하겠습니다",
            "박철수: 채용 두 명 진행",
        ]
        let picked = Retrieval.relevantLines("예산은 누가 맡나요?", lines, budget: 60)
        XCTAssertFalse(picked.isEmpty)
        // the 예산 lines must be selected over the weather/lunch lines
        XCTAssertTrue(picked.contains { $0.contains("예산") })
        XCTAssertFalse(picked.contains("박철수: 점심은 김밥"))
        // chronological order preserved among picks
        XCTAssertEqual(picked, picked.sorted { a, b in
            (lines.firstIndex(of: a) ?? 0) < (lines.firstIndex(of: b) ?? 0) })
    }

    func testNoKeywordMatchReturnsEmpty() {
        let lines = (0..<50).map { "화자\($0 % 3): 어쩌고 저쩌고 매우 긴 발언이 여기에 들어갑니다 \($0)" }
        // a question whose content word appears nowhere → empty (model says "없음")
        XCTAssertTrue(Retrieval.relevantLines("우주선 발사는?", lines, budget: 200).isEmpty)
    }
}
