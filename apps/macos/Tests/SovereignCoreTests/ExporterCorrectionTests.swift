import XCTest
@testable import SovereignCore

final class ExporterCorrectionTests: XCTestCase {
    private func editedLine() -> Line {
        Line(id: UUID(), speaker: 0, start: 1, end: 3,
             words: [Word(t0: 1, t1: 2, text: "raw"), Word(t0: 2, t1: 3, text: "ASR")],
             translations: ["Korean": "교정된 번역"], editedText: "corrected source")
    }

    func testEveryTextExporterUsesCorrectedSource() {
        let line = editedLine()
        XCTAssertTrue(Exporters.markdown([line]).contains("corrected source"))
        XCTAssertFalse(Exporters.markdown([line]).contains("raw ASR"))
        XCTAssertTrue(Exporters.srt([line]).contains("corrected source"))
        XCTAssertFalse(Exporters.srt([line]).contains("raw ASR"))
        XCTAssertTrue(Exporters.vtt([line]).contains("corrected source"))
        XCTAssertTrue(Exporters.plainText([line]).contains("corrected source"))
    }

    func testJSONIncludesTranslationsAndCorrectedSource() throws {
        let data = Data(Exporters.json([editedLine()]).utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(root["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["text"] as? String, "corrected source")
        XCTAssertEqual((segments.first?["translations"] as? [String: String])?["Korean"], "교정된 번역")
    }
}
