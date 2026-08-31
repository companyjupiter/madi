// SummaryReplySanitizerTests — the three 2B pathologies the sanitizer guards,
// each reproduced from the 2026-08-31 CLI probe on the shipped DNA3.0-2B
// (docs/SUMMARY_TEMPLATES.md §7), plus the no-op guarantee for healthy output.
import XCTest
@testable import SovereignCore

final class SummaryReplySanitizerTests: XCTestCase {

    // ── 1. stray </think> + restated answer (probe: 2/9 replies) ─────────────

    func testThinkLeakKeepsTheFinalRestatement() {
        let reply = """
        [요약] 초안 요약입니다.
        [문답]
        - Q: 첫 질문?
        - A: 초안 답변.
        </think>

        [요약] 최종 요약입니다.
        [문답]
        - Q: 첫 질문?
        - A: 최종 답변.
        """
        let s = SummaryReplySanitizer.sanitize(reply)
        XCTAssertTrue(s.contains("최종 요약입니다"))
        XCTAssertFalse(s.contains("초안 요약입니다"))
        XCTAssertFalse(s.contains("</think>"))
    }

    func testThinkLeakWithTruncatedRestatementFallsBackToLongestSegment() {
        // The restatement was cut by the token budget → it lost the head marker;
        // the complete draft (longest segment) must win over a truncated tail.
        let reply = "긴 사고 과정 텍스트가 이어집니다 아주 길게 계속됩니다" + String(repeating: " 채움", count: 30)
            + "</think>\n짧은 꼬리"
        let s = SummaryReplySanitizer.sanitize(reply)
        XCTAssertTrue(s.contains("사고 과정"))
        XCTAssertFalse(s.contains("</think>"))
    }

    func testSpeakersHeadMarkerSelectsSpeakerSegment() {
        let reply = "생각 초안\n</think>\n■ 김부장: 예산 검토. 맡은 일: - 예산안"
        let s = SummaryReplySanitizer.sanitize(reply, headMarker: "■")
        XCTAssertTrue(s.hasPrefix("■ 김부장"))
    }

    // ── 2. alternating repetition loop (probe: [후속] 20×) ───────────────────

    func testAlternatingLoopCollapsesToOnePair() {
        let pair = "- 고객: 그럼 환불이 안 되나요?\n- 상담사: 보험료는 약관상 환불이 어렵습니다.\n"
        let reply = "[요약] 상담 요약.\n[후속]\n" + String(repeating: pair + "\n", count: 20)
        let s = SummaryReplySanitizer.sanitize(reply)
        XCTAssertEqual(s.components(separatedBy: "그럼 환불이").count - 1, 1)
        XCTAssertEqual(s.components(separatedBy: "약관상").count - 1, 1)
        XCTAssertLessThan(s.count, 150)
    }

    func testBlankRunsCollapseToOne() {
        let s = SummaryReplySanitizer.sanitize("[요약] 요약.\n\n\n\n[결정]\n- 결정1")
        XCTAssertFalse(s.contains("\n\n\n"))
        XCTAssertTrue(s.contains("- 결정1"))
    }

    // ── 3. hallucinated section tail (probe: [용어] 65개, 근거 14) ────────────

    func testTermSectionCappedAtRegistryLimit() {
        let terms = (1...12).map { "- 용어\($0): 설명 \($0)" }.joined(separator: "\n")
        let reply = "[요약] 강의 요약.\n[요점]\n- 요점1\n- 요점2\n[용어]\n" + terms
        let s = SummaryReplySanitizer.sanitize(reply)
        XCTAssertTrue(s.contains("- 용어5: 설명 5"))       // first (grounded) terms kept
        XCTAssertFalse(s.contains("- 용어6: 설명 6"))      // hallucination tail cut at cap 5
        XCTAssertTrue(s.contains("- 요점2"))               // other sections untouched
    }

    func testCapResetsPerSection() {
        // 10 QA bullets (cap 10) then 6 후속 bullets (cap 6) — each section gets
        // its own budget; the follow-up section must not inherit QA's count.
        let qa = (1...5).flatMap { ["- Q: 질문 \($0)?", "- A: 답변 \($0)."] }.joined(separator: "\n")
        let fu = (1...8).map { "- 이름\($0): 할 일 \($0)" }.joined(separator: "\n")
        let s = SummaryReplySanitizer.sanitize("[요약] 요약.\n[문답]\n\(qa)\n[후속]\n\(fu)")
        XCTAssertTrue(s.contains("- A: 답변 5."))          // all 10 QA bullets kept
        XCTAssertTrue(s.contains("- 이름6: 할 일 6"))       // 후속 cap 6 kept
        XCTAssertFalse(s.contains("- 이름7: 할 일 7"))      // 7th 후속 dropped
    }

    // ── no-op guarantee for healthy output ────────────────────────────────────

    func testHealthyMeetingReplyPassesThroughUnchanged() {
        let healthy = """
        [요약] 1분기 매출 목표를 초과 달성했고, 다음 스프린트를 시작합니다.
        [액션]
        - 김부장: 금요일까지 예산안 검토
        - 이영희: 캠페인 초안 작성
        [결정]
        - 다음 스프린트 월요일 시작
        """
        XCTAssertEqual(SummaryReplySanitizer.sanitize(healthy), healthy)
    }

    func testHealthySpeakersReplyPassesThroughUnchanged() {
        let healthy = "■ 김부장: 예산 방향을 정리했다. 맡은 일: - 예산안 검토\n■ 이영희: 캠페인을 제안했다."
        XCTAssertEqual(SummaryReplySanitizer.sanitize(healthy, headMarker: "■"), healthy)
    }

    func testNoThinkNoChangeOnPlainProse() {
        let prose = "회의에서는 출시 일정을 논의했고 6월 30일로 확정했습니다."
        XCTAssertEqual(SummaryReplySanitizer.sanitize(prose), prose)
    }
}
