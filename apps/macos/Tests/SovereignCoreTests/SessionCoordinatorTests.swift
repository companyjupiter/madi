import XCTest
@testable import SovereignCore

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private final class Deadline: SessionDeadline {
        let action: @MainActor () -> Void
        var cancelled = false
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func cancel() { cancelled = true }
        func fire() { if !cancelled { action() } }
    }
    @MainActor private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000)
        var deadlines: [Deadline] = []
        func coordinator() -> SessionCoordinator {
            SessionCoordinator(now: { self.date }, schedule: { _, action in
                let deadline = Deadline(action); self.deadlines.append(deadline); return deadline
            })
        }
    }
    private final class Engine: SessionEngine {
        var onOutput: ((SessionEngineOutput) -> Void)?
        var starts = 0, terminations = 0
        var operations: [String] = []
        var startError: Error?
        func start() throws { starts += 1; if let startError { throw startError } }
        func feed(offset: Double, wav: URL) { operations.append("feed:\(offset)") }
        func feedPreview(wav: URL, forced: String) { operations.append("preview") }
        func flush() { operations.append("flush") }
        func terminate() { terminations += 1 }
    }
    private final class Capture: SessionCapture {
        var onSegment: ((Double, URL, Bool) -> Void)?
        var onPreview: ((URL, Double) -> Void)?
        var onLevel: ((Float) -> Void)?
        var onError: ((String) -> Void)?
        var starts = 0, aborts = 0, stops = 0, pauses = 0, resumes = 0
        var startError: Error?
        var suspend = false
        var continuation: CheckedContinuation<Void, Error>?
        func start() async throws {
            starts += 1
            if let startError { throw startError }
            if suspend { try await withCheckedThrowingContinuation { continuation = $0 } }
        }
        func pause() { pauses += 1 }
        func resume() { resumes += 1 }
        func stop() {
            stops += 1
            onSegment?(10, URL(fileURLWithPath: "/tail.wav"), true)
        }
        func abort() { aborts += 1 }
    }
    private struct Fault: Error {}
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    func testStopFeedsTailBeforeFlushAndFinalizesExactlyOnce() async {
        let clock = Clock(), capture = Capture(), engine = Engine()
        let session = clock.coordinator()
        var finishes = 0
        session.onFinished = { finishes += 1 }
        session.startLive(engine: engine, capture: capture)
        engine.onOutput?(.ready); await settle()
        XCTAssertEqual(session.phase, .recording)
        clock.date.addTimeInterval(10)
        session.pause(); clock.date.addTimeInterval(20); session.resume()
        clock.date.addTimeInterval(5)
        session.stop(); session.stop()
        XCTAssertEqual(session.phase, .flushing)
        XCTAssertEqual(engine.operations, ["feed:10.0", "flush"])
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(session.recordedSeconds, 15)
        let lateOutput = engine.onOutput
        engine.onOutput?(.flushed)
        lateOutput?(.terminated(0)); lateOutput?(.flushed)
        clock.date.addTimeInterval(100)
        XCTAssertEqual(session.phase, .done)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(session.recordedSeconds, 15)
        XCTAssertEqual(engine.terminations, 1)
        XCTAssertEqual(capture.aborts, 1)
        XCTAssertTrue(clock.deadlines.allSatisfy(\.cancelled))
    }

    func testEngineFailureReleasesCaptureAndRejectsAllLateCallbacks() async {
        let session = Clock().coordinator(), capture = Capture(), engine = Engine()
        var failures = 0, segments = 0, events = 0
        session.onFailed = { failures += 1 }
        session.onEvent = { _ in events += 1 }
        capture.onSegment = { _, _, _ in segments += 1 }
        session.startLive(engine: engine, capture: capture)
        engine.onOutput?(.ready); await settle()
        let lateSegment = capture.onSegment, lateOutput = engine.onOutput
        engine.onOutput?(.terminated(9))
        lateSegment?(1, URL(fileURLWithPath: "/old.wav"), true)
        lateOutput?(.event(.progressTotal(2))); lateOutput?(.flushed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(segments, 0); XCTAssertEqual(events, 0)
        XCTAssertEqual(capture.aborts, 1); XCTAssertEqual(engine.terminations, 1)
        guard case .error = session.phase else { return XCTFail("failure was hidden") }
    }

    func testLaunchAndCaptureFailuresUseSameTerminalCleanup() async {
        for captureFails in [false, true] {
            let clock = Clock(), capture = Capture(), engine = Engine()
            let session = clock.coordinator()
            if captureFails { capture.startError = Fault() } else { engine.startError = Fault() }
            var failures = 0
            session.onFailed = { failures += 1 }
            session.startLive(engine: engine, capture: capture)
            engine.onOutput?(.ready); await settle()
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(capture.aborts, 1); XCTAssertEqual(engine.terminations, 1)
            XCTAssertTrue(clock.deadlines.allSatisfy(\.cancelled))
            guard case .error = session.phase else { return XCTFail() }
        }
    }

    func testStartupTimeoutCoversEngineAndSuspendedCapture() async {
        for engineReady in [false, true] {
            let clock = Clock(), capture = Capture(), engine = Engine()
            let session = clock.coordinator()
            capture.suspend = true
            session.startLive(engine: engine, capture: capture)
            if engineReady { engine.onOutput?(.ready); await settle() }
            clock.deadlines.first?.fire()
            XCTAssertEqual(engine.terminations, 1)
            XCTAssertEqual(capture.aborts, 1)
            guard case .error = session.phase else { return XCTFail() }
            capture.continuation?.resume(); await settle()
            guard case .error = session.phase else { return XCTFail("late start revived session") }
        }
    }

    func testCancelledCaptureStartupCannotAbortNextCapture() async {
        let session = Clock().coordinator(), oldCapture = Capture(), oldEngine = Engine()
        oldCapture.suspend = true
        session.startLive(engine: oldEngine, capture: oldCapture)
        oldEngine.onOutput?(.ready); await settle()
        session.reset()
        let nextCapture = Capture(), nextEngine = Engine()
        session.startLive(engine: nextEngine, capture: nextCapture)
        nextEngine.onOutput?(.ready); await settle()
        oldCapture.continuation?.resume(); await settle()
        XCTAssertEqual(session.phase, .recording)
        XCTAssertEqual(nextCapture.starts, 1); XCTAssertEqual(nextCapture.aborts, 0)
        session.reset()
    }

    func testWatchdogReplacementIgnoresOldExitAndDoesNotRestartCapture() async {
        let session = Clock().coordinator(), capture = Capture(), oldEngine = Engine()
        var events = 0
        session.onEvent = { _ in events += 1 }
        session.startLive(engine: oldEngine, capture: capture)
        oldEngine.onOutput?(.ready); await settle()
        session.pause()
        let oldOutput = oldEngine.onOutput, replacement = Engine()
        XCTAssertTrue(session.replaceEngine(replacement))
        replacement.onOutput?(.ready)
        oldOutput?(.terminated(15)); oldOutput?(.event(.progressTotal(4)))
        await settle()
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.aborts, 0)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(oldEngine.terminations, 1)
        replacement.onOutput?(.event(.progressTotal(5)))
        XCTAssertEqual(events, 1)
        session.reset()
    }

    func testReplacementLaunchFailureStopsCapture() async {
        let session = Clock().coordinator(), capture = Capture(), engine = Engine()
        session.startLive(engine: engine, capture: capture)
        engine.onOutput?(.ready); await settle()
        let replacement = Engine(); replacement.startError = Fault()
        XCTAssertFalse(session.replaceEngine(replacement))
        XCTAssertEqual(capture.aborts, 1)
        XCTAssertEqual(engine.terminations, 1); XCTAssertEqual(replacement.terminations, 1)
    }

    func testFlushTimeoutRefreshesOnProgressAndFinalizesOnce() async {
        let clock = Clock(), capture = Capture(), engine = Engine()
        let current = clock.coordinator()
        var timedOut = 0, finished = 0
        current.onFlushTimeout = { timedOut += 1 }
        current.onFinished = { finished += 1 }
        current.startLive(engine: engine, capture: capture)
        engine.onOutput?(.ready); await settle(); current.stop()
        let oldDeadline = clock.deadlines.last!
        engine.onOutput?(.event(.progressTotal(1)))
        oldDeadline.action() // simulate a callback already enqueued at cancellation
        XCTAssertEqual(current.phase, .flushing)
        clock.deadlines.last?.fire()
        XCTAssertEqual(current.phase, .done)
        XCTAssertEqual(timedOut, 1); XCTAssertEqual(finished, 1)
    }

    func testCountdownCannotRestartAfterCancellationOrDuringRecording() async {
        let clock = Clock()
        let current = clock.coordinator()
        var starts = 0
        current.beginCountdown(from: 3) { starts += 1 }
        clock.deadlines.last?.fire()
        XCTAssertEqual(current.phase, .countingDown(2))
        let cancelled = clock.deadlines.last!
        current.cancelCountdown(); cancelled.action()
        XCTAssertEqual(current.phase, .idle); XCTAssertEqual(starts, 0)
        let priorGeneration = current.generation
        let engine = Engine(), capture = Capture()
        current.beginCountdown(from: 1) { current.startLive(engine: engine, capture: capture) }
        clock.deadlines.last?.fire(); engine.onOutput?(.ready); await settle()
        XCTAssertNotEqual(current.generation, priorGeneration)
        current.beginCountdown(from: 1) { starts += 1 }
        current.cancelCountdown()
        XCTAssertEqual(current.phase, .recording); XCTAssertEqual(starts, 0)
        current.reset()
    }

    func testCancelledImportCannotLaunchOrFailTheNextFile() async throws {
        for oldFails in [false, true] {
            let session = Clock().coordinator(), oldEngine = Engine(), nextEngine = Engine()
            var continuation: CheckedContinuation<URL, Error>?
            var next: CheckedContinuation<URL, Error>?
            session.startFile(prepare: { try await withCheckedThrowingContinuation { continuation = $0 } },
                              makeEngine: { _ in oldEngine })
            await settle(); XCTAssertNotNil(continuation)
            session.reset()
            session.startFile(prepare: { try await withCheckedThrowingContinuation { next = $0 } },
                              makeEngine: { _ in nextEngine })
            await settle()
            let staleFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data([1]).write(to: staleFile)
            if oldFails { continuation?.resume(throwing: Fault()); try FileManager.default.removeItem(at: staleFile) }
            else { continuation?.resume(returning: staleFile) }
            await settle()
            XCTAssertEqual(session.phase, .processing)
            XCTAssertEqual(oldEngine.starts, 0); XCTAssertEqual(nextEngine.starts, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
            let currentFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data([2]).write(to: currentFile)
            next?.resume(returning: currentFile); await settle()
            XCTAssertEqual(nextEngine.starts, 1)
            nextEngine.onOutput?(.terminated(0))
            XCTAssertEqual(session.phase, .done)
            XCTAssertFalse(FileManager.default.fileExists(atPath: currentFile.path))
        }
    }
}
