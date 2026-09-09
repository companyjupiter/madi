import XCTest
@testable import SovereignCore

/// PreviewTrim (2026-09-10): the gray preview never repeats committed words.
final class PreviewTrimTests: XCTestCase {

    private func w(_ t0: Double, _ t1: Double, _ s: String) -> PreviewTrim.TimedWord { .init(t0: t0, t1: t1, text: s) }

    /// Window opened at 273.5; committed "…별이 파편이" ends at 274.4, held "사방"
    /// spans 274.4–275.0. The preview re-decodes "별 파편이 사방으로 날아간다 이렇게":
    /// the overlap words and the held word's re-decode ("사방으로", starting
    /// inside the held span) vanish, the genuinely new tail stays.
    func testOverlapAndHeldRedecodeAreDropped() {
        let words = [w(0.0, 0.3, "별"), w(0.3, 0.9, "파편이"), w(0.9, 1.6, "사방으로"), w(1.6, 2.2, "날아간다"), w(2.3, 2.6, "이렇게")]
        let shown = PreviewTrim.visibleTail(words: words, windowStart: 273.5, committedEnd: 274.4, heldEnd: 275.0)
        XCTAssertEqual(shown, "날아간다 이렇게")
    }

    /// No held word: only words starting before the watermark go.
    func testWordsStartingAfterTheWatermarkStay() {
        let words = [w(0.0, 0.4, "얼굴"), w(0.4, 0.9, "중입니다"), w(1.0, 1.4, "저희")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, windowStart: 100, committedEnd: 100.9, heldEnd: nil), "저희")
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, windowStart: 100, committedEnd: 100.4, heldEnd: nil), "중입니다 저희")
    }

    func testNothingCommittedShowsEverything() {
        let words = [w(0.0, 0.5, "요즘은"), w(0.5, 1.0, "자기"), w(1.0, 1.5, "스스로")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, windowStart: 0, committedEnd: 0, heldEnd: nil), "요즘은 자기 스스로")
    }

    func testPunctuationJoinsWithoutASpace() {
        let words = [w(0, 0.4, "Hello"), w(0.4, 0.5, ","), w(0.6, 1.0, "world")]
        XCTAssertEqual(PreviewTrim.visibleTail(words: words, windowStart: 0, committedEnd: 0, heldEnd: nil), "Hello, world")
    }

    func testForcedPrefixPrefersTheCommittedWordsAndKeepsALongerAgreedGate() {
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
