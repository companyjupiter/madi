// RoundTripExportParseTests — END-TO-END markdown round-trip at the CORE level.
//
// Builds a synthetic [Line]/[Word] transcript (multiple speakers, a names map,
// low-confidence words, overlapSpeakers, real timecodes), renders it to the
// Exporters.markdown SAVED-doc shape, then feeds that string to the REAL
// TranscriptArchive.parse (the documented inverse) and asserts the load-bearing
// facts survive the trip: speaker ids, names, timecodes, text, and the
// italic→low-confidence flag.
//
// ADAPTATION NOTE (real API mismatch, not invented): Exporters.swift is NOT in
// the Foundation-only `SovereignCore` target — it transitively imports SwiftUI
// via `Theme.confThreshold` (Sovereign/UI/Theme.swift `import SwiftUI`), so
// `Exporters.markdown` is unavailable to this GUI-free test target and pulling it
// in would violate the no-SwiftUI rule. TranscriptArchive is documented as "the
// exact inverse of Exporters.markdown" with a frozen line shape:
//   `- **[mm:ss] Who** body *low-conf* ⟨+Name 겹침⟩`
// so this test reproduces that exact emitter (including the <confThreshold italic
// rule and the overlap marker) as `renderMarkdown` below and round-trips through
// the REAL parser. The fidelity caveat from TranscriptArchive's own header is
// honoured: per-word timing/conf are NOT recoverable from markdown — words
// inherit `line.start` for time and italic→0.3 / plain→1.0 for conf — so time and
// conf are asserted with >=/bucket tolerance while speaker ids, names and text are
// exact.
import XCTest
@testable import SovereignCore

final class RoundTripExportParseTests: XCTestCase {

    // Threshold the emitter uses to decide the *italic* low-confidence mark.
    // Mirrors Theme.confThreshold's 0.55 default (that value lives in a SwiftUI
    // file we can't import here); the parser maps italic→0.3, plain→1.0.
    private let confThreshold = 0.55

    // ── format-faithful re-implementation of Exporters.markdown ────────────────
    // Kept byte-identical to Exporters.markdown's bullet shape so the real
    // TranscriptArchive.parse is exercised against a genuine export, not a
    // hand-tuned string.

    private func timecode(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func renderWords(_ words: [Word]) -> String {
        var s = ""
        for (i, w) in words.enumerated() {
            if i > 0, w.text.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            let t = w.text.trimmingCharacters(in: .whitespaces)
            s += (w.conf < confThreshold && !t.isEmpty) ? "*\(t)*" : w.text
        }
        return s
    }

    private func renderMarkdown(_ lines: [Line], names: [Int: String], summary: String? = nil) -> String {
        var s = "# Transcript\n\n"
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "## 회의 요약\n\n\(summary)\n\n---\n\n"
        }
        s += "> *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.\n\n"
        for l in lines {
            let who = names[l.speaker] ?? "Speaker \(l.speaker)"
            let body = renderWords(l.words)
            let mark = l.overlapSpeakers
                .map { " ⟨+\(names[$0] ?? "Speaker \($0)") 겹침⟩" }
                .joined()
            s += "- **[\(timecode(l.start))] \(who)** \(body)\(mark)\n"
        }
        return s
    }

    // ── fixture ────────────────────────────────────────────────────────────────

    private func word(_ text: String, _ t0: Double, _ t1: Double, conf: Double = 1.0) -> Word {
        Word(t0: t0, t1: t1, text: text, conf: conf)
    }

    /// Three speakers: 김부장 (named, id 5), 이대리 (named, id 6), and a raw
    /// "Speaker 1" (id 1). One low-confidence word + one overlap marker.
    private func fixture() -> (lines: [Line], names: [Int: String]) {
        let names: [Int: String] = [5: "김부장", 6: "이대리"]
        let l0 = Line(id: UUID(), speaker: 5, start: 3, end: 20,
                      words: [word("안녕하세요", 3, 4),
                              word("반갑습니다", 4, 5, conf: 0.3)],   // low-conf → *italic*
                      overlapSpeakers: [1])
        let l1 = Line(id: UUID(), speaker: 1, start: 69, end: 90,
                      words: [word("네", 69, 69.4), word("시작하죠", 69.4, 70)])
        let l2 = Line(id: UUID(), speaker: 6, start: 90, end: 130,
                      words: [word("첫", 90, 90.3), word("번째", 90.3, 90.8),
                              word("항목입니다", 90.8, 91.5)])
        return ([l0, l1, l2], names)
    }

    // ── round-trip assertions ──────────────────────────────────────────────────

