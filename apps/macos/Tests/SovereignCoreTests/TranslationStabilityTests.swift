import XCTest
@testable import SovereignCore

final class ErasureMathTests: XCTestCase {

    func testPrefixGrowthErasesNothing() {
        XCTAssertEqual(ErasureMath.erasure(from: "안녕하", to: "안녕하세요"), 0)
        XCTAssertEqual(ErasureMath.erasure(from: "", to: "hello"), 0)
    }

    func testTailRewriteErasesOnlyTheTail() {
        // "회의를 시작하겠습니다" → "회의를 시작할게요": common prefix "회의를 시작하"
        XCTAssertEqual(ErasureMath.erasure(from: "회의를 시작하겠습니다", to: "회의를 시작할게요"), 5)
        XCTAssertEqual(ErasureMath.erasure(from: "let us begin", to: "let us start"), 5)
    }

    func testFullReplaceErasesEverything() {
        XCTAssertEqual(ErasureMath.erasure(from: "완전히 다른 문장", to: "전혀 무관한 출력"), 9)
    }

    func testShrinkIsErasure() {
        // Loop-collapse/think-strip can shrink a streamed partial.
        XCTAssertEqual(ErasureMath.erasure(from: "abcdef", to: "abc"), 3)
    }

    func testGraphemeClusters() {
        // Composed Hangul + emoji count as single user-visible characters.
        XCTAssertEqual(ErasureMath.commonPrefixCount("가족👨‍👩‍👧", "가족👨‍👩‍👧입니다"), 3)
    }
}

final class InterimTranslateGateTests: XCTestCase {

    func testFirstRequestAlwaysPasses() {
        XCTAssertTrue(InterimTranslateGate.worthTranslating(source: "안", lastRequested: ""))
    }

    func testEmitterFlapAndShrinkAreGated() {
        XCTAssertFalse(InterimTranslateGate.worthTranslating(
            source: "회의를 시작하겠습니다", lastRequested: "회의를 시작하겠습니다"))
        XCTAssertFalse(InterimTranslateGate.worthTranslating(
            source: "회의를 시작", lastRequested: "회의를 시작하겠습니다"))
    }

    func testSmallTailGrowthWaitsAndBigGrowthPasses() {
        XCTAssertFalse(InterimTranslateGate.worthTranslating(
            source: "회의를 시작하겠습니다 오늘", lastRequested: "회의를 시작하겠습니다"))
        XCTAssertTrue(InterimTranslateGate.worthTranslating(
            source: "회의를 시작하겠습니다 오늘의 안건은", lastRequested: "회의를 시작하겠습니다"))
    }

    func testRealRewritePasses() {
        XCTAssertTrue(InterimTranslateGate.worthTranslating(
            source: "회의를 곧 시작할게요", lastRequested: "회의를 시작하겠습니다"))
    }
}

final class StablePrefixFilterTests: XCTestCase {

    func testPureGrowthPassesThrough() {
        var f = StablePrefixFilter()
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We"), "We")
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We will"), "We will")
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We will begin"), "We will begin")
    }

    func testSmallTailRewriteIsAccepted() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "We will begin now")
        // erases "now" (3) ≤ tolerance → accepted immediately
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We will begin today"),
                       "We will begin today")
    }

    func testDeepRewriteFreezesThenAcceptsOnSecondVerdict() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "The meeting will start in a moment")
        // Whole-prefix rewording — held on first sight…
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "In a moment the meeting starts"),
                       "The meeting will start in a moment")
        // …accepted when a second consecutive candidate still contradicts.
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "In a moment the meeting starts, so"),
                       "In a moment the meeting starts, so")
    }

    func testAgreementResetsTheStreak() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "The meeting will start in a moment")
        _ = f.stabilize(lang: "English", candidate: "Shortly the meeting is going to start")  // held (streak 1)
        // A candidate that AGREES with the display again clears the streak…
        XCTAssertEqual(f.stabilize(lang: "English",
                                   candidate: "The meeting will start in a moment, everyone"),
                       "The meeting will start in a moment, everyone")
        // …so a later single contradiction is held again.
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "Something entirely different here"),
                       "The meeting will start in a moment, everyone")
    }

    func testShrinkToPrefixIsHeldOnce() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "Korean", candidate: "회의를 시작하겠습니다. 회의를 시작하겠습니다. 회의를 시작하겠습니다.")
        // Loop-collapse shrinks the text (deep erase): un-drawing waits for a
        // second opinion…
        XCTAssertEqual(f.stabilize(lang: "Korean", candidate: "회의를 시작하겠습니다."),
                       "회의를 시작하겠습니다. 회의를 시작하겠습니다. 회의를 시작하겠습니다.")
        // …and lands when confirmed.
        XCTAssertEqual(f.stabilize(lang: "Korean", candidate: "회의를 시작하겠습니다."),
                       "회의를 시작하겠습니다.")
    }

    func testLanguagesAreIndependentAndResetClears() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "Hello everyone")
        XCTAssertEqual(f.stabilize(lang: "Japanese", candidate: "皆さんこんにちは"), "皆さんこんにちは")
        f.reset()
        // After a window boundary a brand-new sentence replaces freely.
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "Next topic then"), "Next topic then")
    }

    func testRemoveDropsState() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "Original sentence shown here")
        f.remove(lang: "English")
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "Fresh start"), "Fresh start")
    }
}

@MainActor
final class TranslationStabilityMetricsTests: XCTestCase {

    override func setUp() async throws {
        TranslationStabilityMetrics.shared.reset()
    }

    func testCaptionRewriteSequence() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.caption, key: "English", text: "We will")            // first show
        m.recordShown(.caption, key: "English", text: "We will begin")      // growth
        m.recordShown(.caption, key: "English", text: "We are starting")    // rewrite: erases "will begin" (10)
        let c = m.counters[.caption]!
        XCTAssertEqual(c.updates, 3)
        XCTAssertEqual(c.rewrites, 1)
        XCTAssertEqual(c.erasedChars, 10)
    }

    func testIdenticalTextIsNoOp() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.caption, key: "English", text: "same")
        m.recordShown(.caption, key: "English", text: "same")
        XCTAssertEqual(m.counters[.caption]?.updates, 1)
    }

    func testRemovalCountsAsFullErase() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.panel, key: "L1|English", text: "hello there")
        m.recordShown(.panel, key: "L1|English", text: nil)   // invalidate/prune
        let c = m.counters[.panel]!
        XCTAssertEqual(c.erasedChars, 11)
        XCTAssertEqual(c.rewrites, 1)
        // Removing an already-absent key records nothing.
        m.recordShown(.panel, key: "L1|English", text: nil)
        XCTAssertEqual(m.counters[.panel]?.updates, 2)
    }

    func testCloseCaptionForgetsWithoutCounting() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.caption, key: "English", text: "provisional text")
        m.closeCaption()   // committed translation superseded it — not flicker
        XCTAssertEqual(m.counters[.caption]?.erasedChars, 0)
        // Next window's first text is a fresh show, not a rewrite of the old one.
        m.recordShown(.caption, key: "English", text: "next sentence")
        XCTAssertEqual(m.counters[.caption]?.rewrites ?? 0, 0)
    }

    func testFinalPanelCharsIsTheDenominator() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.panel, key: "L1|English", text: "final one")   // 9
        m.recordShown(.panel, key: "L1|Korean", text: "최종")          // 2
        XCTAssertEqual(m.finalPanelChars, 11)
        XCTAssertTrue(m.summary().contains("finalChars=11"))
    }
}
