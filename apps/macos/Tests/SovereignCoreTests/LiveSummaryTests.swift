// LiveSummaryTests — the live key-point notes core (docs/LIVE_SUMMARY.md): the note prompt,
// the deterministic language guard, the oldest-first window, the reply parse, de-duplication,
// display sections, and the no-degradation invariants. Scheduling mirrors the live rail's
// (SessionController); what is testable headless lives here.
import XCTest
@testable import SovereignCore

final class LiveSummaryTests: XCTestCase {

    private func line(_ speaker: String, _ text: String, _ start: Double = 0) -> LiveSummary.WindowLine {
        .init(id: UUID(), start: start, end: start + 2, speaker: speaker, text: text)
    }

    // ── prompt contract (replayed on the shipped 4B) ─────────────────────────

    func testNotePromptAsksForOneConcreteNoteAndCarriesTheWindow() {
        let p = LiveSummary.notePrompt(window: "김부장: 외주 견적은 3억입니다", language: .ko, template: .meeting)
        XCTAssertTrue(p.hasSuffix("새 발언: 김부장: 외주 견적은 3억입니다"))
        XCTAssertTrue(p.contains("가장 중요한 구체적인 내용 하나만"))
        XCTAssertTrue(p.contains("'없음'이라고만"))
        XCTAssertFalse(p.contains("기존 요약"), "no carry: a request never sees an earlier summary")
    }

    /// Decisions only when stated — "(결정, 할 일…)" as a category list made 12 of one
    /// meeting's notes claim decisions nobody made.
    func testPromptForbidsInventedDecisions() {
        let p = LiveSummary.notePrompt(window: "w", language: .ko, template: .meeting)
        XCTAssertTrue(p.contains("'결정'이나 '합의'는 발언에서 분명히 정했다고 말한 경우에만"))
    }

    /// The language is named outright, from the transcript — "발언과 같은 언어로" let a Korean
    /// meeting with English fragments come back in English.
    func testLanguageIsNamedOutright() {
        XCTAssertTrue(LiveSummary.notePrompt(window: "w", language: .ko, template: .meeting).contains("반드시 한국어로만"))
        XCTAssertTrue(LiveSummary.notePrompt(window: "w", language: .en, template: .meeting).contains("반드시 영어로만"))
        XCTAssertFalse(LiveSummary.notePrompt(window: "w", language: .ko, template: .meeting).contains("발언과 같은 언어로"))
    }

    func testTemplateHintIsAutoDerivedNudgeOnly() {
        XCTAssertEqual(LiveSummary.hint(.meeting), "")
        XCTAssertTrue(LiveSummary.notePrompt(window: "w", language: .ko, template: .lecture).contains("핵심 개념"))
        XCTAssertTrue(LiveSummary.notePrompt(window: "w", language: .ko, template: .interview).contains("질문과 답변"))
    }

    // ── language guard ───────────────────────────────────────────────────────

    func testDominantLanguageFollowsTheTranscriptNotItsFragments() {
        XCTAssertEqual(LiveSummary.dominantLanguage(of: "제미나이랑 GPT는 웹서치가 됩니다. Q. So, you can see the search tool. 그래서 클라이언트 단에서"), .ko)
        XCTAssertEqual(LiveSummary.dominantLanguage(of: "Seven co-founders are all still at the company."), .en)
        XCTAssertEqual(LiveSummary.dominantLanguage(of: "これは会議の議事録です"), .ja)
        XCTAssertEqual(LiveSummary.dominantLanguage(of: "这是会议记录"), .zh)
    }

