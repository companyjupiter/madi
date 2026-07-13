import XCTest
@testable import SovereignCore

final class EngineEventsTests: XCTestCase {
    func testDecodeCarriesCorrectionEvidence() {
        let raw = #"{"t":"seg","idx":7,"t0":10.0,"t1":14.0,"avg_logprob":-1.31,"fallback":"logprob","tok_s":42,"enc_ms":80,"dec_ms":300,"passes":2,"dropped":false,"text":"x"}"#
        guard case .segment(let info) = EngineEvents.decode(line: raw) else { return XCTFail() }
        XCTAssertEqual(info.idx, 7)
        XCTAssertEqual(info.avgLogprob, -1.31, accuracy: 0.001)
        XCTAssertEqual(info.fallback, "logprob")
        XCTAssertEqual(info.passes, 2)
    }
}
