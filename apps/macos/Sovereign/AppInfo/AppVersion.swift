// AppVersion.swift — single source of truth for the app's semantic version,
// release channel, and the BETA EXPIRY date, plus the pure logic behind them
// (SemVer parse/compare + expiry evaluation). Foundation-only so it lives in the
// headless SovereignCore test target — the comparator and the expiry latch are
// correctness-critical and unit-tested (Tests/SovereignCoreTests/AppVersionTests).
//
// Canonical values also live in Info.plist (CFBundleShortVersionString /
// MADIFullVersion / MADIChannel / MADIBetaExpiry) so build + packaging tooling
// can read them without compiling Swift; this file reads those keys at runtime
// with hardcoded fallbacks so `swift test` (test bundle, no app Info.plist) is
// deterministic.

import Foundation

// MARK: - Semantic version (semver.org 2.0.0 precedence)

/// A parsed semantic version. Build metadata (`+…`) is ignored in precedence,
/// per spec §10. Prerelease identifiers (`-beta.1`) order per §11: a version WITH
/// a prerelease is LOWER than the same core without one (1.0.0-beta < 1.0.0).
struct SemVer: Comparable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    /// Prerelease identifiers split on '.', empty for a normal release.
    let prerelease: [Identifier]

    enum Identifier: Comparable, Equatable {
        case numeric(Int)
        case alpha(String)

        // §11.4: numeric identifiers always have LOWER precedence than
        // alphanumeric; numerics compare numerically, alphas lexically (ASCII).
        static func < (a: Identifier, b: Identifier) -> Bool {
            switch (a, b) {
            case let (.numeric(x), .numeric(y)): return x < y
            case let (.alpha(x), .alpha(y)):     return x < y
            case (.numeric, .alpha):             return true
            case (.alpha, .numeric):             return false
            }
        }
    }

    /// Parse a tag or version string. Tolerant: a leading `v`/`V` is stripped,
    /// missing minor/patch default to 0, build metadata is dropped. Returns nil
    /// only when the core has no leading integer at all.
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let f = s.first, f == "v" || f == "V" { s.removeFirst() }
        // strip build metadata (+…) — not part of precedence
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }
        // split core vs prerelease on the FIRST hyphen
        let coreStr: Substring
        let preStr: Substring?
        if let dash = s.firstIndex(of: "-") {
            coreStr = s[s.startIndex..<dash]
            preStr = s[s.index(after: dash)...]
        } else {
            coreStr = Substring(s)
            preStr = nil
        }
        let parts = coreStr.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let maj = Int(first) else { return nil }
        self.major = maj
        self.minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        self.patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        if let pre = preStr, !pre.isEmpty {
            self.prerelease = pre.split(separator: ".", omittingEmptySubsequences: false).map { tok in
                if let n = Int(tok), !tok.isEmpty, tok.allSatisfy({ $0.isNumber }) {
                    return .numeric(n)
                }
                return .alpha(String(tok))
            }
        } else {
            self.prerelease = []
        }
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // §11.3: no-prerelease > has-prerelease
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true):  return false           // equal cores, both releases
        case (true, false): return false           // a is release, b is pre → a > b
        case (false, true): return true            // a is pre, b is release → a < b
        case (false, false):
            // compare identifier by identifier; more fields wins if all equal
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                return x < y
            }
            return a.prerelease.count < b.prerelease.count
        }
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return core }
        let pre = prerelease.map {
            switch $0 { case .numeric(let n): return String(n); case .alpha(let s): return s }
        }.joined(separator: ".")
        return "\(core)-\(pre)"
    }
}

// MARK: - Beta expiry status

/// Where the beta is in its lifecycle relative to the hard expiry date.
enum ExpiryStatus: Equatable {
    case active                          // outside the warning window
    case expiringSoon(daysLeft: Int)     // within warningDays of expiry (>= 0)
    case expired                         // at or past expiry (or latched expired)
}

// MARK: - App version + channel + expiry (single source of truth)

enum AppVersion {
    /// Fallbacks used when the Info.plist keys are absent (e.g. the headless
    /// test bundle). Keep in lockstep with Info.plist.
    static let fallbackFull = "0.1.0"
    static let fallbackMarketing = "0.1.0"
    static let fallbackChannel = "stable"

    /// GitHub repo the updater queries. owner/name.
    static let repoOwner = "companyjupiter"
    static let repoName = "madi"

    /// Days before expiry that the in-app warning banner starts showing.
    static let warningDays = 14

    /// UserDefaults key for the monotonic "highest wall-clock ever observed",
    /// used to latch expiry against a naive clock-rollback.
    static let highWaterKey = "MADIBetaHighWaterEpoch"

    /// Full semver INCLUDING prerelease (e.g. "0.9.0-beta.1"). Info.plist
    /// `MADIFullVersion`, else fallback.
    static var full: String {
        (Bundle.main.object(forInfoDictionaryKey: "MADIFullVersion") as? String) ?? fallbackFull
    }

