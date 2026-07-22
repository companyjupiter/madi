import XCTest
@testable import SovereignCore

final class RecordingStartAdmissionTests: XCTestCase {
    func testTerminalCountdownTickStartsRecording() {
        XCTAssertTrue(RecordingStartAdmission.allows(.countdown(1)))
    }

    func testEarlierCountdownTicksCannotStartRecording() {
        XCTAssertFalse(RecordingStartAdmission.allows(.countdown(3)))
        XCTAssertFalse(RecordingStartAdmission.allows(.countdown(2)))
        XCTAssertFalse(RecordingStartAdmission.allows(.countdown(0)))
    }

    func testDirectRetryStatesRemainAdmitted() {
        XCTAssertTrue(RecordingStartAdmission.allows(.idle))
        XCTAssertTrue(RecordingStartAdmission.allows(.done))
        XCTAssertTrue(RecordingStartAdmission.allows(.error))
    }

    func testBusyEngineStatesRemainRejected() {
        XCTAssertFalse(RecordingStartAdmission.allows(.busy))
    }
}
