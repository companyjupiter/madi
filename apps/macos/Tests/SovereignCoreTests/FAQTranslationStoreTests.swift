// FAQTranslationStoreTests.swift — conservative exact-match semantics: hits
// must survive punctuation/spacing variance, misses must stay misses (fuzzy
// matching is deliberately rejected — medical context).

import XCTest
@testable import SovereignCore

final class FAQTranslationStoreTests: XCTestCase {
    private let store = FAQTranslationStore(entries: [
        ["Korean": "시술 후 3일간 사우나와 격한 운동은 피해 주세요.",
         "Japanese": "施術後3日間はサウナと激しい運動をお控えください。",
         "Chinese": "术后三天请避免桑拿和剧烈运动。"],
        ["Japanese": "痛みはありますか?", "Korean": "아픈가요?"],
    ])

    func testExactHitReturnsOtherLanguages() {
        let r = store.lookup("시술 후 3일간 사우나와 격한 운동은 피해 주세요.")
        XCTAssertEqual(r?["Japanese"], "施術後3日間はサウナと激しい運動をお控えください。")
        XCTAssertEqual(r?["Chinese"], "术后三天请避免桑拿和剧烈运动。")
        XCTAssertNil(r?["Korean"])   // the matched source column is dropped
    }

    func testPunctuationAndSpacingVarianceStillHits() {
        // STT commits without the trailing period and with different spacing
        let r = store.lookup("시술후 3일간 사우나와 격한 운동은 피해주세요")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?["Japanese"], "施術後3日間はサウナと激しい運動をお控えください。")
    }

    func testReverseDirectionLookup() {
        // the JAPANESE column of an entry resolves toward Korean
        let r = store.lookup("痛みはありますか")
        XCTAssertEqual(r?["Korean"], "아픈가요?")
    }

    func testNearMissDoesNotFuzzyMatch() {
        // one word differs — must MISS (fuzzy hits are worse than misses here)
        XCTAssertNil(store.lookup("시술 후 5일간 사우나와 격한 운동은 피해 주세요."))
    }

    func testShortKeyNeverIndexes() {
        // "아픈가요?" normalizes to 4+ chars and works; a 2-char utterance must not
        let s = FAQTranslationStore(entries: [["Korean": "네.", "Japanese": "はい。"]])
        XCTAssertNil(s.lookup("네."))
    }
}
