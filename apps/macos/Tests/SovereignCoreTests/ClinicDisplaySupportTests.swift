import XCTest
@testable import SovereignCore

final class CaptionStatusTests: XCTestCase {
    func testLocalizedToViewerLanguage() {
        XCTAssertEqual(CaptionStatus.translating.text(for: "Japanese"), "翻訳中…")
        XCTAssertEqual(CaptionStatus.translating.text(for: "Chinese"), "翻译中…")
        XCTAssertEqual(CaptionStatus.waiting.text(for: "English"), "waiting for speech…")
        XCTAssertEqual(CaptionStatus.live.text(for: "Korean"), "진행 중")
    }
    func testUnknownLangFallsBackToKorean() {
        XCTAssertEqual(CaptionStatus.waiting.text(for: nil), "음성을 기다리는 중…")
        XCTAssertEqual(CaptionStatus.waiting.text(for: "Klingon"), "음성을 기다리는 중…")
    }
}

final class CaptionSettingsTests: XCTestCase {
    func testClampBounds() {
        var s = CaptionSettings()
        s.patientFontSize = 500; s.minScaleFactor = 0.1; s.panelWidth = 10
        let c = s.clamped
        XCTAssertEqual(c.patientFontSize, 96)
        XCTAssertEqual(c.minScaleFactor, 0.5)
        XCTAssertEqual(c.panelWidth, 480)
    }
    func testRoundTripCodable() throws {
        var s = CaptionSettings()
        s.patientPanelEnabled = true; s.patientScreenIndex = 1; s.patientLangOverride = "Japanese"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(CaptionSettings.self, from: data)
        XCTAssertEqual(s, back)
    }
}

final class ChatLayoutTests: XCTestCase {
    func testFirstSpeakerLeadsOthersTrail() {
        XCTAssertEqual(ChatLayout.side(for: 0, firstSpeaker: 0), .leading)
        XCTAssertEqual(ChatLayout.side(for: 1, firstSpeaker: 0), .trailing)
        XCTAssertEqual(ChatLayout.side(for: 2, firstSpeaker: 2), .leading)
    }
    func testNilFirstSpeakerDefaultsLeading() {
        XCTAssertEqual(ChatLayout.side(for: 5, firstSpeaker: nil), .leading)
    }
    func testAppliesOnlyForTwoParties() {
        XCTAssertTrue(ChatLayout.applies(speakers: [0, 1]))
        XCTAssertFalse(ChatLayout.applies(speakers: [0]))
        XCTAssertFalse(ChatLayout.applies(speakers: [0, 1, 2]))
    }
}