    func testOutputScriptGate() {
        XCTAssertTrue(LiveSummary.scriptMatches("GPT·Gemini 웹서치 지원 모델 2개", .ko), "Latin product names are fine in Korean")
        XCTAssertFalse(LiveSummary.scriptMatches("Global AI tool usage requires infrastructure.", .ko))
        XCTAssertFalse(LiveSummary.scriptMatches("国宝로 때 찾아줘", .ko), "stray hanzi rejected")
        XCTAssertTrue(LiveSummary.scriptMatches("Anthropic was founded in 2021.", .en))
        XCTAssertFalse(LiveSummary.scriptMatches("Anthropic 설립", .en))
        XCTAssertFalse(LiveSummary.scriptMatches("2021.", .ko), "no letters, no note")
    }

    // ── window ───────────────────────────────────────────────────────────────

    /// Oldest first, capped; what doesn't fit waits for the next request (the carry kept
    /// the newest 700 chars and silently dropped the rest).
    func testWindowTakesOldestFirstAndLeavesTheRest() {
        let lines = (0..<5).map { line("화자1", String(repeating: "가", count: 300), Double($0)) }
        let (text, used) = LiveSummary.takeWindow(lines, cap: 1000)
        XCTAssertEqual(used, 3)                                   // 3×(300+5) + 2×3 ≤ 1000 < 4 lines
        XCTAssertTrue(text.hasPrefix("화자1: 가"))
        XCTAssertLessThanOrEqual(text.count, 1000)
    }

    func testOversizedSingleLineIsTruncatedNotStuck() {
        let (text, used) = LiveSummary.takeWindow([line("A", String(repeating: "나", count: 5000))], cap: 1000)
        XCTAssertEqual(used, 1)
        XCTAssertEqual(text.count, 1000)
    }

    /// Every speaker is labeled so the model can tell them apart — labeling only named ones
    /// moved other people's words onto the named speaker.
    func testWindowLabelsEverySpeaker() {
        let (text, _) = LiveSummary.takeWindow([line("전웅재", "질문입니다"), line("화자3", "답입니다")])
        XCTAssertEqual(text, "전웅재: 질문입니다 / 화자3: 답입니다")
    }

    // ── reply parse ──────────────────────────────────────────────────────────

    func testParseKeepsOneNote() {
        XCTAssertEqual(LiveSummary.parseNote("- 10만 건 검색에 700달러 비용 논의\n- 두 번째"), "10만 건 검색에 700달러 비용 논의")
    }

    func testParseRemovesAnonymousSpeakersButKeepsNames() {
        XCTAssertEqual(LiveSummary.parseNote("- 화자3은 게이트웨이 방식을 제안했습니다."), "게이트웨이 방식을 제안했습니다.")
        XCTAssertEqual(LiveSummary.parseNote("- Speaker 9: 세션 간 연동은 불가"), "세션 간 연동은 불가")
        XCTAssertEqual(LiveSummary.parseNote("- 전웅재는 10만건 검색에 700불이라고 말했습니다."),
                       "전웅재는 10만건 검색에 700불이라고 말했습니다.")
    }

    func testParseDropsPromptEcho() {
        XCTAssertEqual(LiveSummary.parseNote("- 발언에서 가장 중요한 구체적인 내용은 강제 툴콜링 도입입니다."),
                       "강제 툴콜링 도입입니다.")
    }

    func testParseRejectsNoneFragmentsAndRunOns() {
        XCTAssertNil(LiveSummary.parseNote("없음"))
        XCTAssertNil(LiveSummary.parseNote("- 없음."))
        XCTAssertNil(LiveSummary.parseNote("- None"))
        XCTAssertNil(LiveSummary.parseNote("- 5개"))
        XCTAssertNil(LiveSummary.parseNote("- " + String(repeating: "가", count: LiveSummary.maxNoteChars + 1)))
        XCTAssertNil(LiveSummary.parseNote(""))
    }

    // ── de-duplication ───────────────────────────────────────────────────────

    func testNearDuplicateCatchesEchoAndSplit() {
        XCTAssertTrue(LiveSummary.isNearDuplicate("세션 간 연동 불가 시 특별 명칭 부여로 연동하는 방안 논의",
                                                  "세션 간 연동 불가 시 특별 명칭 부여로 연동하는 방안 논의 (추가 언급)"))
        XCTAssertFalse(LiveSummary.isNearDuplicate("10만 건 검색에 700달러", "루트 계정은 LIG가 보유"))
    }

