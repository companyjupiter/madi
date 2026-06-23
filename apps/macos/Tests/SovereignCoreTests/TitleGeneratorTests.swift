// TitleGeneratorTests — sanitizing a raw LLM title into a safe short meeting
// name (strip quotes/markdown/illegal chars, cap length, nil on garbage) and the
// timestamped fallback format.
import XCTest
@testable import SovereignCore

final class TitleGeneratorTests: XCTestCase {

    // MARK: sanitize — clean pass-through

    func testPlainTitleUntouched() {
        XCTAssertEqual(TitleGenerator.sanitize("1분기 매출 회의"), "1분기 매출 회의")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(TitleGenerator.sanitize("   주간 스탠드업   "), "주간 스탠드업")
    }

    // MARK: sanitize — quotes / markdown

    func testStripsSurroundingDoubleQuotes() {
        XCTAssertEqual(TitleGenerator.sanitize("\"예산 검토\""), "예산 검토")
    }

    func testStripsCurlyQuotes() {
        XCTAssertEqual(TitleGenerator.sanitize("“킥오프 미팅”"), "킥오프 미팅")
    }

    func testStripsMarkdownEmphasis() {
        XCTAssertEqual(TitleGenerator.sanitize("**중요 회의**"), "중요 회의")
        XCTAssertEqual(TitleGenerator.sanitize("# 디자인 리뷰"), "디자인 리뷰")
        XCTAssertEqual(TitleGenerator.sanitize("`코드 리뷰`"), "코드 리뷰")
    }

    // MARK: sanitize — labels & trailing punctuation

    func testStripsLeadingLabel() {
        XCTAssertEqual(TitleGenerator.sanitize("제목: 분기 계획"), "분기 계획")
        XCTAssertEqual(TitleGenerator.sanitize("Title: Sprint Plan"), "Sprint Plan")
    }

    func testStripsTrailingPunctuation() {
        XCTAssertEqual(TitleGenerator.sanitize("회의 결과."), "회의 결과")
        XCTAssertEqual(TitleGenerator.sanitize("다음 단계는?"), "다음 단계는")
    }

    // MARK: sanitize — filesystem-illegal characters

    func testRemovesPathSeparators() {
        // '/' and ':' must never appear (path component safety)
        let out = TitleGenerator.sanitize("2026/06 예산: 검토")
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.contains("/"))
        XCTAssertFalse(out!.contains(":"))
    }

    func testRemovesOtherIllegalChars() {
        let out = TitleGenerator.sanitize("리뷰 <초안> | v2 ?")
        XCTAssertNotNil(out)
        for c in ["<", ">", "|", "?", "*", "\\", "\""] {
            XCTAssertFalse(out!.contains(c), "should not contain \(c)")
        }
    }

    // MARK: sanitize — multi-line input

    func testTakesFirstNonEmptyLine() {
        XCTAssertEqual(TitleGenerator.sanitize("\n\n주간 회의\n부연 설명 줄"), "주간 회의")
    }

    // MARK: sanitize — length cap

    func testCapsLength() {
        let long = String(repeating: "가", count: 60)
        let out = TitleGenerator.sanitize(long)
        XCTAssertNotNil(out)
        XCTAssertLessThanOrEqual(out!.count, TitleGenerator.maxLength)
    }

    func testCapDoesNotEndOnSpace() {
        // a space landing exactly at the cut boundary should be trimmed away
        let raw = String(repeating: "a", count: TitleGenerator.maxLength) + " tail"
        let out = TitleGenerator.sanitize(raw)
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.count, TitleGenerator.maxLength)
        XCTAssertFalse(out!.hasSuffix(" "))
    }

    // MARK: sanitize — garbage → nil

    func testNilOnEmpty() {
        XCTAssertNil(TitleGenerator.sanitize(""))
        XCTAssertNil(TitleGenerator.sanitize("    "))
        XCTAssertNil(TitleGenerator.sanitize("\n\n"))
    }

    func testNilOnPurePunctuation() {
        XCTAssertNil(TitleGenerator.sanitize("\"\""))
        XCTAssertNil(TitleGenerator.sanitize("***"))
        XCTAssertNil(TitleGenerator.sanitize("... !!!"))
        XCTAssertNil(TitleGenerator.sanitize("/:/"))
    }

    // MARK: fallbackTitle

    func testFallbackTitleFormat() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 23
        comps.hour = 14; comps.minute = 5
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(TitleGenerator.fallbackTitle(date: date), "회의 2026-06-23 1405")
    }

    func testFallbackTitlePrefix() {
        XCTAssertTrue(TitleGenerator.fallbackTitle(date: Date()).hasPrefix("회의 "))
    }

    // MARK: promptText

    func testPromptTextIncludesTranscript() {
        let p = TitleGenerator.promptText("안녕하세요 회의 시작합니다")
        XCTAssertTrue(p.contains("안녕하세요 회의 시작합니다"))
        XCTAssertTrue(p.contains("제목"))
    }
}
