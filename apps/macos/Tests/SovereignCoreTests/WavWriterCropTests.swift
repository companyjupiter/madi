import XCTest
@testable import SovereignCore

final class WavWriterCropTests: XCTestCase {
    func testCropProducesBoundedCanonicalClip() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-crop-source-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }
        try WavWriter.write(samples: Array(repeating: 123, count: 160_000), to: source) // 10 s
        let cropped = try WavWriter.crop16kMonoPCM(source: source, start: 4, end: 5, pad: 0.2)
        defer { try? FileManager.default.removeItem(at: cropped) }
        let bytes = try Data(contentsOf: cropped)
        XCTAssertEqual(bytes.prefix(4), Data("RIFF".utf8))
        // 1.4 s × 16 kHz × 2 bytes + canonical 44-byte header.
        XCTAssertEqual(bytes.count, 44 + 22_400 * 2)
        XCTAssertLessThan(bytes.count, (try Data(contentsOf: source)).count / 5)
    }

    func testCropRejectsNonWav() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-crop-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("not wav".utf8).write(to: source)
        XCTAssertThrowsError(try WavWriter.crop16kMonoPCM(source: source, start: 0, end: 1))
    }
}
