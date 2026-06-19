// EngineProtocolTests — the stdout line decoder that turns the engine's text
// stream into typed EngineEvents. Pure + stateful; GUI-free.
import XCTest
@testable import SovereignCore

final class EngineProtocolTests: XCTestCase {

    func testDecodesControlLines() {
        let d = EngineProtocol.Decoder()
        XCTAssertEqual(d.decode(line: "[stream] ready"), .ready)
        XCTAssertEqual(d.decode(line: "<<FLUSH_END>>"), .flushEnd)
    }

    func testDecodesFileModeProgressTotal() {
        let d = EngineProtocol.Decoder()
        // "[8] audio: … → N chunk(s) …" → progressTotal(N)
        XCTAssertEqual(d.decode(line: "[8] audio: 12.3s → 5 chunk(s) @16k"), .progressTotal(5))
    }

    func testUnknownLineIsOther() {
        let d = EngineProtocol.Decoder()
        if case .other = d.decode(line: "[perf] some diagnostic noise") { } else {
            XCTFail("unrecognized non-progress lines should decode to .other")
        }
    }
}
