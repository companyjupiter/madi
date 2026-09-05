import XCTest
@testable import SovereignCore

/// P6: the exact lines the 0.3.9 live engine printed (captured via the tee shim),
/// which the app used to drop.
final class EngineDiagnosticsTests: XCTestCase {
    func testLiveCaptureLinesFoldIntoTheTag() {
        var d = EngineDiagnostics()
        for l in ["[prompt] biasing 3 word(s) → 5 tokens",
                  "[caps] preview-fp",
                  "[lang] locked token 50259 margin 2.60 after 1 probe(s) (en=50259 ko=50264)",
                  "[rescue] chunk 1: logprob — re-decoding with timestamp tokens",
                  "[rescue] chunk 1: logprob — re-decoding with timestamp tokens",
                  "[rescue] chunk 1: re-decode still degenerate — segment dropped",
                  "[loop-p2] chunk 1: period 4 x2 at 0 — truncated 437 → 4 tokens (shift 0 span 274/19 fr)",
                  "[loop-p2] chunk 1: period 9 x2 at 22 — kept, second copy advances (shift 47 span 74/61 fr)",
                  "[perf] chunk 1: conv 3ms | encoder 212ms"] { d.ingest(l) }
        XCTAssertEqual(d.tag, "eng lang=50259/2.60/1 prompt=3w/5t rescue=dropped:1,logprob:2 loopp2=1/1")
        XCTAssertEqual(d.recent.count, 7, "[caps] and [perf] are not diagnostics")
    }

    func testUnlockedAndEmpty() {
        var d = EngineDiagnostics()
        XCTAssertEqual(d.tag, "eng lang=unlocked/0 prompt=0 rescue=0 loopp2=0/0")
        d.ingest("[lang] probe 1 token 50259 margin 0.40 — below lock margin, staying open")
        XCTAssertEqual(d.tag, "eng lang=unlocked/1 prompt=0 rescue=0 loopp2=0/0")
    }

    func testRecentIsBounded() {
        var d = EngineDiagnostics()
        for i in 0..<40 { d.ingest("[rescue] chunk \(i): logprob — re-decoding with timestamp tokens") }
        XCTAssertEqual(d.recent.count, EngineDiagnostics.recentLimit)
        XCTAssertEqual(d.rescues["logprob"], 40)
    }
}
