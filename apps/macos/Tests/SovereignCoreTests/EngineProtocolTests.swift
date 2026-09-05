// EngineProtocolTests — the stdout line decoder that turns the engine's text
// stream into typed EngineEvents. Pure + stateful; GUI-free.
import XCTest
@testable import SovereignCore

final class EngineProtocolTests: XCTestCase {

    func testDecodesControlLines() {
        let d = EngineProtocol.Decoder()
        XCTAssertEqual(d.decode(line: "[stream] ready"), .ready)
        XCTAssertEqual(d.decode(line: "<<FLUSH_END>>"), .flushEnd)
        XCTAssertEqual(d.decode(line: "SPKOVRESET"), .speakerOverlapReset)
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

    func testSpeakerLabelWithMarginField() {
        // S2: 5th field = acoustic margin; older engines omit it (default 1.0)
        XCTAssertEqual(EngineProtocol.parseSpeaker("SPK 12.50 1 1.50 0.27", tag: "SPK"),
                       SpeakerLabel(time: 12.5, id: 1, dur: 1.5, margin: 0.27))
        XCTAssertEqual(EngineProtocol.parseSpeaker("SPK 12.50 1 1.50", tag: "SPK"),
                       SpeakerLabel(time: 12.5, id: 1, dur: 1.5, margin: 1.0))
        XCTAssertEqual(EngineProtocol.parseSpeaker("SPKFIX 3.00 0 0.80 0.44", tag: "SPKFIX"),
                       SpeakerLabel(time: 3.0, id: 0, dur: 0.8, margin: 0.44))
    }

    func testDecodesSegmentEnd() {
        let d = EngineProtocol.Decoder()
        XCTAssertEqual(d.decode(line: "<<SEG_END>>"), .segmentEnd)
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

    func testPreviewLaneIsolatesTextAndRestoresCommittedParsing() {
        let d = EngineProtocol.Decoder()
        XCTAssertEqual(d.decode(line: "<<PREVIEW_BEGIN>>"), .previewBegin)
        XCTAssertEqual(d.decode(line: "«partial 0.00» 미리 보기"), .previewPartial("미리 보기"))
        if case .other = d.decode(line: "=== WORD TIMESTAMPS ===") { } else {
            XCTFail("preview word section must not look committed")
        }
        XCTAssertEqual(d.decode(line: "[0.10s-0.50s] 안녕하세요  «conf 0.91»"),
                       .previewWord("안녕하세요"))
        // Even if a future engine accidentally emits session state inside the
        // markers, the decoder must quarantine it from SessionController.
        if case .other = d.decode(line: "SPK 0.00 7 1.50") { } else {
            XCTFail("preview speaker state escaped its lane")
        }
        if case .other = d.decode(line: "[lang] detected token 50264 (en=50259 ko=50264)") { } else {
            XCTFail("preview language state escaped its lane")
        }
        if case .other = d.decode(line: "<<SEG_END>>") { } else {
            XCTFail("preview job spoofed a committed segment barrier")
        }
        XCTAssertEqual(d.decode(line: "<<PREVIEW_END>>"), .previewEnd)
        XCTAssertEqual(d.decode(line: "=== WORD TIMESTAMPS ==="), .wordSectionBegin)
        XCTAssertEqual(d.decode(line: "[1.00s-1.40s] committed"),
                       .word(t0: 1.0, t1: 1.4, text: "committed", conf: 1.0))
    }
}

/// P6: the 0.3.8 engine renamed the lock line; the parser must accept both, or the
/// preview lane never starts (0.3.9 capture: 48 SEG commands, 0 PREVIEW).
extension EngineProtocolTests {
    func testLanguageLockLineBothWordings() {
        let d = EngineProtocol.Decoder()
        XCTAssertEqual(d.decode(line: "[lang] detected token 50264 (en=50259 ko=50264)"), .languageDetected(50264))
        XCTAssertEqual(d.decode(line: "[lang] locked token 50259 margin 2.60 after 1 probe(s) (en=50259 ko=50264)"), .languageDetected(50259))
        XCTAssertEqual(d.decode(line: "[lang] probe 1 token 50259 margin 0.40 — below lock margin, staying open"), .other("[lang] probe 1 token 50259 margin 0.40 — below lock margin, staying open"))
    }
}
