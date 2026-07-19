// L10nTests — the runtime UI-language helper + a localized enum label. GUI-free.
import XCTest
@testable import SovereignCore

final class L10nTests: XCTestCase {

    func testPicksStringByLanguage() {
        XCTAssertEqual(UILanguage.ko("녹음 시작", "Start recording"), "녹음 시작")
        XCTAssertEqual(UILanguage.en("녹음 시작", "Start recording"), "Start recording")
    }

    func testNativeNames() {
        XCTAssertEqual(UILanguage.ko.nativeName, "한국어")
        XCTAssertEqual(UILanguage.en.nativeName, "English")
    }

    func testEnumLabelLocalizes() {
        XCTAssertEqual(MeetingMode.general.label(.ko), "일반")
        XCTAssertEqual(MeetingMode.general.label(.en), "General")
        XCTAssertEqual(MeetingMode.oneOnOne.label(.en), "1:1")   // symbol stays
        // Back-compat: the Korean `var label` is unchanged for not-yet-localized callers.
        XCTAssertEqual(MeetingMode.lecture.label, "강의")
    }
}
