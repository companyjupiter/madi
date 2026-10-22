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

    /// Redesigned (live notes) but OFF by default until a live session confirms caption
    /// latency with it on; the trial switch is a user default, not a build change.
    func testLiveSummaryIsUnwiredByDefault() {
        let key = "liveSummaryWired"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(LiveFeatureWiring.liveSummary, "off unless deliberately switched on")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(LiveFeatureWiring.liveSummary, "the trial switch wires it without a rebuild")
    }
}

extension LiveFeatureWiringTests {
    /// P6: the tail line is translated only after the transcription preview clears.
    func testTailTranslationWaitsForPreview() {
        XCTAssertTrue(LiveFeatureWiring.tailTranslationWaitsForPreview)
    }

    func testTranslationStreamingIsOff() {
        XCTAssertFalse(LiveFeatureWiring.translationStreaming,
                       "a committed line's translation lands once, complete — no typewriter preview")
    }
}
