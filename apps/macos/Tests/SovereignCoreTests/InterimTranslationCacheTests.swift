import XCTest
@testable import SovereignCore

final class InterimTranslationCacheTests: XCTestCase {

    func testExactMatchHit() {
        var c = InterimTranslationCache()
        c.put("Hello there", ["Korean": "안녕하세요", "Japanese": "こんにちは"])
        let hit = c.get("Hello there")
        XCTAssertEqual(hit?["Korean"], "안녕하세요")
        XCTAssertEqual(hit?["Japanese"], "こんにちは")
    }

    func testMissOnDifferentText() {
        var c = InterimTranslationCache()
        c.put("Hello there", ["Korean": "안녕하세요"])
        XCTAssertNil(c.get("Goodbye now"))
    }

    func testNormalizedMatch() {
        var c = InterimTranslationCache()
        // Stored with surrounding whitespace + an embedded newline; queried plain.
        c.put("  Hello\nthere  ", ["Korean": "안녕"])
        XCTAssertEqual(c.get("Hello there")?["Korean"], "안녕")
        // ...and the reverse: stored plain, queried with whitespace/newline noise.
        var d = InterimTranslationCache()
        d.put("Hello there", ["Korean": "안녕"])
        XCTAssertEqual(d.get("\tHello\nthere\n")?["Korean"], "안녕")
    }

    func testEmptySourceAndEmptyTranslationsIgnored() {
        var c = InterimTranslationCache()
        c.put("   \n  ", ["Korean": "x"])      // empty after normalization
        c.put("Real text", [:])                 // empty translations
        XCTAssertTrue(c.isEmpty)
        XCTAssertNil(c.get("   "))
        XCTAssertNil(c.get("Real text"))
    }

    func testLRUEvictionAtCapacity() {
        var c = InterimTranslationCache(capacity: 3)
        c.put("a", ["Korean": "1"])
        c.put("b", ["Korean": "2"])
        c.put("c", ["Korean": "3"])
        c.put("d", ["Korean": "4"])   // evicts the oldest unused ("a")
        XCTAssertEqual(c.count, 3)
        XCTAssertNil(c.peek("a"))
        XCTAssertEqual(c.peek("b")?["Korean"], "2")
        XCTAssertEqual(c.peek("d")?["Korean"], "4")
    }

    func testLRUOrderRefreshedOnGet() {
        var c = InterimTranslationCache(capacity: 3)
        c.put("a", ["Korean": "1"])
        c.put("b", ["Korean": "2"])
        c.put("c", ["Korean": "3"])
        _ = c.get("a")                // "a" is now most-recently-used
        c.put("d", ["Korean": "4"])   // evicts "b" (now the oldest), not "a"
        XCTAssertNotNil(c.peek("a"))
        XCTAssertNil(c.peek("b"))
        XCTAssertNotNil(c.peek("d"))
    }

    func testCrossTextIsolationNoBleed() {
        var c = InterimTranslationCache()
        c.put("Sentence one", ["Korean": "문장 하나"])
        c.put("Sentence two", ["Korean": "문장 둘"])
        // Each source returns ONLY its own translation — no bleed between entries.
        XCTAssertEqual(c.get("Sentence one")?["Korean"], "문장 하나")
        XCTAssertEqual(c.get("Sentence two")?["Korean"], "문장 둘")
        XCTAssertNil(c.get("Sentence three"))
    }

    func testClearEmpties() {
        var c = InterimTranslationCache()
        c.put("Hello", ["Korean": "안녕"])
        c.put("World", ["Korean": "세계"])
        XCTAssertFalse(c.isEmpty)
        c.clear()
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.count, 0)
        XCTAssertNil(c.get("Hello"))
    }

    func testPutMergesLanguagesAcrossTurns() {
        var c = InterimTranslationCache()
        c.put("Hello", ["Korean": "안녕"])
        c.put("Hello", ["Japanese": "こんにちは"])   // same source, a later target added
        let hit = c.get("Hello")
        XCTAssertEqual(hit?["Korean"], "안녕")
        XCTAssertEqual(hit?["Japanese"], "こんにちは")
        XCTAssertEqual(c.count, 1)
    }
}
