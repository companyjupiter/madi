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

/// Live application safety (2026-08-27): formatting now runs the moment a line
/// stops being the live tail, not only at finalize. The counter anchor is what
/// makes that safe — a partial number carries no counter yet, so it cannot be
/// converted and then rewritten when the rest of the word arrives.
final class KoreanNumberLiveSafetyTests: XCTestCase {

    private func f(_ s: String) -> String { KoreanNumberFormatter.format(s) }

    func testPartialNumberWithoutItsCounterNeverConverts() {
        // These are prefixes a growing line passes through on the way to
        // "이천이십년" / "십오일" / "삼십오분". None may convert early.
        for partial in ["이천이십", "이천", "십오", "삼십", "삼십오", "열한", "스물"] {
            XCTAssertEqual(f(partial), partial, "\(partial) has no counter yet")
        }
    }

    func testConversionAppearsOnlyWhenTheCounterArrives() {
        XCTAssertEqual(f("이천이십"), "이천이십")
        XCTAssertEqual(f("이천이십년"), "2020년")   // …and only now
    }

    func testFormattingIsIdempotent() {
        // The stable-line pass re-runs on every word ingest; a second pass over
        // already-formatted text must be a no-op or it would churn the display.
        let once = f("천구백사십년 팔월 십오일에 열한시 삼십오분")
        XCTAssertEqual(f(once), once)
        XCTAssertEqual(once, "1940년 8월 15일에 11시 35분")
    }

    func testGrowthSequenceConvertsExactlyOnce() {
        // Simulate the live tail growing word by word: the rendered text must
        // never convert and then change its mind.
        var seen: [String] = []
        var text = ""
        for word in ["회의는", "이천이십", "오년", "팔월에", "열렸다"] {
            text = text.isEmpty ? word : text + " " + word
            seen.append(f(text))
        }
        XCTAssertEqual(seen.last, "회의는 이천이십 5년 8월에 열렸다")
        // The anti-churn property: once something renders as digits it stays
        // digits — no render may take a digit run away from the one before it.
        func digitRuns(_ s: String) -> [String] {
            s.split(whereSeparator: { !$0.isNumber }).map(String.init)
        }
        for i in 1..<seen.count {
            for run in digitRuns(seen[i - 1]) {
                XCTAssertTrue(digitRuns(seen[i]).contains(run),
                              "digit run \(run) vanished: \(seen[i - 1]) → \(seen[i])")
            }
        }
    }

    /// guard 4: a counter that runs straight into a verb ending is not a counter.
    func testGuard4_politeImperativeIsNotATime() {
        XCTAssertEqual(KoreanNumberFormatter.format("어서 오십시오."), "어서 오십시오.")
        XCTAssertEqual(KoreanNumberFormatter.format("어서 오십시오. 반갑습니다."), "어서 오십시오. 반갑습니다.")
        XCTAssertEqual(KoreanNumberFormatter.format("앉으십시오"), "앉으십시오")
        // real times keep converting: a particle or a space may follow the counter
        XCTAssertEqual(KoreanNumberFormatter.format("오시에 만나요"), "5시에 만나요")
        XCTAssertEqual(KoreanNumberFormatter.format("오십분 뒤"), "50분 뒤")
        XCTAssertEqual(KoreanNumberFormatter.format("다섯시 오분"), "5시 5분")
    }
}
