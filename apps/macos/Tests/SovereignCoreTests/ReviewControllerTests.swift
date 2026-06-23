// ReviewControllerTests — 귀로 검토 상태 머신의 헤드리스 검증. 오디오/AVFoundation
// 없이 큐 구성 + 진행(advance/wrap/manualJump/gate) 로직만 결정적으로 확인.
import XCTest
@testable import SovereignCore

@MainActor
final class ReviewControllerTests: XCTestCase {

    /// conf 가 섞인 한 라인.
    private func line(_ words: [(Double, Double, String, Double)]) -> Line {
        let ws = words.map { Word(t0: $0.0, t1: $0.1, text: $0.2, conf: $0.3) }
        return Line(id: UUID(), speaker: 0, start: ws.first?.t0 ?? 0, end: ws.last?.t1 ?? 0, words: ws)
    }

    // MARK: buildQueue

    /// 저신뢰 단어만, transcript 순서로, 단어 단위로 펼쳐진다.
    func testBuildQueuePicksLowConfWordsInOrder() {
        let l1 = line([(0, 0.5, "ok", 0.9), (0.5, 1.0, "huh", 0.3)])
        let l2 = line([(2.0, 2.4, "what", 0.2), (2.4, 2.8, "fine", 0.8)])
        let q = ReviewController.buildQueue([l1, l2], threshold: 0.55)
        XCTAssertEqual(q.map(\.text), ["huh", "what"])
        XCTAssertEqual(q[0].t0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(q[0].t1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(q[0].lineID, l1.id)
        XCTAssertEqual(q[1].lineID, l2.id)
    }

    /// 공백뿐인 저신뢰 단어는 큐에서 제외.
    func testBuildQueueSkipsBlankWords() {
        let l = line([(0, 0.2, "   ", 0.1), (0.2, 0.6, "real", 0.1)])
        let q = ReviewController.buildQueue([l], threshold: 0.55)
        XCTAssertEqual(q.map(\.text), ["real"])
    }

    /// 임계값 경계: conf == threshold 는 저신뢰가 아님(< 만 잡음).
    func testThresholdIsStrictLessThan() {
        let l = line([(0, 0.2, "edge", 0.55)])
        XCTAssertTrue(ReviewController.buildQueue([l], threshold: 0.55).isEmpty)
    }

    // MARK: wrap arithmetic

    func testWrappedForwardAndBackward() {
        XCTAssertEqual(ReviewController.wrapped(2, by: 1, count: 3), 0)   // wrap forward
        XCTAssertEqual(ReviewController.wrapped(0, by: -1, count: 3), 2)  // wrap backward
        XCTAssertEqual(ReviewController.wrapped(5, by: 0, count: 0), 0)   // empty → 0
    }

    // MARK: listening lifecycle

    private func loaded() -> ReviewController {
        let c = ReviewController()
        let l = line([(0, 0.5, "a", 0.1), (1.0, 1.5, "b", 0.1), (2.0, 2.5, "c", 0.1)])
        c.refresh(lines: [l], threshold: 0.55)
        return c
    }

    /// 파일 모드(canPlay)일 때 토글하면 듣기가 켜지고 첫 단어를 돌려준다.
    func testToggleOnReturnsFirstSpan() {
        let c = loaded()
        let span = c.toggleListening(canPlay: true)
        XCTAssertTrue(c.isListening)
        XCTAssertEqual(span?.text, "a")
        XCTAssertEqual(c.index, 0)
    }

    /// 파일 모드가 아니면(canPlay=false) 켜지지 않는다.
    func testToggleBlockedWhenCannotPlay() {
        let c = loaded()
        XCTAssertNil(c.toggleListening(canPlay: false))
        XCTAssertFalse(c.isListening)
    }

    /// 빈 큐면 켜지지 않는다.
    func testToggleBlockedWhenQueueEmpty() {
        let c = ReviewController()
        c.refresh(lines: [line([(0, 0.5, "hi", 0.9)])], threshold: 0.55)   // 전부 고신뢰
        XCTAssertNil(c.toggleListening(canPlay: true))
        XCTAssertFalse(c.isListening)
    }

    /// advance 가 한 단어씩 전진하다 마지막에서 깔끔히 정지.
    func testAdvanceWalksThenStopsAtEnd() {
        let c = loaded()
        _ = c.toggleListening(canPlay: true)         // index 0 ("a")
        XCTAssertEqual(c.advance()?.text, "b")        // → 1
        XCTAssertEqual(c.advance()?.text, "c")        // → 2 (마지막)
        XCTAssertNil(c.advance())                     // 끝 → 정지
        XCTAssertFalse(c.isListening)
        XCTAssertEqual(c.index, 2)                     // 인덱스는 마지막 유지
    }

    /// 듣기 꺼져 있으면 advance 는 아무 일도 안 함.
    func testAdvanceNoopWhenNotListening() {
        let c = loaded()
        XCTAssertNil(c.advance())
        XCTAssertEqual(c.index, 0)
    }

    /// 수동 점프는 듣기를 멈추고 인덱스를 wrap 이동.
    func testManualJumpPausesListening() {
        let c = loaded()
        _ = c.toggleListening(canPlay: true)
        c.manualJump(-1)                               // 0 → wrap → 2
        XCTAssertFalse(c.isListening)
        XCTAssertEqual(c.index, 2)
    }

    /// 큐가 빈 라인으로 refresh 되면 듣기가 자동 종료되고 인덱스 0.
    func testRefreshToEmptyStopsListening() {
        let c = loaded()
        _ = c.toggleListening(canPlay: true)
        c.refresh(lines: [line([(0, 0.5, "hi", 0.99)])], threshold: 0.55)
        XCTAssertTrue(c.queue.isEmpty)
        XCTAssertFalse(c.isListening)
        XCTAssertEqual(c.index, 0)
    }

    /// 큐가 줄어들면 인덱스를 마지막으로 클램프(범위 밖 방지).
    func testRefreshClampsIndex() {
        let c = loaded()                               // 큐 3개
        _ = c.toggleListening(canPlay: true)
        _ = c.advance(); _ = c.advance()               // index 2
        c.refresh(lines: [line([(0, 0.5, "a", 0.1), (1, 1.5, "b", 0.1)])], threshold: 0.55)  // 큐 2개
        XCTAssertEqual(c.queue.count, 2)
        XCTAssertEqual(c.index, 1)
    }
}