    func testAcceptsOnlyNewNotesInTheSessionLanguage() {
        let existing = [LiveSummary.Note(text: "10만 건 검색 비용은 700달러로 논의됨", start: 0, end: 30, lineIDs: [])]
        XCTAssertFalse(LiveSummary.accepts("10만 건 검색 비용은 700달러로 논의됨.", language: .ko, existing: existing))
        XCTAssertFalse(LiveSummary.accepts("The cost is 700 dollars per 100k searches.", language: .ko, existing: existing))
        XCTAssertTrue(LiveSummary.accepts("LIG가 루트 계정을 보유하고 권한을 위임하는 방안 논의", language: .ko, existing: existing))
    }

    // ── display sections ─────────────────────────────────────────────────────

    func testSectionsGroupByFiveMinutesInOrder() {
        let n = { (t: Double) in LiveSummary.Note(text: "n\(t)", start: t, end: t + 30, lineIDs: []) }
        let s = LiveSummary.sections([n(610), n(10), n(299), n(300)])
        XCTAssertEqual(s.map(\.index), [0, 1, 2])
        XCTAssertEqual(s[0].notes.map(\.start), [10, 299])
        XCTAssertEqual(s[2].startSeconds, 600)
    }

    func testBulletsParseAndStripMarks() {
        XCTAssertEqual(LiveSummary.bullets("- 일정 확정\n• 예산 검토\n\n· 외주"), ["일정 확정", "예산 검토", "외주"])
        XCTAssertEqual(LiveSummary.bullets("대시 없는 줄"), ["대시 없는 줄"])
        XCTAssertEqual(LiveSummary.bullets(""), [])
    }

    // ── no-degradation envelope ──────────────────────────────────────────────

    /// The window cap bounds prefill — the only way a note request can delay a caption turn
    /// is while it runs.
    func testInputIsBoundedByTheWindowCap() {
        let huge = (0..<50).map { line("화자1", String(repeating: "다", count: 400), Double($0)) }
        let (text, _) = LiveSummary.takeWindow(huge)
        let p = LiveSummary.notePrompt(window: text, language: .ko, template: .meeting)
        XCTAssertLessThan(p.count, LiveSummary.windowCap + 400)
        XCTAssertGreaterThan(LiveSummary.maxBacklogChars, LiveSummary.windowCap)
    }

    /// The cadence stays LAZIER than the rail's — it shares the engine with captions and is
    /// the least urgent consumer.
    func testCadenceIsLazierThanTheRail() {
        XCTAssertGreaterThanOrEqual(LiveSummary.tickSeconds, 30)
        XCTAssertGreaterThanOrEqual(LiveSummary.minNewLines, 6)
    }

    /// Broker lane ordering: a queued caption always beats a queued note (which rides
    /// .postSession), and caption pressure makes the note ineligible until the aging valve.
    func testBrokerLaneKeepsCaptionsFirst() {
        XCTAssertLessThan(DNAEngineBroker.Priority.postSession.rawValue,
                          DNAEngineBroker.Priority.liveRail.rawValue)
        let queued: [(priority: Int, sequence: UInt64, waitedSeconds: Double)] = [
            (DNAEngineBroker.Priority.postSession.rawValue, 1, 5),
            (DNAEngineBroker.Priority.committedCaption.rawValue, 2, 0),
        ]
        XCTAssertEqual(DNAEngineBroker.eligibleIndex(queued, captionPressure: 0), 1)
        let alone: [(priority: Int, sequence: UInt64, waitedSeconds: Double)] = [
            (DNAEngineBroker.Priority.postSession.rawValue, 1, 5),
        ]
        XCTAssertNil(DNAEngineBroker.eligibleIndex(alone, captionPressure: 3))
    }
}
