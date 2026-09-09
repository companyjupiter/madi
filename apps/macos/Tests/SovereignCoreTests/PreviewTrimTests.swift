import XCTest
@testable import SovereignCore

/// PreviewTrim (2026-09-10): the gray preview never repeats shown words.
final class PreviewTrimTests: XCTestCase {

    private func w(_ t0: Double, _ t1: Double, _ s: String) -> PreviewTrim.TimedWord { .init(t0: t0, t1: t1, text: s) }

    /// The forced prefix ("별이 파편이 사방", what the transcript shows inside the
    /// window) is echoed verbatim by the engine with fake 20 ms timestamps; only
    /// the words after it are shown, whatever their times.
    func testEchoedForcedPrefixIsStrippedByText() {
        let words = [w(0.0, 0.02, "별이"), w(0.02, 0.04, "파편이"), w(0.04, 0.06, "사방"), w(0.66, 1.2, "날아간다"), w(1.3, 1.6, "이렇게")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, forced: "별이 파편이 사방"), "날아간다 이렇게")
    }

    /// An echo that is not verbatim (spacing, a particle) still drops the same
    /// number of words.
    func testNonVerbatimEchoDropsByCount() {
        let words = [w(0, 0.1, "별"), w(0.1, 0.2, "파편이"), w(0.2, 0.3, "사방으로"), w(0.7, 1.2, "날아간다")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, forced: "별이 파편이 사방"), "날아간다")
    }

    func testNoForcedPrefixShowsEverything() {
        let words = [w(0.0, 0.5, "요즘은"), w(0.5, 1.0, "자기"), w(1.0, 1.5, "스스로")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, forced: ""), "요즘은 자기 스스로")
    }

    func testPrefixCoveringEverythingShowsNothing() {
        let words = [w(0, 0.02, "a"), w(0.02, 0.04, "b")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, forced: "a b"), "")
    }

    func testPunctuationJoinsWithoutASpace() {
        let words = [w(0, 0.4, "Hello"), w(0.4, 0.5, ","), w(0.6, 1.0, "world")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, forced: ""), "Hello, world")
    }

    func testForcedPrefixPrefersTheShownWordsAndKeepsALongerAgreedGate() {
        XCTAssertEqual(PreviewTrim.forcedPrefix(committed: ["별", "파편이"], gate: ""), "별 파편이")
        XCTAssertEqual(PreviewTrim.forcedPrefix(committed: ["별", "파편이"], gate: "별 파편이 사방으로 날아간다"), "별 파편이 사방으로 날아간다")
        XCTAssertEqual(PreviewTrim.forcedPrefix(committed: ["별", "파편이"], gate: "얼굴 중입니다"), "별 파편이", "a gate that disagrees with the transcript loses")
        XCTAssertEqual(PreviewTrim.forcedPrefix(committed: [], gate: "흥미로운 과학"), "흥미로운 과학")
    }

    func testTrimByCount() {
        XCTAssertEqual(PreviewTrim.trimByCount("a b c d", dropping: 2), "c d")
        XCTAssertEqual(PreviewTrim.trimByCount("a b", dropping: 2), "")
        XCTAssertEqual(PreviewTrim.trimByCount("a b", dropping: 0), "a b")
    }
}
