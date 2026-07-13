// TranscriptArchiveTests — the .md → [Line] parser that re-opens an archived
// transcript from the workspace explorer. Inverse of Exporters.markdown; GUI-free.
import XCTest
@testable import SovereignCore

final class TranscriptArchiveTests: XCTestCase {

    /// A canonical export: header + legend + two bullet lines, one named speaker
    /// and one "Speaker N", with a low-confidence italic word and an overlap mark.
    private let sample = """
    # Transcript

    > *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.

    - **[00:03] 김부장** 안녕하세요 *반갑습니다* ⟨+Speaker 1 겹침⟩
    - **[01:09] Speaker 1** 네 시작하죠
    """

    func testParsesLinesTimecodesAndText() {
        let p = TranscriptArchive.parse(text: sample)
        XCTAssertNotNil(p)
        guard let p else { return }
        XCTAssertEqual(p.lines.count, 2)
        XCTAssertEqual(p.lines[0].start, 3, accuracy: 1e-9)     // 00:03
        XCTAssertEqual(p.lines[1].start, 69, accuracy: 1e-9)    // 01:09
        // first line end = next line's start (derived span)
        XCTAssertEqual(p.lines[0].end, 69, accuracy: 1e-9)
        XCTAssertTrue(p.lines[0].text.contains("안녕하세요"))
        XCTAssertTrue(p.lines[0].text.contains("반갑습니다"))  // italics stripped
        XCTAssertFalse(p.lines[0].text.contains("*"))          // no stray asterisks
        XCTAssertFalse(p.lines[0].text.contains("겹침"))       // overlap marker stripped
    }

    func testSpeakerIdsAndNames() {
        guard let p = TranscriptArchive.parse(text: sample) else { return XCTFail() }
        // "Speaker 1" keeps id 1; the named speaker is allocated above it (id 2).
        XCTAssertEqual(p.lines[1].speaker, 1)
        XCTAssertEqual(p.names[p.lines[0].speaker], "김부장")
        XCTAssertNil(p.names[1])                                // "Speaker 1" → no custom name
        XCTAssertGreaterThan(p.lines[0].speaker, 1)            // named id reserved above Speaker 1
    }

    func testLowConfidenceItalicRoundTrips() {
        guard let p = TranscriptArchive.parse(text: sample) else { return XCTFail() }
        let flagged = p.lines[0].words.filter { $0.conf < 0.55 }   // Theme.n threshold
        XCTAssertEqual(flagged.count, 1)
        XCTAssertEqual(flagged.first?.text, "반갑습니다")
        // plain words stay full-confidence
        XCTAssertTrue(p.lines[0].words.contains { $0.text == "안녕하세요" && $0.conf >= 0.99 })
    }

    func testNonTranscriptReturnsNil() {
        XCTAssertNil(TranscriptArchive.parse(text: "# Notes\n\njust prose, no bullets"))
        XCTAssertNil(TranscriptArchive.parse(text: ""))
    }

    func testTranslationsRoundTripThroughCanonicalMarkdown() {
        let line = Line(id: UUID(), speaker: 0, start: 3, end: 5,
                        words: [Word(t0: 3, t1: 5, text: "안녕하세요")],
                        translations: ["English": "Hello", "Japanese": "こんにちは"])
        let markdown = Exporters.markdown([line])
        guard let parsed = TranscriptArchive.parse(text: markdown) else { return XCTFail() }
        XCTAssertEqual(parsed.lines.first?.translations["English"], "Hello")
        XCTAssertEqual(parsed.lines.first?.translations["Japanese"], "こんにちは")
    }
}
