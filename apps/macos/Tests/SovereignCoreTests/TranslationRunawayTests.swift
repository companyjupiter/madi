import XCTest
@testable import SovereignCore

/// T7 (2026-09-06): bounds on a runaway translation. A 9-word line produced a
/// ~500-token cycling list live; both bounds scale with the SOURCE.
final class TranslationRunawayTests: XCTestCase {

    func testTokenCapScalesWithSourceAndIsClamped() {
        XCTAssertEqual(TranslationOutputPolicy.tokenCap(source: "Hi"), 48, "floor for one-word replies")
        let line = "I was actually more into reading and arts."            // 42 chars
        XCTAssertEqual(TranslationOutputPolicy.tokenCap(source: line), 87)  // 63 + 24
        let long = String(repeating: "word ", count: 120)                     // 600 chars
        XCTAssertEqual(TranslationOutputPolicy.tokenCap(source: long), 512, "never above the engine cap")
    }

    func testRunawayLimitIsThreeTimesSourceWithFloor() {
        XCTAssertEqual(TranslationOutputPolicy.runawayLimit(source: "Yes."), 80)
        XCTAssertEqual(TranslationOutputPolicy.runawayLimit(source: String(repeating: "a", count: 50)), 150)
    }

    func testTruncateKeepsShortRepliesUntouched() {
        let ok = "실제로는 읽고 예술에 더 관심이 있었습니다."
        XCTAssertEqual(TranslationOutputPolicy.truncateRunaway(ok, limit: 80), ok)
    }

    func testTruncateCutsAtLastSentenceEndInsideLimit() {
        let runaway = "실제로는 읽고 예술에 더 관심이 있었습니다. 학교에서는 수학, 과학, 역사, 지리, 영어, 프랑스어, 독일어, 스페인어, 미술, 음악, 체육, 컴퓨터 과학, 사회학, 심리학, 철학, 경제학, 정치학, 생물학"
        let cut = TranslationOutputPolicy.truncateRunaway(runaway, limit: 80)
        XCTAssertEqual(cut, "실제로는 읽고 예술에 더 관심이 있었습니다.")
    }

    func testTruncateHardCutsWhenNoSentenceEndIsUsable() {
        let list = String(repeating: "수학, ", count: 40)   // no sentence end at all
        let cut = TranslationOutputPolicy.truncateRunaway(list, limit: 80)
        XCTAssertLessThanOrEqual(cut.count, 80)
        XCTAssertFalse(cut.isEmpty)
    }
}
