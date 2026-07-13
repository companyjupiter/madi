import XCTest
@testable import SovereignCore

/// Engine → Transcript → multi-translation correction → export/archive.
/// This keeps the user-visible result contract covered without SwiftUI or a model download.
@MainActor
final class CorrectionPipelineE2ETests: XCTestCase {
    func testCorrectedSessionSurvivesFinalizationAndEveryCanonicalOutput() throws {
        let decoder = EngineProtocol.Decoder()
        let store = TranscriptStore()

        store.ingest(decoder.decode(line: "SPK 0.0 3 2.0 0.20"))
        store.ingest(decoder.decode(line: "=== WORD TIMESTAMPS ==="))
        store.ingest(decoder.decode(line: "[0.00s-1.00s] 소버림"))

        let lineID = try XCTUnwrap(store.lines.first?.id)
        let rawRevision = try XCTUnwrap(store.sourceRevision(for: lineID))
        XCTAssertTrue(store.setTranslation(lineID, lang: "English", "Soverim", sourceRevision: rawRevision))

        XCTAssertTrue(store.editLine(lineID, "소버린", expectedRevision: rawRevision))
        XCTAssertFalse(store.setTranslation(lineID, lang: "English", "stale model result",
                                             sourceRevision: rawRevision))
        store.mergeSpeaker(from: 3, into: 1)
        store.finalize()

        let correctedRevision = try XCTUnwrap(store.sourceRevision(for: lineID))
        XCTAssertTrue(store.setTranslation(lineID, lang: "English", "Sovereign",
                                           sourceRevision: correctedRevision))
        XCTAssertTrue(store.setTranslation(lineID, lang: "Japanese", "ソブリン",
                                           sourceRevision: correctedRevision))
        XCTAssertTrue(store.editTranslation(lineID, lang: "English", "Sovereign AI"))

        let lines = store.lines
        let names = [1: "Jupiter"]
        XCTAssertEqual(lines.first?.speaker, 1)
        XCTAssertEqual(lines.first?.text, "소버린")
        XCTAssertEqual(lines.first?.translations["English"], "Sovereign AI")
        XCTAssertEqual(lines.first?.translations["Japanese"], "ソブリン")
        XCTAssertTrue(lines.first?.editedTranslations.contains("English") == true)

        let markdown = Exporters.markdown(lines, names: names)
        for output in [markdown, Exporters.srt(lines, names: names), Exporters.vtt(lines, names: names)] {
            XCTAssertTrue(output.contains("소버린"))
            XCTAssertFalse(output.contains("소버림"))
            XCTAssertFalse(output.contains("stale model result"))
        }

        let archived = try XCTUnwrap(TranscriptArchive.parse(text: markdown))
        XCTAssertEqual(archived.lines.first?.text, "소버린")
        XCTAssertEqual(archived.lines.first?.translations["English"], "Sovereign AI")
        XCTAssertEqual(archived.lines.first?.translations["Japanese"], "ソブリン")
        XCTAssertTrue(archived.names.values.contains("Jupiter"))

        let jsonData = Data(Exporters.json(lines, names: names).utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let segments = try XCTUnwrap(root["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.first?["text"] as? String, "소버린")
        XCTAssertEqual(segments.first?["name"] as? String, "Jupiter")
        XCTAssertEqual((segments.first?["translations"] as? [String: String])?["English"], "Sovereign AI")
    }
}
