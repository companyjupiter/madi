import XCTest
@testable import SovereignCore

final class SessionOneShotTranscriberTests: XCTestCase {
    private func fixture(_ body: String) throws -> SessionOneShotTranscriber.Config {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("transcribe.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return .init(binary: script, model: root, wav: root, bpe: root, assets: root, languageToken: 50264)
    }

    func testSuccessfulOutputPreservesParserAndForcedLanguage() async throws {
        let config = try fixture("""
        printf '=== TRANSCRIPTION (1s) ===\n'
        echo "language $WHISPER_LANG_ID"
        printf '\n[perf] done\n'
        """)
        let result = await SessionOneShotTranscriber.transcribe(config)
        XCTAssertEqual(result, "language 50264")
    }

    func testTimeoutTerminatesStuckCorrectionWithoutApplyingPartialText() async throws {
        let config = try fixture("printf '=== TRANSCRIPTION ===\npartial\n'; exec /bin/sleep 30")
        let began = Date()
        let result = await SessionOneShotTranscriber.transcribe(config, timeout: 0.05)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testFailedProcessDoesNotApplyPartialText() async throws {
        let config = try fixture("printf '=== TRANSCRIPTION ===\npartial\n'; exit 7")
        let result = await SessionOneShotTranscriber.transcribe(config)
        XCTAssertNil(result)
    }

    func testCancellationTerminatesAlreadyRunningCorrection() async throws {
        let config = try fixture("echo started > started; exec /bin/sleep 30")
        let task = Task.detached { await SessionOneShotTranscriber.transcribe(config) }
        defer { task.cancel() }
        let marker = config.assets.appendingPathComponent("started")
        let limit = Date().addingTimeInterval(4)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let began = Date()
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testAlreadyCancelledCorrectionNeverLaunches() async throws {
        let config = try fixture("echo started > started")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SessionOneShotTranscriber.transcribe(config)
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.assets.appendingPathComponent("started").path))
    }
}
