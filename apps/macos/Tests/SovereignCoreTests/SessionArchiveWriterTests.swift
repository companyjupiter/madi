import XCTest
@testable import SovereignCore

@MainActor
final class SessionArchiveWriterTests: XCTestCase {
    func testCheckpointsShareOneFileAndResetAllocatesAnother() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SessionArchiveWriter()
        XCTAssertTrue(writer.saveTranscript("first", folder: folder, base: "meeting"))
        let first = try XCTUnwrap(writer.transcriptURL)
        XCTAssertTrue(writer.saveTranscript("final", folder: folder, base: "different"))
        XCTAssertEqual(writer.transcriptURL, first)
        XCTAssertEqual(try String(contentsOf: first), "final")
        writer.reset()
        XCTAssertTrue(writer.saveTranscript("next", folder: folder, base: "meeting"))
        XCTAssertEqual(writer.transcriptURL?.lastPathComponent, "meeting 2.md")
        XCTAssertEqual(try String(contentsOf: first), "final")
    }
    func testWriteFailureDoesNotClaimSuccessAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root) // deterministic ENOTDIR, also works as root
        let writer = SessionArchiveWriter()
        XCTAssertFalse(writer.saveTranscript("text", folder: root, base: "meeting"))
        XCTAssertNil(writer.transcriptURL); XCTAssertNotNil(writer.lastError)
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(writer.saveTranscript("text", folder: root, base: "meeting"))
        XCTAssertNotNil(writer.transcriptURL); XCTAssertNil(writer.lastError)
    }
    func testRenamePreservesCollisionAndSummaryThenCheckpointsNewPath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SessionArchiveWriter()
        XCTAssertTrue(writer.saveTranscript("text", folder: folder, base: "meeting"))
        XCTAssertTrue(writer.saveSummary("summary"))
        let collision = folder.appendingPathComponent("title.md")
        try "existing".write(to: collision, atomically: true, encoding: .utf8)
        XCTAssertTrue(writer.rename(to: "title", folder: folder))
        XCTAssertEqual(writer.transcriptURL?.lastPathComponent, "title 2.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("title 2 요약.md").path))
        XCTAssertTrue(writer.saveTranscript("updated", folder: folder, base: "ignored"))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(writer.transcriptURL)), "updated")
        XCTAssertEqual(try String(contentsOf: collision), "existing")
    }
}
