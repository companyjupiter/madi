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
