// LiveCoachTests — pure live-coach compute: agenda coverage, question persistence,
// and pace cue over immutable snapshots. GUI-free (SovereignCore).
import XCTest
@testable import SovereignCore

final class LiveCoachTests: XCTestCase {

    private func prepItem(_ text: String, speaker: String = "김부장", meeting: String = "기획회의", order: Int = 0) -> PrepItem {
        PrepItem(speaker: speaker, text: text, meeting: meeting, meetingOrder: order)
    }

    private func line(_ start: Double, _ end: Double, speaker: Int = 0, overlap: [Int] = []) -> Line {
        Line(id: UUID(), speaker: speaker, start: start, end: end,
             words: [Word(t0: start, t1: end, text: "x", conf: 1)], overlapSpeakers: overlap)
    }

    // MARK: - threshold

    func testCoverageThreshold() {
        XCTAssertEqual(LiveCoach.coverageThreshold(keywordCount: 0), 0)
        XCTAssertEqual(LiveCoach.coverageThreshold(keywordCount: 1), 1)
        XCTAssertEqual(LiveCoach.coverageThreshold(keywordCount: 2), 2)   // short: all
        XCTAssertEqual(LiveCoach.coverageThreshold(keywordCount: 3), 2)   // majority
        XCTAssertEqual(LiveCoach.coverageThreshold(keywordCount: 4), 3)
        XCTAssertEqual(LiveCoach.coverageThreshold(keywordCount: 6), 4)
    }

    // MARK: - agenda derivation

    func testAgendaFromBriefKeywordsAndOrder() {
        let brief = PrepBriefData(
            meetingTitle: "스프린트 점검",
            attendees: [],
            decisions: [prepItem("예산 배정을 확정했습니다", order: 0)],
            openItems: [prepItem("부하 테스트 일정 검토 필요", order: 1)],
            relatedTalks: [])
        let agenda = LiveCoach.agenda(from: brief)
        XCTAssertEqual(agenda.count, 2)
        XCTAssertEqual(agenda[0].origin, .decision, "decisions come first")
        XCTAssertEqual(agenda[1].origin, .openItem)
        XCTAssertFalse(agenda[0].keywords.isEmpty, "decision keyworded")
        XCTAssertFalse(agenda[1].keywords.isEmpty, "open item keyworded")
    }

    func testAgendaDropsKeywordlessItems() {
        // A line that yields no usable keyword (all stopwords / too short) is dropped.
        let brief = PrepBriefData(meetingTitle: "t", attendees: [],
                                  decisions: [prepItem("것 건")], openItems: [], relatedTalks: [])
        XCTAssertTrue(LiveCoach.agenda(from: brief).isEmpty)
    }

    // MARK: - coverage classification

    func testClassifyCoveredVsRemaining() {
        let brief = PrepBriefData(
            meetingTitle: "t", attendees: [],
            decisions: [prepItem("예산 배정 확정", order: 0)],
            openItems: [prepItem("부하 테스트 일정 검토 필요", order: 1)],
            relatedTalks: [])
        let agenda = LiveCoach.agenda(from: brief)
        // The room discusses the budget but never the load test.
        let spoken = ["오늘 예산 배정 다시 확정하죠", "그 부분은 동의합니다"]
        let r = LiveCoach.classify(agenda: agenda, spokenLines: spoken)
        XCTAssertEqual(r.covered.count, 1)
        XCTAssertEqual(r.covered.first?.origin, .decision)
        XCTAssertEqual(r.remaining.count, 1)
        XCTAssertEqual(r.remaining.first?.origin, .openItem)
    }

    func testClassifyEmptyTranscriptAllRemaining() {
        let brief = PrepBriefData(meetingTitle: "t", attendees: [],
                                  decisions: [prepItem("예산 배정 확정")], openItems: [], relatedTalks: [])
        let agenda = LiveCoach.agenda(from: brief)
        let r = LiveCoach.classify(agenda: agenda, spokenLines: [])
        XCTAssertTrue(r.covered.isEmpty)
        XCTAssertEqual(r.remaining.count, 1)
    }

