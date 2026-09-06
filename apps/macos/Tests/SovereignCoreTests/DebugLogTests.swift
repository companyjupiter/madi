import XCTest
@testable import SovereignCore

/// Debug bundle sink (docs/DEBUG_MODE.md): JSONL per stream, raw appends,
/// and a nil shared sink when the mode is off.
@MainActor
final class DebugLogTests: XCTestCase {

    override func tearDown() async throws { DebugLog.stop() }

    func testEmitWritesOneJSONObjectPerLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("madi-debuglog-\(UUID().uuidString)")
        let log = try XCTUnwrap(DebugLog.start(root: root))
        log.emit("store", "boundary", ["cont": false, "gap": 0.25, "prev": "goes,", "n": 3])
        log.emit("store", "join", ["frozen": true])
        log.appendLine("  1.000\t00001-seg.wav\t0.000 /tmp/seg.wav", to: "stdin.log")
        DebugLog.stop()   // flushes
        let text = try String(contentsOf: log.bundle.appendingPathComponent("store.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["ev"] as? String, "boundary")
        XCTAssertEqual(first["cont"] as? Bool, false)
        XCTAssertEqual(first["prev"] as? String, "goes,")
        XCTAssertNotNil(first["t"] as? Double, "session-relative seconds")
        XCTAssertNotNil(first["w"] as? String, "wall clock")
        let stdin = try String(contentsOf: log.bundle.appendingPathComponent("stdin.log"), encoding: .utf8)
        XCTAssertTrue(stdin.hasPrefix("  1.000\t00001-seg.wav"))
        try? FileManager.default.removeItem(at: root)
    }

    func testOffModeIsANilSink() {
        XCTAssertNil(DebugLog.shared)
        // call sites are `DebugLog.shared?.emit(...)`: nothing to write, nothing created
        let store = TranscriptStore()
        store.ingest(.word(t0: 0, t1: 0.3, text: "hello", conf: 1))
        XCTAssertNil(DebugLog.shared)
    }
}
