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

    func testDecodesSpeakerNameMatch() {
        let d = EngineProtocol.Decoder()
        // "SPKNAME <id> <name>" — a live speaker matched an enrolled voiceprint
        XCTAssertEqual(d.decode(line: "SPKNAME 2 김 부장"), .speakerName(id: 2, name: "김 부장"))
        // must NOT be mis-parsed as a SPK speaker label
        if case .speaker = d.decode(line: "SPKNAME 0 Alice") { XCTFail("SPKNAME parsed as SPK") }
    }

    func testUnknownLineIsOther() {
        let d = EngineProtocol.Decoder()
        if case .other = d.decode(line: "[perf] some diagnostic noise") { } else {
            XCTFail("unrecognized non-progress lines should decode to .other")
        }
    }

    func testDecodesPartialHypothesis() {
        let d = EngineProtocol.Decoder()
        // «partial <t0>» <text> — streaming in-decode hypothesis (PARTIALS=1)
        XCTAssertEqual(d.decode(line: "«partial 12.50» 안녕하세요 오늘은"),
                       .partial(t0: 12.5, text: "안녕하세요 오늘은"))
        // malformed (no closing guillemet) must not crash → .other
        if case .other = d.decode(line: "«partial 12.50 안녕") { } else {
            XCTFail("malformed partial should decode to .other")
        }
    }
}
