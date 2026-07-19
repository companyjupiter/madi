// L10nTests — the runtime UI-language helper + a localized enum label. GUI-free.
import XCTest
@testable import SovereignCore

final class L10nTests: XCTestCase {

    func testPicksStringByLanguage() {
        XCTAssertEqual(UILanguage.ko("녹음 시작", "Start recording"), "녹음 시작")
        XCTAssertEqual(UILanguage.en("녹음 시작", "Start recording"), "Start recording")
    }

    func testJapaneseResolutionOrder() {
        // Resolution order for .ja: inline ja > L10nJa.table[en] > en.
        // 1. En NOT in the table → English fallback (never Korean).
        XCTAssertEqual(UILanguage.ja("가나다", "zzz not a real ui string"), "zzz not a real ui string")
        // 2. En IN the table → the Japanese translation.
        XCTAssertEqual(UILanguage.ja("녹음 시작", "Start recording"), "録音開始")
        XCTAssertEqual(L10nJa.table["Start recording"], "録音開始")
        // 3. Inline ja argument wins over the table.
        XCTAssertEqual(UILanguage.ja("녹음 시작", "Start recording", "インライン"), "インライン")
        // ko/en are unaffected by the 3rd arg / the table.
        XCTAssertEqual(UILanguage.ko("녹음 시작", "Start recording", "録音開始"), "녹음 시작")
        XCTAssertEqual(UILanguage.en("녹음 시작", "Start recording", "録音開始"), "Start recording")
    }

    func testNativeNames() {
        XCTAssertEqual(UILanguage.ko.nativeName, "한국어")
        XCTAssertEqual(UILanguage.en.nativeName, "English")
        XCTAssertEqual(UILanguage.ja.nativeName, "日本語")
        // The picker iterates allCases — all three languages must be selectable.
        XCTAssertEqual(UILanguage.allCases, [.ko, .en, .ja])
    }

    func testEnumLabelLocalizes() {
        XCTAssertEqual(MeetingMode.general.label(.ko), "일반")
        XCTAssertEqual(MeetingMode.general.label(.en), "General")
        XCTAssertEqual(MeetingMode.oneOnOne.label(.en), "1:1")   // symbol stays
        // Back-compat: the Korean `var label` is unchanged for not-yet-localized callers.
        XCTAssertEqual(MeetingMode.lecture.label, "강의")
    }
}
