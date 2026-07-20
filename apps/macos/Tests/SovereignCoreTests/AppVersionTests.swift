// AppVersionTests — the correctness-critical pure logic behind Help → 업데이트/정보:
//   • SemVer parse + precedence (semver.org 2.0.0 §11), incl. the exact beta
//     ordering the updater depends on (0.9.0-beta.1 < 0.9.0-beta.2 < 0.9.0 < 1.0.0).
//   • Beta-expiry status: active / expiringSoon(D-n) / expired, and the
//     clock-rollback latch via the high-water mark.
//   • ReleaseFeed.newest: schema-1 CloudFront feed validation, strict channel /
//     URL / digest checks, and the split between invalid-feed throws vs valid
//     non-newer nil.
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

    func testNewestReturnsReleaseWhenValidAndStrictlyNewer() throws {
        let data = feed("""
        {
          "schema": 1,
          "version": "0.9.0-beta.2",
          "tag": "v0.9.0-beta.2",
          "channel": "beta",
          "dmg_url": "https://madi.devart.tv/releases/0.9.0-beta.2/madi-0.9.0-beta.2-arm64.dmg",
          "dmg_size": 123,
          "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        }
        """)
        let r = try ReleaseFeed.newest(from: data, current: SemVer("0.9.0-beta.1")!, channel: "beta")
        XCTAssertEqual(r?.version, SemVer("0.9.0-beta.2"))
        XCTAssertEqual(r?.tag, "v0.9.0-beta.2")
        XCTAssertEqual(r?.dmgURL.absoluteString, "https://madi.devart.tv/releases/0.9.0-beta.2/madi-0.9.0-beta.2-arm64.dmg")
        XCTAssertEqual(r?.dmgSize, 123)
        XCTAssertEqual(r?.sha256, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertEqual(r?.pageURL, AppVersion.releasesURL, "CloudFront feed keeps GitHub releases page as the human fallback")
    }

    func testNewestReturnsNilWhenFeedIsValidButNotNewer() throws {
        let data = feed("""
        {
          "schema": 1,
          "version": "0.9.0-beta.1",
          "tag": "v0.9.0-beta.1",
          "channel": "beta",
          "dmg_url": "https://madi.devart.tv/releases/0.9.0-beta.1/madi-0.9.0-beta.1-arm64.dmg",
          "dmg_size": 321,
          "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        }
        """)
        XCTAssertNil(try ReleaseFeed.newest(from: data, current: SemVer("0.9.0-beta.1")!, channel: "beta"),
                     "same version is not strictly newer")
    }

    func testNewestAcceptsSemVerEquivalentVersionAndTagForms() throws {
        let data = feed("""
        {
          "schema": 1,
          "version": "1.0.0",
          "tag": "v1.0.0",
          "channel": "stable",
          "dmg_url": "https://madi.devart.tv/releases/1.0.0/madi-1.0.0-arm64.dmg",
          "dmg_size": 999,
          "sha256": "1111111111111111111111111111111111111111111111111111111111111111"
        }
        """)
        let r = try ReleaseFeed.newest(from: data, current: SemVer("0.9.0-beta.1")!, channel: "stable")
        XCTAssertEqual(r?.tag, "v1.0.0")
    }

    func testNewestThrowsForInvalidJSON() {
        XCTAssertThrowsError(try ReleaseFeed.newest(from: feed("not json"), current: SemVer("1.0.0")!, channel: "stable")) {
            XCTAssertEqual($0 as? ReleaseFeedError, .invalidJSON)
        }
    }

    func testNewestThrowsForJSONObjectShapeMismatch() {
        let data = feed("""
        [{"schema":1}]
        """)
        XCTAssertThrowsError(try ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!, channel: "stable")) {
            XCTAssertEqual($0 as? ReleaseFeedError, .invalidJSON)
        }
    }

    func testNewestThrowsForUnsupportedSchema() {
        let data = feed("""
        {
          "schema": 2,
          "version": "1.2.0",
          "tag": "v1.2.0",
          "channel": "stable",
          "dmg_url": "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.dmg",
          "dmg_size": 7,
          "sha256": "2222222222222222222222222222222222222222222222222222222222222222"
        }
        """)
        XCTAssertThrowsError(try ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!, channel: "stable")) {
            XCTAssertEqual($0 as? ReleaseFeedError, .unsupportedSchema(2))
        }
    }

    func testNewestThrowsWhenVersionAndTagDoNotMatch() {
        let data = feed("""
        {
          "schema": 1,
          "version": "1.2.0",
          "tag": "v1.2.1",
          "channel": "stable",
          "dmg_url": "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.dmg",
          "dmg_size": 7,
          "sha256": "3333333333333333333333333333333333333333333333333333333333333333"
        }
        """)
        XCTAssertThrowsError(try ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!, channel: "stable")) {
            XCTAssertEqual(
                $0 as? ReleaseFeedError,
                .versionTagMismatch(version: "1.2.0", tag: "v1.2.1")
            )
        }
    }

    func testNewestThrowsWhenChannelDoesNotMatchRequestedChannel() {
        let data = feed("""
        {
          "schema": 1,
          "version": "1.2.0",
          "tag": "v1.2.0",
          "channel": "beta",
          "dmg_url": "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.dmg",
          "dmg_size": 7,
          "sha256": "4444444444444444444444444444444444444444444444444444444444444444"
        }
        """)
        XCTAssertThrowsError(try ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!, channel: "stable")) {
            XCTAssertEqual(
                $0 as? ReleaseFeedError,
                .wrongChannel(expected: "stable", actual: "beta")
            )
        }
    }

    func testNewestThrowsWhenDMGURLViolatesCloudFrontPolicy() {
        let badURLs = [
            "http://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.dmg",
            "https://example.com/releases/1.2.0/madi-1.2.0-arm64.dmg",
            "https://madi.devart.tv/downloads/1.2.0/madi-1.2.0-arm64.dmg",
            "https://madi.devart.tv/releases/9.9.9/madi-1.2.0-arm64.dmg",
            "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.zip",
            "https://madi.devart.tv/releases/1.2.0/Madi-1.2.0-arm64.dmg",
            "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-offline-arm64.dmg",
            "https://madi.devart.tv/releases/1.2.0/nested/madi-1.2.0-arm64.dmg",
            "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.dmg?source=other"
        ]

        for badURL in badURLs {
            let data = feed("""
            {
              "schema": 1,
              "version": "1.2.0",
              "tag": "v1.2.0",
              "channel": "stable",
              "dmg_url": "\(badURL)",
              "dmg_size": 7,
              "sha256": "5555555555555555555555555555555555555555555555555555555555555555"
            }
            """)
            XCTAssertThrowsError(try ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!, channel: "stable")) {
                XCTAssertEqual($0 as? ReleaseFeedError, .invalidDMGURL(badURL))
            }
        }
    }

    func testNewestThrowsWhenDMGSizeIsNotPositive() {
        let data = feed("""
        {
          "schema": 1,
          "version": "1.2.0",
          "tag": "v1.2.0",
          "channel": "stable",
          "dmg_url": "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.dmg",
          "dmg_size": 0,
          "sha256": "6666666666666666666666666666666666666666666666666666666666666666"
        }
        """)
        XCTAssertThrowsError(try ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!, channel: "stable")) {
            XCTAssertEqual($0 as? ReleaseFeedError, .invalidDMGSize(0))
        }
    }

    func testNewestThrowsWhenSHA256IsNotLowercase64Hex() {
        let digests = [
            "ABCDEFabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabc",
            "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcg"
        ]

        for digest in digests {
            let data = feed("""
            {
              "schema": 1,
              "version": "1.2.0",
              "tag": "v1.2.0",
              "channel": "stable",
              "dmg_url": "https://madi.devart.tv/releases/1.2.0/madi-1.2.0-arm64.dmg",
              "dmg_size": 7,
              "sha256": "\(digest)"
            }
            """)
            XCTAssertThrowsError(try ReleaseFeed.newest(from: data, current: SemVer("1.0.0")!, channel: "stable")) {
                XCTAssertEqual($0 as? ReleaseFeedError, .invalidSHA256(digest))
            }
        }
    }
}