    func testCoverageIsIncrementalMonotone() {
        // Once covered with a short transcript, adding more lines never un-covers it.
        let brief = PrepBriefData(meetingTitle: "t", attendees: [],
                                  decisions: [prepItem("예산 배정 확정")], openItems: [], relatedTalks: [])
        let agenda = LiveCoach.agenda(from: brief)
        let early = LiveCoach.classify(agenda: agenda, spokenLines: ["예산 배정 확정 합시다"])
        XCTAssertEqual(early.covered.count, 1)
        let later = LiveCoach.classify(agenda: agenda,
                                       spokenLines: ["예산 배정 확정 합시다", "다른 얘기로 넘어가죠"])
        XCTAssertEqual(later.covered.count, 1, "covered item stays covered as transcript grows")
    }

    // MARK: - question persistence

    func testQuestionsAnsweredAndUnanswered() {
        let qs = LiveCoach.questions(
            railQuestions: ["배포 일정 확정 가능한가요", "예산 추가 배정 가능한가요"],
            // The room comes back to the budget question (예산 추가 배정) but never the
            // deploy schedule — so the 2nd is answered, the 1st stays open.
            spokenLines: ["예산 추가 배정은 가능하다고 봅니다"])
        XCTAssertEqual(qs.count, 2)
        let byText = Dictionary(uniqueKeysWithValues: qs.map { ($0.text, $0.answered) })
        XCTAssertEqual(byText["배포 일정 확정 가능한가요"], false, "deploy schedule still open")
        XCTAssertEqual(byText["예산 추가 배정 가능한가요"], true, "budget question answered")
    }

    func testQuestionsDedupeAndOrder() {
        let qs = LiveCoach.questions(railQuestions: ["A 질문은 무엇", "A 질문은 무엇", "B 질문은 무엇"],
                                     spokenLines: [])
        XCTAssertEqual(qs.count, 2, "deduped by text")
        XCTAssertEqual(qs.map(\.text), ["A 질문은 무엇", "B 질문은 무엇"], "raise order preserved")
        XCTAssertTrue(qs.allSatisfy { !$0.answered }, "empty transcript → all unanswered")
    }

    // MARK: - pace

    func testPaceTooFewBucketsUnknown() {
        XCTAssertEqual(LiveCoach.pace(energy: []), .unknown)
        XCTAssertEqual(LiveCoach.pace(energy: [0.5, 0.5]), .unknown)
    }

    func testPaceLowWhenRecentlyQuiet() {
        let e = [0.9, 0.9, 0.9, 0.05, 0.05, 0.05]   // dropped off recently
        XCTAssertEqual(LiveCoach.pace(energy: e, window: 3), .low)
    }

    func testPaceHeatingWhenRecentlyRising() {
        let e = [0.2, 0.2, 0.2, 0.9, 0.95, 1.0]
        XCTAssertEqual(LiveCoach.pace(energy: e, window: 3), .heating)
    }

    func testPaceSteadyWhenFlat() {
        let e = [0.5, 0.55, 0.5, 0.52, 0.5, 0.53]
        XCTAssertEqual(LiveCoach.pace(energy: e, window: 3), .steady)
    }

    // MARK: - full compute

    func testComputeWiresAllSignals() {
        let brief = PrepBriefData(
            meetingTitle: "t", attendees: [],
            decisions: [prepItem("예산 배정 확정", order: 0)],
            openItems: [prepItem("부하 테스트 일정 검토 필요", order: 1)],
            relatedTalks: [])
        let agenda = LiveCoach.agenda(from: brief)
        let lines = (0..<8).map { line(Double($0), Double($0) + 0.7) }
        let state = LiveCoach.compute(
            agenda: agenda,
            spokenLines: ["예산 배정 확정 합시다"],
            railQuestions: ["배포 일정은 언제"],
            lines: lines,
            energyBuckets: 10)
        XCTAssertEqual(state.coveredCount, 1)
        XCTAssertEqual(state.totalCount, 2)
        XCTAssertEqual(state.unansweredCount, 1)
        XCTAssertEqual(state.energy.count, 10)
        XCTAssertFalse(state.isEmpty)
    }

    func testComputeEmptyWhenNoAgendaNoQuestions() {
        let state = LiveCoach.compute(agenda: [], spokenLines: ["아무 말"],
                                      railQuestions: [], lines: [], energyBuckets: 10)
        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(state.pace, .unknown, "no energy → unknown pace")
    }
}
