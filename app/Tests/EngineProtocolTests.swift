// EngineProtocolTests.swift — verify the stdout parser against real engine lines.
// Build standalone (no Xcode):
//   swiftc -parse-as-library Sovereign/Engine/EngineProtocol.swift \
//          Tests/EngineProtocolTests.swift -o /tmp/eptest && /tmp/eptest
// (the @main runner below makes it an executable that exits non-zero on failure)

import Foundation

@main
struct EngineProtocolTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond { failures += 1; print("FAIL: \(msg)") }
        }

        let d = EngineProtocol.Decoder()

        check(d.decode(line: "[stream] ready (model resident; feed ...)") == .ready,
              "ready line")

        // words only count inside the WORD TIMESTAMPS section
        check(d.decode(line: "=== WORD TIMESTAMPS ===") == .wordSectionBegin,
              "word section begin")
        if case .word(let t0, let t1, let w, let c) = d.decode(line: "[1.20s-1.85s] 안녕하세요") {
            check(abs(t0 - 1.20) < 1e-6 && abs(t1 - 1.85) < 1e-6 && w == "안녕하세요" && c == 1.0, "word parse (no conf → 1.0)")
        } else { failures += 1; print("FAIL: word not parsed") }

        // single-time word [t] (engine sometimes emits onset only)
        if case .word(let a, let b, let w, _) = d.decode(line: "[2.00s] hi") {
            check(abs(a - 2.0) < 1e-6 && abs(b - 2.0) < 1e-6 && w == "hi", "single-time word")
        } else { failures += 1; print("FAIL: single-time word") }

        // confidence suffix:  word  «conf 0.42»  → text without suffix, conf parsed
        if case .word(_, _, let w, let c) = d.decode(line: "[3.0s-3.4s] 섹스는  «conf 0.36»") {
            check(w == "섹스는" && abs(c - 0.36) < 1e-6, "word conf parse: got \"\(w)\" c=\(c)")
        } else { failures += 1; print("FAIL: word+conf not parsed") }

        // a non-word section closes the word context
        _ = d.decode(line: "=== TRANSCRIPTION (31.95s, 16 chunk(s)) ===")
        check(d.decode(line: "[1.0s-2.0s] should-be-other") == .other("[1.0s-2.0s] should-be-other"),
              "word ignored outside section")

        // speaker lines (with and without dur), order matters: SPKFIX/SPKOV before SPK
        check(d.decode(line: "SPK 12.34 2") == .speaker(.init(time: 12.34, id: 2, dur: 1.5)),
              "SPK no-dur defaults 1.5")
        check(d.decode(line: "SPKFIX 5.00 1 1.50") == .speakerFix(.init(time: 5.0, id: 1, dur: 1.5)),
              "SPKFIX with dur")
        check(d.decode(line: "SPKOV 17.00 5 0.90") == .speakerOverlap(.init(time: 17.0, id: 5, dur: 0.90)),
              "SPKOV with dur")

        check(d.decode(line: "<<FLUSH_END>>") == .flushEnd, "flush end")

        // perf/log noise → other
        check(d.decode(line: "[perf] chunk 1: ...") == .other("[perf] chunk 1: ..."),
              "perf line is other")

        if failures == 0 { print("✅ EngineProtocol: all checks passed") }
        else { print("❌ \(failures) failure(s)"); exit(1) }
    }
}
