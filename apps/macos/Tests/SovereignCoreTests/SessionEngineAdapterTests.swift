import XCTest
@testable import SovereignCore

@MainActor
final class SessionEngineAdapterTests: XCTestCase {
    /// Exercises actual Process pipes + protocol parsing through the new port.
    /// No microphone, Whisper binary or downloaded model is involved.
    func testRealProcessReadyFeedFlushAndExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("engine.sh")
        try """
        #!/bin/sh
        echo '[stream] ready'
        while IFS= read -r line; do
          case "$line" in
            FLUSH) echo '<<FLUSH_END>>'; exit 0 ;;
            *) echo '[8] audio: 1s → 1 chunk(s) @16k'; echo '<<SEG_END>>' ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let engine = SessionEngineAdapter(config: .init(binaryURL: script, modelURL: root,
                                                        bpeURL: root, assetsDir: root, streamWavRoots: [root]))
        defer { engine.terminate() }
        let ready = expectation(description: "ready"), segment = expectation(description: "segment")
        let flush = expectation(description: "flush"), exit = expectation(description: "exit")
        var outputs: [String] = []
        engine.onOutput = { output in
            switch output {
            case .ready: outputs.append("ready"); ready.fulfill()
            case .event(.segmentEnd): outputs.append("segment"); segment.fulfill()
            case .flushed: outputs.append("flush"); flush.fulfill()
            case .terminated(let code): XCTAssertEqual(code, 0); outputs.append("exit"); exit.fulfill()
            default: break
            }
        }
        try engine.start()
        await fulfillment(of: [ready], timeout: 3)
        engine.feed(offset: 0, wav: root.appendingPathComponent("audio.wav"))
        await fulfillment(of: [segment], timeout: 3)
        engine.flush()
        await fulfillment(of: [flush, exit], timeout: 3)
        XCTAssertEqual(outputs, ["ready", "segment", "flush", "exit"])
    }

    func testImmediateFileExitDeliversBufferedEventsBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("engine.sh")
        try """
        #!/bin/sh
        i=0
        while [ "$i" -lt 1000 ]; do
          echo '<<SEG_END>>'
          i=$((i + 1))
        done
        printf '[8] audio: 1s → 7 chunk(s) @16k'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let session = SessionCoordinator()
        defer { session.reset() }
        let finished = expectation(description: "all output then finalization")
        var segments = 0, chunks = 0
        session.onEvent = {
            if $0 == .segmentEnd { segments += 1 }
            if case .progressTotal(let total) = $0 { chunks = total }
        }
        session.onFinished = { finished.fulfill() }
        session.startFile(prepare: {
            let wav = root.appendingPathComponent("audio.wav")
            try Data([1]).write(to: wav)
            return wav
        }, makeEngine: { wav in
            SessionEngineAdapter(config: .init(binaryURL: script, modelURL: root,
                                               bpeURL: root, assetsDir: root, fileURL: wav))
        })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(segments, 1000, "process exit must not finalize before stdout is delivered")
        XCTAssertEqual(chunks, 7, "EOF must deliver even a final line without a newline")
    }
}
