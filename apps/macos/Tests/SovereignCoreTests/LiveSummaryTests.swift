// LiveSummaryTests — the rolling live-summary prompt/parse core and its
// no-degradation invariants (docs/LIVE_SUMMARY.md). The scheduling itself
// mirrors the live rail's (SessionController); what's testable headless is the
// prompt contract, the input caps that bound in-flight time, and the broker
// lane the requests ride.
import XCTest
@testable import SovereignCore

final class LiveSummaryTests: XCTestCase {

    // ── prompt contract (wording CLI-probed on the 4B — 4/4 pass) ────────────

    func testFirstPromptHasNoCarrySection() {
        let p = LiveSummary.prompt(carry: nil, window: "김부장: 시작합니다", template: .meeting)
        XCTAssertTrue(p.contains("발언: 김부장: 시작합니다"))
        XCTAssertFalse(p.contains("기존 요약"))
        XCTAssertTrue(p.contains("3-5개 불릿"))
        XCTAssertTrue(p.contains("다른 말 없이 불릿만"))
    }

    func testUpdatePromptCarriesPreviousSummaryAndNewLinesOnly() {
        let p = LiveSummary.prompt(carry: "- 일정 확정\n- 예산 검토", window: "이영희: 외주 견적 내일 받습니다",
                                   template: .meeting)
        XCTAssertTrue(p.contains("기존 요약: - 일정 확정 - 예산 검토"))   // newlines flattened
        XCTAssertTrue(p.contains("새 발언: 이영희: 외주 견적 내일 받습니다"))
        XCTAssertTrue(p.contains("3-6개 불릿"))
    }

    func testEmptyCarryFallsBackToFirstPrompt() {
        let p = LiveSummary.prompt(carry: "  \n ", window: "발언", template: .meeting)
        XCTAssertFalse(p.contains("기존 요약"))
    }

    /// The caps are the in-flight-time bound — the ONLY way a live-summary
    /// request can delay a caption turn is while it's generating, and prefill
    /// scales with these.
    func testInputCapsBoundThePrompt() {
        let hugeCarry = String(repeating: "가", count: 5_000)
        let hugeWindow = String(repeating: "나", count: 9_000)
        let p = LiveSummary.prompt(carry: hugeCarry, window: hugeWindow, template: .meeting)
        XCTAssertLessThan(p.count, LiveSummary.carryCap + LiveSummary.windowCap + 300)
        // window keeps its TAIL (newest speech), carry its head
        XCTAssertTrue(p.hasSuffix(String(repeating: "나", count: 10)))
    }

    /// GOLDEN: the A/B-probed language instruction — the soft "전사와 같은
    /// 언어로" leaked 63 hangul chars into an English meeting's summary on the
    /// 4B; this exact wording leaked 0. Both prompt variants must carry it.
    func testProbedLanguageInstructionIsPinned() {
        let pinned = "반드시 발언과 같은 언어로만 답하세요(발언이 영어면 영어로)."
        XCTAssertTrue(LiveSummary.prompt(carry: nil, window: "w", template: .meeting).contains(pinned))
        XCTAssertTrue(LiveSummary.prompt(carry: "c", window: "w", template: .meeting).contains(pinned))
        XCTAssertFalse(LiveSummary.prompt(carry: nil, window: "w", template: .meeting)
            .contains("전사와 같은 언어로"))
    }

    func testTemplateHintIsAutoDerivedNudgeOnly() {
        XCTAssertEqual(LiveSummary.hint(.meeting), "")   // baseline stays clean
        XCTAssertTrue(LiveSummary.hint(.lecture).contains("요점"))
        XCTAssertTrue(LiveSummary.hint(.interview).contains("질문"))
        for t in SummaryTemplate.allCases {
            // a nudge, never a section-format instruction — live output is flat bullets
            XCTAssertFalse(LiveSummary.hint(t).contains("["))
        }
    }

    // ── display parse ─────────────────────────────────────────────────────────

    func testBulletsParseAndStripMarks() {
        let b = LiveSummary.bullets("- 일정 확정\n• 예산 검토\n\n- QA 외주 보강")
        XCTAssertEqual(b, ["일정 확정", "예산 검토", "QA 외주 보강"])
    }

    func testDroppedDashStillShowsTheLine() {
        // A 2B-style dropped dash must not hide content from the pane.
        XCTAssertEqual(LiveSummary.bullets("일정 확정\n- 예산 검토"), ["일정 확정", "예산 검토"])
    }

    func testBulletsOfEmptyReplyIsEmpty() {
        XCTAssertTrue(LiveSummary.bullets("").isEmpty)
        XCTAssertTrue(LiveSummary.bullets("  \n- \n").isEmpty)
    }

    // ── no-degradation invariants ─────────────────────────────────────────────

    /// The live-summary cadence must stay LAZIER than the rail's — it shares the
    /// engine with captions and is the least urgent consumer.
    func testCadenceIsLazierThanTheRail() {
        XCTAssertGreaterThanOrEqual(LiveSummary.tickSeconds, 30)
        XCTAssertGreaterThanOrEqual(LiveSummary.minNewLines, 6)
    }

    /// Broker lane ordering: a queued caption always beats a queued live-summary
    /// (which rides .postSession), and caption pressure makes the summary
    /// ineligible entirely until the aging valve.
    func testBrokerLaneKeepsCaptionsFirst() {
        XCTAssertLessThan(DNAEngineBroker.Priority.postSession.rawValue,
                          DNAEngineBroker.Priority.liveRail.rawValue)
        let queued: [(priority: Int, sequence: UInt64, waitedSeconds: Double)] = [
            (DNAEngineBroker.Priority.postSession.rawValue, 1, 5),      // live-summary first in line
            (DNAEngineBroker.Priority.committedCaption.rawValue, 2, 0), // caption arrives later
        ]
        XCTAssertEqual(DNAEngineBroker.eligibleIndex(queued, captionPressure: 0), 1)
        // under caption pressure the summary is ineligible even alone
        let alone: [(priority: Int, sequence: UInt64, waitedSeconds: Double)] = [
            (DNAEngineBroker.Priority.postSession.rawValue, 1, 5),
        ]
        XCTAssertNil(DNAEngineBroker.eligibleIndex(alone, captionPressure: 3))
    }
}
