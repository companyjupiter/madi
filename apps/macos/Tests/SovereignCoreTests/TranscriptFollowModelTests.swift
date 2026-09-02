import XCTest
@testable import SovereignCore

final class TranscriptFollowModelTests: XCTestCase {
    private func refs(_ n: Int, from: Int = 0) -> [TranscriptFollowModel.LineRef] {
        (from..<(from + n)).map { TranscriptFollowModel.LineRef(id: UUID(), end: Double($0)) }
    }

    func testGrowthAboveViewportNeverReleasesFollow() {
        var m = TranscriptFollowModel()
        let lines = refs(5)
        XCTAssertEqual(m.geometry(gap: 0, isLive: true, lines: lines), .none)
        // translations land above the viewport: gap jumps by 600pt with no user input
        XCTAssertEqual(m.geometry(gap: 600, isLive: true, lines: lines), .pinToTail)
        XCTAssertTrue(m.following)
        XCTAssertFalse(m.atBottom)
        // not live (archive): no pin, still following
        XCTAssertEqual(m.geometry(gap: 600, isLive: false, lines: lines), .none)
        XCTAssertTrue(m.following)
    }

    func testUpwardWheelReleasesAndDownwardNearBottomRearms() {
        var m = TranscriptFollowModel()
        m.userScrolled(deltaY: 1, gap: 0)           // jitter
        XCTAssertTrue(m.following)
        m.userScrolled(deltaY: 12, gap: 300)         // scroll up
        XCTAssertFalse(m.following)
        m.userScrolled(deltaY: -12, gap: 400)        // scroll down, still far
        XCTAssertFalse(m.following)
        m.userScrolled(deltaY: -12, gap: 100)        // scroll down near the tail
        XCTAssertTrue(m.following)
    }

    func testUnseenCountSurvivesMergesAndCountsByIdentity() {
        var m = TranscriptFollowModel()
        var lines = refs(5)
        _ = m.geometry(gap: 0, isLive: true, lines: lines)      // seen through line 5
        m.userScrolled(deltaY: 40, gap: 900)                     // reader scrolls up
        _ = m.geometry(gap: 900, isLive: true, lines: lines)
        XCTAssertFalse(m.atBottom); XCTAssertFalse(m.following)
        lines += refs(3, from: 5)                                // +3 commits
        m.linesChanged(lines)
        XCTAssertEqual(m.unseen, 3)
        // a live merge removes one of the NEW lines: 2 remain after the seen tail
        lines.remove(at: 6)
        m.linesChanged(lines)
        XCTAssertEqual(m.unseen, 2)
        lines += refs(4, from: 8)
        m.linesChanged(lines)
        XCTAssertEqual(m.unseen, 6)
        // the seen tail itself is merged away: fall back to time (end > seenTailEnd)
        let seen = m.seenTailID!
        lines.removeAll { $0.id == seen }
        m.linesChanged(lines)
        XCTAssertEqual(m.unseen, 6)
    }

    func testPillTapJumpsAndReengages() {
        var m = TranscriptFollowModel()
        var lines = refs(5)
        _ = m.geometry(gap: 0, isLive: true, lines: lines)
        m.userScrolled(deltaY: 40, gap: 900)
        _ = m.geometry(gap: 900, isLive: true, lines: lines)
        lines += refs(7, from: 5)
        m.linesChanged(lines)
        XCTAssertEqual(m.unseen, 7)
        XCTAssertEqual(m.pillTapped(lines), .pinToTail)
        XCTAssertTrue(m.following); XCTAssertEqual(m.unseen, 0)
        XCTAssertEqual(m.seenTailID, lines.last?.id)
        // geometry during the animated jump: large gaps must not release again
        XCTAssertEqual(m.geometry(gap: 2400, isLive: true, lines: lines), .pinToTail)
        XCTAssertTrue(m.following)
        XCTAssertEqual(m.geometry(gap: 0, isLive: true, lines: lines), .none)
        XCTAssertTrue(m.atBottom)
    }

    func testProgrammaticJumpReleasesAndResetClears() {
        var m = TranscriptFollowModel()
        m.programmaticJump()
        XCTAssertFalse(m.following)
        m.reset()
        XCTAssertTrue(m.following); XCTAssertEqual(m.unseen, 0); XCTAssertNil(m.seenTailID)
        m.linesChanged([])
        XCTAssertTrue(m.following)
    }

    func testWhileFollowingNewLinesAreAlwaysSeen() {
        var m = TranscriptFollowModel()
        var lines = refs(3)
        _ = m.geometry(gap: 0, isLive: true, lines: lines)
        // content grows below: gap > near zone for a frame, but follow holds so nothing is "unseen"
        lines += refs(2, from: 3)
        _ = m.geometry(gap: 300, isLive: true, lines: lines)
        m.linesChanged(lines)
        XCTAssertEqual(m.unseen, 0)
    }
}
