import XCTest
@testable import SovereignCore

/// guard 5 (2026-09-11): a single Sino digit before 시 converts only when what
/// follows reads as a time.
final class KoreanNumberFormatterGuard5Tests: XCTestCase {
    func testHonorificComeStaysAVerb() {
        XCTAssertEqual(KoreanNumberFormatter.format("바이쉬 놀러 오시면 제가 소개시켜 드리겠습니다."), "바이쉬 놀러 오시면 제가 소개시켜 드리겠습니다.")
        XCTAssertEqual(KoreanNumberFormatter.format("여기 사시면 편해요"), "여기 사시면 편해요")
        XCTAssertEqual(KoreanNumberFormatter.format("일시적으로 구시가지에 사시사철"), "일시적으로 구시가지에 사시사철")
        XCTAssertEqual(KoreanNumberFormatter.format("오시는 분들은 오시라고"), "오시는 분들은 오시라고")
    }
    func testRealTimesStillConvert() {
        XCTAssertEqual(KoreanNumberFormatter.format("오시에 만나요"), "5시에 만나요")
        XCTAssertEqual(KoreanNumberFormatter.format("오시까지 오세요"), "5시까지 오세요")
        XCTAssertEqual(KoreanNumberFormatter.format("오시 반에"), "5시 반에")
        XCTAssertEqual(KoreanNumberFormatter.format("지금 오시."), "지금 5시.")
        XCTAssertEqual(KoreanNumberFormatter.format("열한시 삼십오분"), "11시 35분")
        XCTAssertEqual(KoreanNumberFormatter.format("삼시 반부터"), "3시 반부터")
    }
}
