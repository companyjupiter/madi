// TranslateStreamParserTests.swift — the framing state machine is replayed with
// the EXACT chunk shapes captured from a live engine run (timestamped pipe
// capture, 2026-07-03): control lines, token-by-token reply fragments, split
// UTF-8 sequences, and the "\n[perf] generation…\n> " terminator.

import XCTest
@testable import SovereignCore

final class TranslateStreamParserTests: XCTestCase {
    private func feed(_ p: inout TranslateStreamParser, _ s: String) -> [TranslateStreamParser.Event] {
        p.ingest(Data(s.utf8))
    }

    func testReadyThenFullTurnStreamsDeltas() {
        var p = TranslateStreamParser()
        XCTAssertEqual(feed(&p, "Loading model...\nInitializing Metal backend...\nREADY\n"),
                       [.ready])
        // prompt echo "> " + [chat] + prefill arrive as one chunk (observed shape)
        XCTAssertEqual(feed(&p, "> [chat] 58 tokens, prefilling...\n[perf] prefill: 58 tok in 238.3ms (243.4 tok/s)\n"),
                       [])
        // token-by-token reply fragments — each emits the accumulated text
        XCTAssertEqual(feed(&p, "レーザー"), [.replyDelta("レーザー")])
        XCTAssertEqual(feed(&p, "治療後"), [.replyDelta("レーザー治療後")])
        // terminator: reply's \n + generation line + next REPL prompt
        let done = feed(&p, "\n[perf] generation: 24 tok in 459.4ms (52.2 tok/s)\n> ")
        XCTAssertEqual(done, [.turnComplete("レーザー治療後")])
    }

    func testSplitUTF8SequenceIsHeldBack() {
        var p = TranslateStreamParser()
        _ = feed(&p, "READY\n[perf] prefill: 10 tok in 1ms (1 tok/s)\n")
        // '가' = EA B0 80 — split mid-character across chunks
        let bytes: [UInt8] = [0xEA, 0xB0]
        XCTAssertEqual(p.ingest(Data(bytes)), [])          // incomplete → no delta
        XCTAssertEqual(p.ingest(Data([0x80])), [.replyDelta("가")])
        let done = feed(&p, "\n[perf] generation: 1 tok in 1ms (1 tok/s)\n")
        XCTAssertEqual(done, [.turnComplete("가")])
    }

    func testIntraReplyNewlineJoinsWithSpace() {
        var p = TranslateStreamParser()
        _ = feed(&p, "READY\n[perf] prefill: 10 tok in 1ms (1 tok/s)\n")
        _ = feed(&p, "첫 줄")
        // a newline NOT followed by the generation marker = continuation
        let ev = feed(&p, "\n둘째 줄이 충분히 길어서 마커보다 깁니다")
        XCTAssertEqual(ev.last, .replyDelta("첫 줄 둘째 줄이 충분히 길어서 마커보다 깁니다"))
        let done = feed(&p, "\n[perf] generation: 9 tok in 1ms (9 tok/s)\n")
        XCTAssertEqual(done, [.turnComplete("첫 줄 둘째 줄이 충분히 길어서 마커보다 깁니다")])
    }

    func testSummaryModePreservesIntraReplyNewlines() {
        var p = TranslateStreamParser(preserveNewlines: true)
        _ = feed(&p, "READY\n[perf] prefill: 10 tok in 1ms (1 tok/s)\n")
        _ = feed(&p, "[요약] 첫 줄")
        let ev = feed(&p, "\n[액션] 둘째 줄이 충분히 길어서 마커보다 깁니다")
        XCTAssertEqual(ev.last, .replyDelta("[요약] 첫 줄\n[액션] 둘째 줄이 충분히 길어서 마커보다 깁니다"))
    }

    /// T1: the engine declares its capability tokens once, right before READY.
    /// `fp` gates the forced reply prefix — an engine without it must never be
    /// sent ` %%FP …`, so the tokens have to survive as a typed event.
    func testCapabilitiesControlEvent() {
        var p = TranslateStreamParser()
        XCTAssertEqual(feed(&p, "[caps] pfxcache fp\nREADY\n"),
                       [.capabilities(["pfxcache", "fp"]), .ready])
        // an older engine: pfxcache only
        var q = TranslateStreamParser()
        XCTAssertEqual(feed(&q, "> [caps] pfxcache\nREADY\n"),
                       [.capabilities(["pfxcache"]), .ready])
    }