    /// Marketing version — numeric CFBundleShortVersionString (e.g. "0.9.0").
    static var marketing: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackMarketing
    }

    /// Build number — CFBundleVersion (e.g. "1").
    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    /// Release channel string: "beta" | "rc" | "stable". Info.plist `MADIChannel`.
    static var channel: String {
        (Bundle.main.object(forInfoDictionaryKey: "MADIChannel") as? String) ?? fallbackChannel
    }

    /// Bundle identifier (CFBundleIdentifier), for the Info window.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.companyjupiter.madi"
    }

    static var isBeta: Bool { channel.lowercased() == "beta" }

    /// Parsed current version for comparison against release tags.
    static var current: SemVer { SemVer(full) ?? SemVer("0.0.0")! }

    /// The hard beta-expiry instant. Info.plist `MADIBetaExpiry` ("yyyy-MM-dd",
    /// interpreted as LOCAL midnight), else 2026-12-01 local.
    static let betaExpiryDate: Date = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "MADIBetaExpiry") as? String,
           let d = parseDay(s) { return d }
        var c = DateComponents(); c.year = 2026; c.month = 12; c.day = 1
        return Calendar.current.date(from: c) ?? .distantFuture
    }()

    /// Parse a "yyyy-MM-dd" day into that day's LOCAL midnight.
    static func parseDay(_ s: String, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    // MARK: expiry evaluation

    /// PURE expiry decision — no I/O, fully unit-tested.
    /// - `highWater`: the max wall-clock ever persisted from prior launches.
    ///   If it is at/after `expiry`, we stay expired even when `now` was rolled
    ///   back before `expiry` (defeats a trivial "set the clock back" bypass).
    static func expiryStatus(now: Date,
                             expiry: Date,
                             highWater: Date?,
                             warningDays: Int = AppVersion.warningDays,
                             calendar: Calendar = .current) -> ExpiryStatus {
        let effectiveNow = max(now, highWater ?? now)
        if effectiveNow >= expiry { return .expired }
        let startNow = calendar.startOfDay(for: now)
        let startExp = calendar.startOfDay(for: expiry)
        let days = calendar.dateComponents([.day], from: startNow, to: startExp).day ?? Int.max
        if days <= warningDays { return .expiringSoon(daysLeft: max(0, days)) }
        return .active
    }

    /// Runtime wrapper: reads + advances the persisted high-water mark in
    /// `defaults`, then returns the status for `betaExpiryDate`. Side-effecting
    /// (persists max(now, stored)); tests exercise `expiryStatus` directly.
    @discardableResult
    static func evaluateExpiry(now: Date = Date(),
                               defaults: UserDefaults = .standard) -> ExpiryStatus {
        let stored = (defaults.object(forKey: highWaterKey) as? Double)
        let highWater = stored.map { Date(timeIntervalSince1970: $0) }
        let status = expiryStatus(now: now, expiry: betaExpiryDate, highWater: highWater)
        let newHW = max(now.timeIntervalSince1970, stored ?? now.timeIntervalSince1970)
        defaults.set(newHW, forKey: highWaterKey)
        return status
    }

    /// The public download/support page users are sent to when the beta expires
    /// or an update is offered but no DMG asset is attached.
    static var releasesURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases")!
    }
}

// MARK: - GitHub Releases feed (pure parsing — unit-tested)

/// A release candidate parsed from the GitHub Releases API.
struct ReleaseInfo: Equatable {
    let version: SemVer
    let tag: String
    let notes: String          // release body (markdown)
    let pageURL: URL           // html_url — the release page
    let dmgURL: URL?           // browser_download_url of the .dmg asset, if any
    let dmgSize: Int64
}

enum ReleaseFeed {
    /// Decode the `/releases` JSON array and return the highest-SemVer release
    /// strictly newer than `current`, or nil if none is. Drafts are skipped;
    /// prereleases are KEPT (this is a beta channel — a newer beta or a stable
    /// build both outrank the current build by the same comparator).
    static func newest(from data: Data, current: SemVer) -> ReleaseInfo? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var best: ReleaseInfo?
        for obj in arr {
            if (obj["draft"] as? Bool) == true { continue }
            guard let tag = obj["tag_name"] as? String, let ver = SemVer(tag) else { continue }
            let notes = (obj["body"] as? String) ?? ""
            let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
                ?? AppVersion.releasesURL
            var dmgURL: URL?
            var dmgSize: Int64 = 0
            if let assets = obj["assets"] as? [[String: Any]] {
                // A release may also contain the much larger offline DMG. The
                // in-app updater must prefer the standard installer regardless
                // of the order returned by GitHub.
                let dmgAssets = assets.filter {
                    (($0["name"] as? String)?.lowercased().hasSuffix(".dmg")) == true
                }
                let selected = dmgAssets.first {
                    (($0["name"] as? String)?.lowercased().contains("offline")) == false
                } ?? dmgAssets.first
                if let a = selected,
                   let urlStr = a["browser_download_url"] as? String,
                   let url = URL(string: urlStr) {
                    dmgURL = url
                    if let n = a["size"] as? Int64 { dmgSize = n }
                    else if let n = a["size"] as? Int { dmgSize = Int64(n) }
                }
            }
            let info = ReleaseInfo(version: ver, tag: tag, notes: notes,
                                   pageURL: page, dmgURL: dmgURL, dmgSize: dmgSize)
            if info.version > current, best == nil || info.version > best!.version {
                best = info
            }
        }
        return best
    }
}
