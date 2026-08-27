import XCTest
@testable import SovereignCore

/// Ported + validated against engine/metal/bench/wer_runs/ko_num3.py, which was
/// measured on FLEURS-ko (turbo CER 5.63→5.34; docs/ENGINE_EVAL.md). These cases
/// are the exact ones that drove the three ambiguity guards.
final class KoreanNumberFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { KoreanNumberFormatter.format(s) }

    // MARK: true conversions (the win)

    func testSinoDateAndTime() {
        XCTAssertEqual(f("천구백사십년"), "1940년")
        XCTAssertEqual(f("천구백육십삼 년"), "1963년")   // space before counter
        XCTAssertEqual(f("십오일"), "15일")            // 일 counter vs 일=1 collision
        XCTAssertEqual(f("삼십오분"), "35분")
        XCTAssertEqual(f("이천이십년 팔월"), "2020년 8월")   // single Sino digit ok before HARD counter
        XCTAssertEqual(f("팔월"), "8월")
        XCTAssertEqual(f("오분"), "5분")
        XCTAssertEqual(f("천 년"), "1000년")
    }

    func testNativeCountersAndMixed() {
        XCTAssertEqual(f("열한시 삼십오분"), "11시 35분")
        XCTAssertEqual(f("오후 열한시"), "오후 11시")
        XCTAssertEqual(f("두시 삼십분"), "2시 30분")
        XCTAssertEqual(f("열두시 오분"), "12시 5분")
        XCTAssertEqual(f("스물세 살"), "23살")
        XCTAssertEqual(f("아홉 명"), "9명")
        XCTAssertEqual(f("열아홉 명"), "19명")
        XCTAssertEqual(f("두 개 이상"), "2개 이상")
    }

    // MARK: ambiguity guards (the refutation-driven part)

    func testGuard1_onlyClearCounters() {
        // 번/차/등/위/도/장/대 were dropped — 이번(this time) must NOT become 2번.
        XCTAssertEqual(f("이번"), "이번")
        XCTAssertEqual(f("한 번 더"), "한 번 더")   // 번 is not an anchor
    }

    func testGuard2_bareYiStaysDeterminer() {
        // "이" is both 2 and the determiner "this"; a lone 이 never converts.
        XCTAssertEqual(f("이 시기에"), "이 시기에")
        XCTAssertEqual(f("이 년에"), "이 년에")
        // …but a lone Sino digit that is NOT 이 does convert before a HARD counter.
        XCTAssertEqual(f("사고"), "사고")          // 사 not before a counter
        XCTAssertEqual(f("제일"), "제일")          // preceded by 제 (Hangul) → guard 3
    }

    func testGuard3_digitBeforeSpanBlocksMerge() {
        // an existing digit before a Sino-big word must not merge: 1만 년.
        XCTAssertEqual(f("1만 년"), "1만 년")
        XCTAssertEqual(f("softCounter 없이"), "softCounter 없이")
    }

    func testGuard3_hangulBeforeSpanBlocks() {
        // 관형사형 ~한: 소중한 일 must stay, not become 소중1일.
        XCTAssertEqual(f("소중한 일을"), "소중한 일을")
        XCTAssertEqual(f("방대한 시설"), "방대한 시설")
        XCTAssertEqual(f("낭자한 시대"), "낭자한 시대")
        // 열/세 inside compound words.
        XCTAssertEqual(f("계열 세포"), "계열 세포")
        XCTAssertEqual(f("일요일"), "일요일")
    }

    // MARK: neutrality

    func testNonKoreanIsNoOp() {
        XCTAssertEqual(f("Hello world 2024"), "Hello world 2024")
        XCTAssertEqual(f("2020年 8月"), "2020年 8月")           // Japanese kanji counters
        XCTAssertEqual(f("会议在三点"), "会议在三点")            // Chinese, no Hangul counter
        XCTAssertEqual(f(""), "")
        XCTAssertEqual(f("숫자 없는 평범한 문장입니다"), "숫자 없는 평범한 문장입니다")
    }

    func testDigitsUntouchedAndMultiplePerLine() {
        XCTAssertEqual(f("1940년"), "1940년")
        XCTAssertEqual(f("천구백사십년 팔월 십오일에"), "1940년 8월 15일에")
    }

    func testParsers() {
        XCTAssertEqual(KoreanNumberFormatter.parseSino("천구백사십"), 1940)
        XCTAssertEqual(KoreanNumberFormatter.parseSino("이만삼천"), 23000)
        XCTAssertNil(KoreanNumberFormatter.parseSino("천사람"))   // 사람 not sino
        // native map holds the pre-counter forms (세, not standalone 셋).
        let (v, n) = KoreanNumberFormatter.parseNative("스물세")
        XCTAssertEqual(v, 23); XCTAssertEqual(n, "스물세".count)
    }
}
