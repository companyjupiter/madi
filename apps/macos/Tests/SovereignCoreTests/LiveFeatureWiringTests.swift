import XCTest
@testable import SovereignCore

/// P6: both live lanes are switched off by product decision. The test states the
/// decision so that turning one back on is a deliberate edit with a failing test,
/// not something that drifts back in.
final class LiveFeatureWiringTests: XCTestCase {
    func testInterimTranslationIsUnwired() {
        XCTAssertFalse(LiveFeatureWiring.interimTranslation,
                       "translating the in-progress hypothesis was measured to cost more than it returns")
    }

    func testLiveSummaryIsUnwired() {
        XCTAssertFalse(LiveFeatureWiring.liveSummary,
                       "the rolling summary pane is unwired pending a redesign")
    }
}

extension LiveFeatureWiringTests {
    /// P6: the tail line is translated only after the transcription preview clears.
    func testTailTranslationWaitsForPreview() {
        XCTAssertTrue(LiveFeatureWiring.tailTranslationWaitsForPreview)
    }
}
