import XCTest
@testable import SovereignCore

/// Live 0.3.6 (2026-09-03, KO→EN·日): the caption lane held a backlog from
/// 00:01:30 to the end of the session, and the rolling summary pane never
/// updated again after 00:01:24 — nine minutes with the same three bullets.
final class BackgroundLaneAdmissionTests: XCTestCase {
    private func admits(_ depth: Int, _ backlog: Int, _ idle: Double) -> Bool {
        BackgroundLaneAdmission.admits(queueDepth: depth, backlog: backlog, secondsSinceProgress: idle)
    }

    func testIdleCaptionLaneAdmitsImmediately() {
        XCTAssertTrue(admits(0, 0, 0))
        XCTAssertTrue(admits(0, 0, 5))
    }

    func testBusyLaneDefersUntilStarved() {
        XCTAssertFalse(admits(3, 0, 30), "a short busy spell still yields to captions")
        XCTAssertFalse(admits(0, 2, 89))
        XCTAssertTrue(admits(3, 0, 90), "at the valve the lane submits anyway")
        XCTAssertTrue(admits(20, 14, 600), "a permanently busy lane cannot freeze the pane")
    }

    /// The observed session: 30 s ticks, backlog from tick 3 onward, never idle.
    /// Old rule = zero updates forever; new rule = one update per valve period.
    func testTickSequenceUnderPermanentBacklog() {
        var idle = 0.0, admitted = 0
        for tick in 1...20 {
            let depth = tick >= 3 ? 8 : 0
            if admits(depth, 0, idle) { admitted += 1; idle = 0 } else { idle += 30 }
        }
        XCTAssertEqual(admitted, 6, "2 idle ticks + one admission per 90 s valve")
    }

    func testStarvedAfterIsTheBrokerValvePeriod() {
        XCTAssertEqual(BackgroundLaneAdmission.starvedAfter, DNAEngineBroker.backgroundAgingSeconds)
    }
}
