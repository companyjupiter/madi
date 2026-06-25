// MeetingModeTests — pure preset orchestration. GUI-free.
import XCTest
@testable import SovereignCore

final class MeetingModeTests: XCTestCase {

    func testFiveModesCoverFullEnum() {
        XCTAssertEqual(MeetingMode.allCases.count, 5)
        XCTAssertEqual(Set(MeetingMode.allCases),
                       [.general, .oneOnOne, .standup, .interview, .lecture])
    }

    func testRawValuesAreStablePersistenceKeys() {
        // Renaming any of these breaks UserDefaults persistence — pin them.
        XCTAssertEqual(MeetingMode.general.rawValue, "general")
        XCTAssertEqual(MeetingMode.oneOnOne.rawValue, "oneOnOne")
        XCTAssertEqual(MeetingMode.standup.rawValue, "standup")
        XCTAssertEqual(MeetingMode.interview.rawValue, "interview")
        XCTAssertEqual(MeetingMode.lecture.rawValue, "lecture")
        // id mirrors rawValue.
        for m in MeetingMode.allCases { XCTAssertEqual(m.id, m.rawValue) }
    }

    func testLabelsAndSymbolsAreUniqueAndNonEmpty() {
        let labels = MeetingMode.allCases.map(\.label)
        let symbols = MeetingMode.allCases.map(\.sfSymbol)
        XCTAssertEqual(Set(labels).count, labels.count, "labels must be unique")
        XCTAssertEqual(Set(symbols).count, symbols.count, "sf symbols must be unique")
        for l in labels { XCTAssertFalse(l.isEmpty) }
        for s in symbols { XCTAssertFalse(s.isEmpty) }
    }

    func testLabelsAreExpectedKorean() {
        XCTAssertEqual(MeetingMode.general.label, "일반")
        XCTAssertEqual(MeetingMode.oneOnOne.label, "1:1")
        XCTAssertEqual(MeetingMode.standup.label, "스탠드업")
        XCTAssertEqual(MeetingMode.interview.label, "인터뷰")
        XCTAssertEqual(MeetingMode.lecture.label, "강의")
    }

    func testDefaultSpeakerCountsAreSensible() {
        // 1:1 and 인터뷰 fix two speakers; 강의 is one; 일반/스탠드업 stay 자동(0).
        XCTAssertEqual(MeetingMode.general.config.defaultSpeakerCountRaw, 0)
        XCTAssertEqual(MeetingMode.oneOnOne.config.defaultSpeakerCountRaw, 2)
        XCTAssertEqual(MeetingMode.standup.config.defaultSpeakerCountRaw, 0)
        XCTAssertEqual(MeetingMode.interview.config.defaultSpeakerCountRaw, 2)
        XCTAssertEqual(MeetingMode.lecture.config.defaultSpeakerCountRaw, 1)
    }

    func testSpeakerCountRawsAreInValidRange() {
        // Must be a valid SpeakerCount rawValue (0=자동,1,2,3,4=4명 이상).
        for m in MeetingMode.allCases {
            let raw = m.config.defaultSpeakerCountRaw
            XCTAssertTrue((0...4).contains(raw), "\(m) raw \(raw) out of SpeakerCount range")
        }
    }

    func testGeneralSummarySuffixIsEmptyNoOp() {
        // Appending general's suffix must NOT alter the baseline prompt.
        XCTAssertEqual(MeetingMode.general.config.summaryPromptSuffix, "")
    }

    func testNonGeneralModesAddNonEmptyDistinctSuffixes() {
        let nonGeneral = MeetingMode.allCases.filter { $0 != .general }
        let suffixes = nonGeneral.map { $0.config.summaryPromptSuffix }
        for s in suffixes { XCTAssertFalse(s.isEmpty) }
        XCTAssertEqual(Set(suffixes).count, suffixes.count, "each mode nudges differently")
    }

    func testStandupEmphasizesBlockersOneOnOneDecisions() {
        XCTAssertEqual(MeetingMode.standup.config.actionEmphasis, "blockers")
        XCTAssertEqual(MeetingMode.oneOnOne.config.actionEmphasis, "decisions")
        XCTAssertEqual(MeetingMode.interview.config.actionEmphasis, "questions")
        XCTAssertEqual(MeetingMode.general.config.actionEmphasis, "")
        XCTAssertEqual(MeetingMode.lecture.config.actionEmphasis, "")
    }

    func testConfigIsDeterministicAndImmutable() {
        // config is a pure function of mode — two reads are Equatable-equal.
        for m in MeetingMode.allCases {
            XCTAssertEqual(m.config, m.config)
            XCTAssertEqual(m.config.mode, m)
        }
    }

    func testCodableRoundTrip() throws {
        let enc = JSONEncoder(); let dec = JSONDecoder()
        for m in MeetingMode.allCases {
            let data = try enc.encode(m)
            let back = try dec.decode(MeetingMode.self, from: data)
            XCTAssertEqual(back, m)
        }
    }

    func testRawValueInitFallbackForUnknownKey() {
        // An old/garbled UserDefaults value must not crash — init?(rawValue:) is nil,
        // letting the controller fall back to .general.
        XCTAssertNil(MeetingMode(rawValue: "bogus"))
        XCTAssertEqual(MeetingMode(rawValue: "general"), .general)
    }
}