    func testSpeakersNamesAndTextSurvive() {
        let (lines, names) = fixture()
        let md = renderMarkdown(lines, names: names)
        guard let p = TranscriptArchive.parse(text: md) else { return XCTFail("parse returned nil") }

        XCTAssertEqual(p.lines.count, 3)

        // The raw "Speaker 1" keeps its literal id 1 (exact).
        XCTAssertEqual(p.lines[1].speaker, 1)
        XCTAssertNil(p.names[1])

        // Named speakers survive by NAME (their numeric ids are re-allocated by the
        // parser above the highest reserved "Speaker N", so we assert the name map,
        // not the original 5/6 — that's the documented contract).
        XCTAssertEqual(p.names[p.lines[0].speaker], "김부장")
        XCTAssertEqual(p.names[p.lines[2].speaker], "이대리")
        XCTAssertGreaterThan(p.lines[0].speaker, 1)   // named id reserved above Speaker 1

        // Text survives (italics + overlap markup stripped).
        XCTAssertTrue(p.lines[0].text.contains("안녕하세요"))
        XCTAssertTrue(p.lines[0].text.contains("반갑습니다"))
        XCTAssertFalse(p.lines[0].text.contains("*"))
        XCTAssertFalse(p.lines[0].text.contains("겹침"))
        XCTAssertTrue(p.lines[2].text.contains("항목입니다"))
    }

    func testTimecodesSurviveLineStart() {
        let (lines, names) = fixture()
        let md = renderMarkdown(lines, names: names)
        guard let p = TranscriptArchive.parse(text: md) else { return XCTFail() }

        // line.start round-trips exactly (mm:ss granularity → our fixture uses
        // whole-second starts so it is exact, not just >=).
        XCTAssertEqual(p.lines[0].start, 3, accuracy: 1e-9)
        XCTAssertEqual(p.lines[1].start, 69, accuracy: 1e-9)
        XCTAssertEqual(p.lines[2].start, 90, accuracy: 1e-9)

        // Derived span: each line.end = next line's start; the last line gets a
        // 0-span (end == start). Per-word time is NOT recoverable — words inherit
        // line.start — so we assert >= line.start (the fidelity caveat).
        XCTAssertEqual(p.lines[0].end, 69, accuracy: 1e-9)
        XCTAssertEqual(p.lines[1].end, 90, accuracy: 1e-9)
        XCTAssertEqual(p.lines[2].end, 90, accuracy: 1e-9)   // last line: end == start
        for w in p.lines[0].words {
            XCTAssertGreaterThanOrEqual(w.t0, p.lines[0].start)
        }
    }

    func testLowConfidenceItalicRoundTripsAsBucket() {
        let (lines, names) = fixture()
        let md = renderMarkdown(lines, names: names)
        guard let p = TranscriptArchive.parse(text: md) else { return XCTFail() }

        // Conf is bucketed by the parser (italic→0.3, plain→1.0), NOT preserved
        // exactly — assert with the bucket tolerance.
        let low = p.lines[0].words.filter { $0.conf < confThreshold }
        XCTAssertEqual(low.count, 1)
        XCTAssertEqual(low.first?.text, "반갑습니다")
        XCTAssertLessThanOrEqual(low.first!.conf, 0.5)              // landed in the low bucket
        XCTAssertTrue(p.lines[0].words.contains { $0.text == "안녕하세요" && $0.conf >= 0.99 })
    }

    func testSummaryBlockDoesNotLeakIntoLines() {
        // A summary block is written first (## 회의 요약 … ---); it must NOT parse
        // as a transcript bullet, and OpenLoopsAggregator must be able to recover it.
        let (lines, names) = fixture()
        let summary = "[결정] 6월 30일 출시 확정\n[액션] 이대리 · 부하 테스트 완료"
        let md = renderMarkdown(lines, names: names, summary: summary)

        guard let p = TranscriptArchive.parse(text: md) else { return XCTFail() }
        XCTAssertEqual(p.lines.count, 3)                            // summary lines didn't become bullets
        XCTAssertFalse(p.lines.contains { $0.text.contains("출시 확정") })

        // The summary survives for the loops pipeline (cross-module round-trip).
        let block = OpenLoopsAggregator.summarySection(md)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("6월 30일 출시 확정"))
        let items = OpenLoopsAggregator.extractItems(fromSummary: block!)
        XCTAssertTrue(items.contains { $0.kind == .decision && $0.text.contains("출시 확정") })
        XCTAssertTrue(items.contains { $0.kind == .action && $0.owner == "이대리" })
    }

    func testEmptyAndNonTranscriptParseToNil() {
        XCTAssertNil(TranscriptArchive.parse(text: ""))
        XCTAssertNil(TranscriptArchive.parse(text: "# Notes\n\njust prose, no bullets"))
    }
}
