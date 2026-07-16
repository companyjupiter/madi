// AppVersionTests — the correctness-critical pure logic behind Help → 업데이트/정보:
//   • SemVer parse + precedence (semver.org 2.0.0 §11), incl. the exact beta
//     ordering the updater depends on (0.9.0-beta.1 < 0.9.0-beta.2 < 0.9.0 < 1.0.0).
//   • Beta-expiry status: active / expiringSoon(D-n) / expired, and the
//     clock-rollback latch via the high-water mark.
//   • ReleaseFeed.newest: prerelease inclusion, "strictly newer", DMG asset pick,
//     draft skip, highest-of-many.
import XCTest
@testable import SovereignCore

final class AppVersionTests: XCTestCase {

    // MARK: SemVer parsing

    func testParseBasicAndTolerant() {
        XCTAssertEqual(SemVer("1.2.3").map(\.description), "1.2.3")
        XCTAssertEqual(SemVer("v0.9.0-beta.1")?.description, "0.9.0-beta.1", "leading v stripped")
        XCTAssertEqual(SemVer("1.0")?.description, "1.0.0", "missing patch → 0")
        XCTAssertEqual(SemVer("2")?.description, "2.0.0", "missing minor+patch → 0")
        // build metadata is dropped from precedence
        XCTAssertEqual(SemVer("1.0.0+build.7")?.description, "1.0.0")
        XCTAssertNil(SemVer("not-a-version"), "no leading integer → nil")
        XCTAssertNil(SemVer(""), "empty → nil")
    }

    // MARK: SemVer precedence

    func testCorePrecedence() {
        XCTAssertLessThan(SemVer("1.0.0")!, SemVer("2.0.0")!)
        XCTAssertLessThan(SemVer("1.9.0")!, SemVer("1.10.0")!, "numeric, not lexical")
        XCTAssertLessThan(SemVer("1.0.0")!, SemVer("1.0.1")!)
    }

    func testPrereleaseIsLowerThanRelease() {
        // §11.3 — a version with a prerelease is LOWER than the same core release.
        XCTAssertLessThan(SemVer("1.0.0-beta.1")!, SemVer("1.0.0")!)
        XCTAssertLessThan(SemVer("0.9.0-rc.1")!, SemVer("0.9.0")!)
    }

    func testPrereleaseIdentifierOrdering() {
        // numeric identifiers compare numerically
        XCTAssertLessThan(SemVer("0.9.0-beta.1")!, SemVer("0.9.0-beta.2")!)
        XCTAssertLessThan(SemVer("0.9.0-beta.2")!, SemVer("0.9.0-beta.10")!, "numeric, not lexical")
        // numeric < alphanumeric (§11.4.3)
        XCTAssertLessThan(SemVer("1.0.0-1")!, SemVer("1.0.0-alpha")!)
        // more fields wins when all preceding equal (§11.4.4)
        XCTAssertLessThan(SemVer("1.0.0-alpha")!, SemVer("1.0.0-alpha.1")!)
        // canonical semver.org example chain
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
                     "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                     "1.0.0-rc.1", "1.0.0"].map { SemVer($0)! }
        for i in 0..<(chain.count - 1) {
            XCTAssertLessThan(chain[i], chain[i + 1], "chain[\(i)] < chain[\(i+1)]")
        }
    }

    func testTheBetaLifecycleOrdering() {
        // The exact chain the updater must respect for this release.
        XCTAssertLessThan(SemVer("0.9.0-beta.1")!, SemVer("0.9.0-beta.2")!)
        XCTAssertLessThan(SemVer("0.9.0-beta.2")!, SemVer("0.9.0")!)
        XCTAssertLessThan(SemVer("0.9.0")!, SemVer("1.0.0-beta.1")!)
        XCTAssertLessThan(SemVer("1.0.0-beta.1")!, SemVer("1.0.0")!)
    }

    func testEquality() {
        XCTAssertFalse(SemVer("1.0.0")! < SemVer("1.0.0")!)
        XCTAssertFalse(SemVer("1.0.0")! > SemVer("1.0.0")!)
        XCTAssertEqual(SemVer("v1.2.3"), SemVer("1.2.3"))
    }

    // MARK: expiry status

    private func day(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testExpiryActiveFarFromDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let expiry = day(2026, 12, 1, cal)
        let now = day(2026, 6, 1, cal)
        XCTAssertEqual(AppVersion.expiryStatus(now: now, expiry: expiry, highWater: nil, calendar: cal), .active)
    }