    func testPrefixRegistrationControlEvent() {
        var p = TranslateStreamParser()
        XCTAssertEqual(feed(&p, "> PFX_OK 2 40\n"), [.prefixReady(2)])
    }

    func testEmptyReplyCompletesEmpty() {
        var p = TranslateStreamParser()
        _ = feed(&p, "READY\n[perf] prefill: 10 tok in 1ms (1 tok/s)\n")
        let done = feed(&p, "\n[perf] generation: 0 tok in 0ms (0 tok/s)\n")
        XCTAssertEqual(done, [.turnComplete("")])
    }

    func testSecondTurnAfterCompletion() {
        var p = TranslateStreamParser()
        _ = feed(&p, "READY\n")
        _ = feed(&p, "[perf] prefill: 5 tok in 1ms (5 tok/s)\nHola\n[perf] generation: 1 tok in 1ms (1 tok/s)\n> ")
        // the trailing "> " must not corrupt the next turn's [chat] line
        XCTAssertEqual(feed(&p, "[chat] 6 tokens, prefilling...\n[perf] prefill: 6 tok in 1ms (6 tok/s)\n"), [])
        XCTAssertEqual(feed(&p, "Bonjour"), [.replyDelta("Bonjour")])
        XCTAssertEqual(feed(&p, "\n[perf] generation: 1 tok in 1ms (1 tok/s)\n"),
                       [.turnComplete("Bonjour")])
    }

    // The engine's two skip paths used to `continue` with no output the parser
    // recognised, so the driver's request never completed and the DNA lane
    // wedged. They now emit the bare terminator (main.zig emitEmptyTurn). Bytes
    // below are the EXACT capture from a live 2B run, 2026-07-25.

    func testEmptyLineSkipTerminatesTheTurn() {
        var p = TranslateStreamParser()
        _ = feed(&p, "READY\n")
        XCTAssertEqual(feed(&p, "> [perf] generation: 0 tok in 0.0ms (0.0 tok/s)\n"),
                       [.turnComplete("")])
    }

    func testOverLongLineSkipTerminatesTheTurn() {
        var p = TranslateStreamParser()
        _ = feed(&p, "READY\n")
        let captured = "> [warn] input line exceeds 32768 bytes — raise SOV_MAX_SEQ (native 262144). Line skipped.\n"
                     + "[perf] generation: 0 tok in 0.0ms (0.0 tok/s)\n"
        XCTAssertEqual(feed(&p, captured), [.turnComplete("")])
    }

    /// The skip terminator must not leave the parser in reply mode — the next
    /// real turn has to frame normally.
    func testTurnAfterASkipStillFramesNormally() {
        var p = TranslateStreamParser()
        _ = feed(&p, "READY\n")
        XCTAssertEqual(feed(&p, "> [perf] generation: 0 tok in 0.0ms (0.0 tok/s)\n"),
                       [.turnComplete("")])
        _ = feed(&p, "> [chat] 6 tokens, prefilling...\n[perf] prefill: 6 tok in 1ms (6 tok/s)\n")
        XCTAssertEqual(feed(&p, "Hello"), [.replyDelta("Hello")])
        XCTAssertEqual(feed(&p, "\n[perf] generation: 1 tok in 1ms (1 tok/s)\n> "),
                       [.turnComplete("Hello")])
    }
}

final class TranslateRoutingTests: XCTestCase {
    func testScriptDetection() {
        XCTAssertEqual(TranslateRouting.scriptLang(of: "레이저 시술 후에는 세안을 피하세요"), "Korean")
        XCTAssertEqual(TranslateRouting.scriptLang(of: "施術のあと、どのくらいで赤みが引きますか"), "Japanese")
        XCTAssertEqual(TranslateRouting.scriptLang(of: "术后三天内请避免桑拿和剧烈运动"), "Chinese")
        XCTAssertEqual(TranslateRouting.scriptLang(of: "Please avoid saunas for three days"), "English")
        // KO with sprinkled hanja stays Korean
        XCTAssertEqual(TranslateRouting.scriptLang(of: "레이저 토닝 施術 후 관리"), "Korean")
        // numbers/punctuation only → ambiguous
        XCTAssertNil(TranslateRouting.scriptLang(of: "010-1234-5678"))
    }
}
