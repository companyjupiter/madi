import XCTest
@testable import SovereignCore

final class LowMemoryGuidePolicyTests: XCTestCase {
    func testEightGBPresentsCurrentGuideOnce() {
        let memory = UInt64(8) * (1 << 30)
        XCTAssertTrue(LowMemoryGuidePolicy.shouldPresent(
            physicalMemory: memory, presentedRevision: 0))
        XCTAssertFalse(LowMemoryGuidePolicy.shouldPresent(
            physicalMemory: memory,
            presentedRevision: LowMemoryGuidePolicy.currentRevision))
    }

    func testSixteenGBNeverPresentsLowMemoryGuide() {
        XCTAssertFalse(LowMemoryGuidePolicy.shouldPresent(
            physicalMemory: UInt64(16) * (1 << 30), presentedRevision: 0))
    }

    func testNewGuideRevisionCanPresentAgain() {
        XCTAssertTrue(LowMemoryGuidePolicy.shouldPresent(
            physicalMemory: UInt64(8) * (1 << 30),
            presentedRevision: 1,
            currentRevision: 2))
    }

    func testTwelveGBBoundaryUsesQualityProfileAndDoesNotPresent() {
        XCTAssertFalse(LowMemoryGuidePolicy.isEightGBClass(
            physicalMemory: UInt64(12) * (1 << 30)))
    }
}
