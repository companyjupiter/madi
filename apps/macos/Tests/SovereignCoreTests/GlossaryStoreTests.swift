// GlossaryStoreTests — persistent personal-vocabulary store: learn/reinforce,
// active-rule gating, Codable round-trip + upgrade-safe decode.
import XCTest
@testable import SovereignCore

final class GlossaryStoreTests: XCTestCase {

    func testLearnCreatesAndReinforces() {
        var g = Glossary()
        g.learn(wrong: "소버림", right: "소버린")
        XCTAssertEqual(g.entries["소버림"]?.right, "소버린")
        XCTAssertEqual(g.entries["소버림"]?.hits, 1)
        g.learn(wrong: "소버림", right: "소버린")
        XCTAssertEqual(g.entries["소버림"]?.hits, 2, "same correction reinforces hit count")
        XCTAssertEqual(g.entries.count, 1, "no duplicate entry for the same wrong key")
    }

    func testLearnIgnoresSelfAndEmpty() {
        var g = Glossary()
        g.learn(wrong: "같음", right: "같음")   // self-correction
        g.learn(wrong: "", right: "뭔가")
        g.learn(wrong: "뭔가", right: "")
        XCTAssertTrue(g.entries.isEmpty)
    }

    func testChangedMappingLatestWins() {
        var g = Glossary()
        g.learn(wrong: "김방장", right: "김부장")
        g.learn(wrong: "김방장", right: "김반장")   // user changed their mind
        XCTAssertEqual(g.entries["김방장"]?.right, "김반장")
        XCTAssertEqual(g.entries["김방장"]?.hits, 2)
    }

    func testMinHitsGatesActiveAndExact() {
        var g = Glossary()
        g.minHits = 2
        g.learn(wrong: "데에터", right: "데이터")   // hits = 1, below gate
        XCTAssertNil(g.exact("데에터"), "below minHits → not active")
        XCTAssertTrue(g.activeEntries.isEmpty)
        g.learn(wrong: "데에터", right: "데이터")   // hits = 2
        XCTAssertEqual(g.exact("데에터")?.right, "데이터")
        XCTAssertEqual(g.activeEntries.count, 1)
    }

    func testForgetAndClear() {
        var g = Glossary()
        g.learn(wrong: "에이피아이", right: "API")
        g.learn(wrong: "쿠버", right: "쿠버네티스")
        g.forget("에이피아이")
        XCTAssertNil(g.entries["에이피아이"])
        XCTAssertEqual(g.entries.count, 1)
        g.clear()
        XCTAssertTrue(g.entries.isEmpty)
    }

    func testCodableRoundTrip() throws {
        var g = Glossary()
        g.enabled = true
        g.minHits = 2
        g.learn(wrong: "소버림", right: "소버린")
        g.learn(wrong: "소버림", right: "소버린")
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(Glossary.self, from: data)
        XCTAssertEqual(g, back)
        XCTAssertTrue(back.enabled)
        XCTAssertEqual(back.minHits, 2)
        XCTAssertEqual(back.exact("소버림")?.right, "소버린")
    }

    func testUpgradeSafeDecodeMissingKeys() throws {
        // A blob written by an older build that only had `entries` — no enabled/minHits.
        let json = """
        {"entries":{"소버림":{"wrong":"소버림","right":"소버린"}}}
        """.data(using: .utf8)!
        let g = try JSONDecoder().decode(Glossary.self, from: json)
        XCTAssertFalse(g.enabled, "missing enabled → default false, not a throw")
        XCTAssertEqual(g.minHits, 2, "v1 data migrates to the two-confirmation safety gate")
        XCTAssertEqual(g.entries["소버림"]?.right, "소버린")
        XCTAssertEqual(g.entries["소버림"]?.hits, 1, "missing hits → default 1")
    }

    func testUserDefaultsPersistRoundTrip() {
        let suite = "glossary.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var g = Glossary()
        g.enabled = true
        g.learn(wrong: "쿠버", right: "쿠버네티스")
        g.learn(wrong: "쿠버", right: "쿠버네티스")
        g.save(defaults)

        let loaded = Glossary.load(defaults)
        XCTAssertEqual(loaded, g)
        XCTAssertEqual(loaded.exact("쿠버")?.right, "쿠버네티스")
    }

    func testLoadDefaultsWhenEmpty() {
        let suite = "glossary.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let g = Glossary.load(defaults)
        XCTAssertFalse(g.enabled)
        XCTAssertTrue(g.entries.isEmpty)
        XCTAssertEqual(g.minHits, 2)
    }

    func testV1ExplicitSingleHitGateMigratesToTwo() throws {
        let json = #"{"enabled":true,"minHits":1,"entries":{}}"#.data(using: .utf8)!
        let g = try JSONDecoder().decode(Glossary.self, from: json)
        XCTAssertEqual(g.minHits, 2)
    }
}
