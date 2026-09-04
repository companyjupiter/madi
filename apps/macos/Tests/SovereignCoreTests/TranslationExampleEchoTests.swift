import XCTest
@testable import SovereignCore

/// Live 0.3.5 (2026-09-03, EN→中·한): the 4B replayed the T5 example target.
final class TranslationExampleEchoTests: XCTestCase {
    private func strip(_ t: String, ex: String?, src: String) -> String {
        TranslationOutputPolicy.stripExampleEcho(t, exampleTarget: ex, source: src)
    }

    func testLeadingEchoIsStripped() {
        // 31:23 — "Yeah. => 是的。" replayed ahead of the real translation.
        XCTAssertEqual(strip("是的。因为你被放到了29号位，对吧?", ex: "是的。", src: "Cause you're up put aside to 29, right?"),
                       "因为你被放到了29号位，对吧?")
        // 20:24 — a whole earlier Korean paragraph ahead of the sentence.
        let para = "말하면 말하면, 나는 그 중 아주 큰 부분이지. 그리고 추론과 데이터센터 구축으로 돌아가면서, 어떤 일이 일어날지 궁금해하는 가운데."
        XCTAssertEqual(strip(para + " 알지, 아침 3시에 화장실 갈 때 이 약을 복용해.", ex: para,
                             src: "You know, when you get up to pee at three in the morning, take this medication."),
                       "알지, 아침 3시에 화장실 갈 때 이 약을 복용해.")
        // Punctuation/spacing differences in the replay do not defeat the match.
        XCTAssertEqual(strip("是的 因为你被放到了29号位", ex: "是的。", src: "Cause you're up, right?"), "因为你被放到了29号位")
    }

    func testWholeOutputEchoDroppedOnlyWhenImplausible() {
        // 36:14 — "only." came back as the previous line's long translation verbatim.
        let prev = "哇。太疯狂了。好吧，听着，这就是你和马克·库班45分钟的对话，独一无二。"
        XCTAssertEqual(strip(prev, ex: prev, src: "only."), "")
        // A legitimate repeat stays: "Yes." after "Yeah. => 是的。".
        XCTAssertEqual(strip("是的。", ex: "是的。", src: "Yes."), "是的。")
    }

    func testNoEchoUnchanged() {
        XCTAssertEqual(strip("你好", ex: "是的。", src: "Hi"), "你好")
        XCTAssertEqual(strip("是的，我们走吧。", ex: nil, src: "Yes, let's go."), "是的，我们走吧。")
        // Output shorter than the example (a genuine short translation that happens
        // to start like the example) is not an echo.
        XCTAssertEqual(strip("是的", ex: "是的。因为", src: "Yes."), "是的")
    }

    func testTargetLanguageLabelEchoIsStripped() {
        // 21:28 live — "a" → "目标中文：" (label only) and label + reply variants.
        XCTAssertEqual(TranslationOutputPolicy.clean("目标中文：一个"), "一个")
        XCTAssertEqual(TranslationOutputPolicy.clean("번역: 하나"), "하나")
        XCTAssertEqual(TranslationOutputPolicy.clean("Korean: 하나"), "하나")
        XCTAssertEqual(TranslationOutputPolicy.clean("目标中文："), "")
        // A real sentence that merely starts with a language name keeps its text.
        XCTAssertEqual(TranslationOutputPolicy.clean("Korean food is great."), "Korean food is great.")
    }

    func testStreamingHoldWhileStillPrefixOfExample() {
        XCTAssertTrue(TranslationOutputPolicy.mayBeExampleEcho("是", exampleTarget: "是的。因为"))
        XCTAssertTrue(TranslationOutputPolicy.mayBeExampleEcho("是的。因", exampleTarget: "是的。因为"))
        XCTAssertFalse(TranslationOutputPolicy.mayBeExampleEcho("是的。因为你", exampleTarget: "是的。因为"))
        XCTAssertFalse(TranslationOutputPolicy.mayBeExampleEcho("你好", exampleTarget: "是的。因为"))
        XCTAssertFalse(TranslationOutputPolicy.mayBeExampleEcho("是的", exampleTarget: nil))
    }
}

/// P5 (live 0.3.7): the prompt arrow leaked into the MIDDLE of translations.
extension TranslationExampleEchoTests {
    func testInlineArrowIsStripped() {
        XCTAssertEqual(TranslationOutputPolicy.clean("우리가 세계와 함께 그리고 우리가 어떻게 ->"),
                       "우리가 세계와 함께 그리고 우리가 어떻게")
        XCTAssertEqual(TranslationOutputPolicy.clean("앞부분 => 뒷부분"), "앞부분 뒷부분")
        XCTAssertEqual(TranslationOutputPolicy.clean("A → B 입니다"), "A B 입니다")
    }

    func testArrowInsideAWordSurvives() {
        XCTAssertEqual(TranslationOutputPolicy.clean("a->b 형태로 씁니다"), "a->b 형태로 씁니다")
        XCTAssertEqual(TranslationOutputPolicy.clean("화살표가 없는 문장"), "화살표가 없는 문장")
    }
}