    func testExpiryWarningWindow() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let expiry = day(2026, 12, 1, cal)
        // 14 days before → boundary of the window
        XCTAssertEqual(AppVersion.expiryStatus(now: day(2026, 11, 17, cal), expiry: expiry, highWater: nil, calendar: cal),
                       .expiringSoon(daysLeft: 14))
        // 15 days before → still active
        XCTAssertEqual(AppVersion.expiryStatus(now: day(2026, 11, 16, cal), expiry: expiry, highWater: nil, calendar: cal),
                       .active)
        // 1 day before → D-1
        XCTAssertEqual(AppVersion.expiryStatus(now: day(2026, 11, 30, cal), expiry: expiry, highWater: nil, calendar: cal),
                       .expiringSoon(daysLeft: 1))
    }

    func testExpiredAtAndAfterDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let expiry = day(2026, 12, 1, cal)
        XCTAssertEqual(AppVersion.expiryStatus(now: expiry, expiry: expiry, highWater: nil, calendar: cal), .expired,
                       "at local midnight of the expiry day → expired")
        XCTAssertEqual(AppVersion.expiryStatus(now: day(2026, 12, 2, cal), expiry: expiry, highWater: nil, calendar: cal),
                       .expired)
    }

    func testExpiryLatchDefeatsClockRollback() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let expiry = day(2026, 12, 1, cal)
        // We once observed a post-expiry time; now the clock is rolled back to June.
        let rolledBack = day(2026, 6, 1, cal)
        let highWater = day(2026, 12, 5, cal)
        XCTAssertEqual(AppVersion.expiryStatus(now: rolledBack, expiry: expiry, highWater: highWater, calendar: cal),
                       .expired, "high-water >= expiry latches expired despite rollback")
    }

    func testExpiryHighWaterBeforeExpiryDoesNotLatch() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let expiry = day(2026, 12, 1, cal)
        // high-water is before expiry → no latch; status follows `now`.
        XCTAssertEqual(AppVersion.expiryStatus(now: day(2026, 6, 1, cal), expiry: expiry,
                                               highWater: day(2026, 6, 2, cal), calendar: cal),
                       .active)
    }

    func testEvaluateExpiryAdvancesHighWater() {
        let defaults = UserDefaults(suiteName: "AppVersionTests.\(UUID().uuidString)")!
        let key = AppVersion.highWaterKey
        // First eval seeds high-water; a later eval with an earlier clock must not lower it.
        _ = AppVersion.evaluateExpiry(now: Date(timeIntervalSince1970: 2_000_000_000), defaults: defaults)
        let first = defaults.double(forKey: key)
        _ = AppVersion.evaluateExpiry(now: Date(timeIntervalSince1970: 1_000_000_000), defaults: defaults)
        let second = defaults.double(forKey: key)
        XCTAssertEqual(first, second, "rolling the clock back must not lower the persisted high-water")
    }

    // MARK: ReleaseFeed parsing

    private func feed(_ json: String) -> Data { json.data(using: .utf8)! }

    func testNewestPicksHighestNewerIncludingPrerelease() {
        let data = feed("""
        [
          {"tag_name":"v0.9.0-beta.2","body":"n2","html_url":"https://x/2",
           "assets":[{"name":"Madi-0.9.0-beta.2.dmg","browser_download_url":"https://x/2.dmg","size":123}]},
          {"tag_name":"v0.9.0-beta.1","body":"n1","html_url":"https://x/1","assets":[]}
        ]
        """)
        let r = ReleaseFeed.newest(from: data, current: SemVer("0.9.0-beta.1")!)
        XCTAssertEqual(r?.tag, "v0.9.0-beta.2")
        XCTAssertEqual(r?.dmgURL?.absoluteString, "https://x/2.dmg")
        XCTAssertEqual(r?.dmgSize, 123)
    }

    func testNewestReturnsNilWhenNothingNewer() {
        let data = feed("""
        [{"tag_name":"v0.9.0-beta.1","assets":[]}]
        """)
        XCTAssertNil(ReleaseFeed.newest(from: data, current: SemVer("0.9.0-beta.1")!),
                     "same version is not strictly newer")
    }

    func testNewestPrefersStableOverBeta() {
        let data = feed("""
        [
          {"tag_name":"v1.0.0","assets":[{"name":"Madi.dmg","browser_download_url":"https://x/s.dmg","size":9}]},
          {"tag_name":"v1.0.0-beta.5","assets":[]}
        ]
        """)
        let r = ReleaseFeed.newest(from: data, current: SemVer("0.9.0-beta.1")!)
        XCTAssertEqual(r?.tag, "v1.0.0", "stable 1.0.0 outranks 1.0.0-beta.5")
    }

    func testNewestSkipsDraftsAndPicksDMGAsset() {
        let data = feed("""
        [
          {"tag_name":"v2.0.0","draft":true,"assets":[]},
          {"tag_name":"v1.5.0","body":"real","html_url":"https://x/15",
           "assets":[
             {"name":"notes.txt","browser_download_url":"https://x/notes.txt","size":1},
             {"name":"Madi-1.5.0.dmg","browser_download_url":"https://x/15.dmg","size":456}
           ]}
        ]
        """)
        let r = ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!)
        XCTAssertEqual(r?.tag, "v1.5.0", "draft 2.0.0 is skipped")
        XCTAssertEqual(r?.dmgURL?.absoluteString, "https://x/15.dmg", "picks the .dmg, not the .txt")
        XCTAssertEqual(r?.dmgSize, 456)
    }

    func testNewestNoDMGLeavesNilURL() {
        let data = feed("""
        [{"tag_name":"v1.2.0","html_url":"https://x/12","assets":[]}]
        """)
        let r = ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!)
        XCTAssertEqual(r?.tag, "v1.2.0")
        XCTAssertNil(r?.dmgURL)
        XCTAssertEqual(r?.pageURL.absoluteString, "https://x/12")
    }

    func testNewestPrefersStandardDMGOverOfflineDMG() {
        let data = feed("""
        [{"tag_name":"v1.2.0","assets":[
          {"name":"Madi-1.2.0-offline-arm64.dmg","browser_download_url":"https://x/offline.dmg","size":900},
          {"name":"Madi-1.2.0-arm64.dmg","browser_download_url":"https://x/standard.dmg","size":30}
        ]}]
        """)
        let r = ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!)
        XCTAssertEqual(r?.dmgURL?.absoluteString, "https://x/standard.dmg")
        XCTAssertEqual(r?.dmgSize, 30)
    }

    func testNewestGarbageJSON() {
        XCTAssertNil(ReleaseFeed.newest(from: feed("not json"), current: SemVer("1.0.0")!))
        XCTAssertNil(ReleaseFeed.newest(from: feed("{}"), current: SemVer("1.0.0")!), "object, not array")
    }
}
