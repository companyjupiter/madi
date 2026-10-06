import Foundation
import Observation

/// Device/process ports keep the lifecycle executable without AppKit or a model.
@MainActor
protocol SessionCapture: AnyObject {
    var onSegment: ((Double, URL, Bool) -> Void)? { get set }
    var onPreview: ((URL, Double) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start() async throws
    func pause()
    func resume()
    func stop()
    func abort()
}

enum SessionEngineOutput {
    case ready, flushed, terminated(Int32)
    case event(EngineEvent), structured(StructuredEvent), diagnostic(String)
}

@MainActor
protocol SessionEngine: AnyObject {
    var onOutput: ((SessionEngineOutput) -> Void)? { get set }
    func start() throws
    func feed(offset: Double, wav: URL)
    func feedPreview(wav: URL, forced: String)
    func flush()
    func terminate()
}

@MainActor
protocol SessionDeadline: AnyObject { func cancel() }

@MainActor
private final class TaskDeadline: SessionDeadline {
    private var task: Task<Void, Never>?
    init(seconds: TimeInterval, action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

/// Sole owner of session phase and capture/transcription resource lifetime.
/// Session generation rejects cancelled imports; engine identity rejects events
/// queued by a replaced process. Product work (text, translation, save, summary)
/// runs through callbacks after the lifecycle has made its terminal transition.
@Observable @MainActor
final class SessionCoordinator {
    enum Phase: Equatable {
        case idle, countingDown(Int), engineStarting, ready, recording, paused, processing, flushing, done
        case error(String)
    }
    enum Failure {
        case engineStart(Error), captureStart(Error), preparation(Error)
        case startupTimeout, engineExit(Int32), message(String)
    }
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> any SessionDeadline

    private(set) var phase: Phase = .idle
    private(set) var generation = UUID()
    private(set) var recordStartedAt: Date?
    private var recordEndedAt: Date?
    private var pausedAt: Date?
    private var pausedAccum: TimeInterval = 0
    private let now: () -> Date
    private let schedule: Schedule
    private var engine: (any SessionEngine)?
    private var engineID: UUID?
    private var capture: (any SessionCapture)?
    private var captureTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var deadline: (any SessionDeadline)?
    private var deadlineID = UUID()
    private var countdown: (any SessionDeadline)?
    private var countdownID: UUID?
    private var preparedFile: URL?

    var onEvent: ((EngineEvent) -> Void)?
    var onStructured: ((StructuredEvent) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onRecording: (() -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: (() -> Void)?
    var onFlushTimeout: (() -> Void)?
    var failureMessage: (Failure) -> String = { failure in
        switch failure {
        case .engineStart(let e), .captureStart(let e), .preparation(let e): return e.localizedDescription
        case .startupTimeout: return "Engine startup timed out"
        case .engineExit(let code): return "Engine exited (\(code))"
        case .message(let text): return text
        }
    }

    init(now: @escaping () -> Date = Date.init, schedule: Schedule? = nil) {
        self.now = now
        self.schedule = schedule ?? { TaskDeadline(seconds: $0, action: $1) }
    }

    var recordedSeconds: TimeInterval {
        guard let start = recordStartedAt else { return 0 }
        let end = recordEndedAt ?? now()
        return max(0, end.timeIntervalSince(start) - pausedAccum - (pausedAt.map { end.timeIntervalSince($0) } ?? 0))
    }
    var canStart: Bool {
        switch phase {
        case .idle, .done, .error: return true
        default: return false
        }
    }

    func reset() {
        generation = UUID() // invalidate before termination can invoke callbacks
        releaseResources()
        recordStartedAt = nil; recordEndedAt = nil; pausedAt = nil; pausedAccum = 0
        phase = .idle
    }

    func beginCountdown(from count: Int, start: @escaping () -> Void) {
        guard canStart else { return }
        // Preparing/cancelling a countdown does not replace the displayed
        // transcript or its post-session AI work. The actual start does that.
        let identity = UUID()
        countdownID = identity
        tickCountdown(max(1, count), identity: identity, start: start)
    }
    private func tickCountdown(_ count: Int, identity: UUID, start: @escaping () -> Void) {
        phase = .countingDown(count)
        countdown = schedule(1) { [weak self] in
            guard let self, self.countdownID == identity else { return }
            self.countdown = nil
            if count == 1 { self.countdownID = nil; start() }
            else { self.tickCountdown(count - 1, identity: identity, start: start) }
        }
    }
    func cancelCountdown() {
        guard case .countingDown = phase else { return }
        countdownID = nil; countdown?.cancel(); countdown = nil
        phase = .idle
    }
    func openArchive() {
        guard canStart else { return }
        reset(); phase = .done
    }

    func startLive(engine: any SessionEngine, capture: any SessionCapture) {
        guard canStart || phase == .countingDown(1) else { return }
        reset()
        self.capture = capture
        let token = generation
        // Preserve the configured product callbacks, guarding every delivery.
        let segment = capture.onSegment, preview = capture.onPreview
        let level = capture.onLevel, error = capture.onError
        capture.onSegment = { [weak self] offset, url, speech in
            guard let self, self.generation == token,
                  [.ready, .recording, .paused, .flushing].contains(self.phase) else { return }
            segment?(offset, url, speech)
            self.feed(offset: offset, wav: url)
        }
        if let preview {
            capture.onPreview = { [weak self] url, offset in
                guard let self, self.generation == token, self.phase == .recording else { return }
                preview(url, offset)
            }
        }
        capture.onLevel = { [weak self] value in
            guard let self, self.generation == token, self.phase == .recording else { return }
            level?(value)
        }
        capture.onError = { [weak self] message in
            guard let self, self.generation == token,
                  [.engineStarting, .ready, .recording, .paused].contains(self.phase) else { return }
            error?(message)
        }
        phase = .engineStarting
        armStartupDeadline()
        install(engine)
    }

    /// `prepare` transfers ownership of its temporary WAV to this coordinator.
    /// Even a non-cooperative cancelled decoder cannot launch the next engine.
    func startFile(prepare: @escaping () async throws -> URL,
                   makeEngine: @escaping (URL) -> any SessionEngine) {
        guard canStart else { return }
        reset()
        phase = .processing
        let token = generation
        preparationTask = Task { @MainActor [weak self] in
            do {
                let wav = try await prepare()
                guard let self, !Task.isCancelled, self.generation == token, self.phase == .processing else {
                    try? FileManager.default.removeItem(at: wav)
                    return
                }
                self.preparedFile = wav
                self.preparationTask = nil
                self.install(makeEngine(wav))
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.preparationTask = nil
                self.fail(.preparation(error))
            }
        }
    }

    @discardableResult
    func replaceEngine(_ replacement: any SessionEngine) -> Bool {
        guard phase == .recording || phase == .paused else { return false }
        retireEngine()
        install(replacement)
        return phase == .recording || phase == .paused
    }
    private func install(_ next: any SessionEngine) {
        let token = generation, identity = UUID()
        engineID = identity; engine = next
        next.onOutput = { [weak self] output in
            guard let self, self.generation == token, self.engineID == identity else { return }
            self.receive(output)
        }
        do { try next.start() } catch { fail(.engineStart(error)) }
    }
    private func receive(_ output: SessionEngineOutput) {
        switch output {
        case .ready:
            guard phase == .engineStarting, let capture else { return }
            // Keep the deadline armed until asynchronous capture startup completes.
            phase = .ready
            let token = generation
            captureTask = Task { @MainActor [weak self, capture] in
                do {
                    try await capture.start()
                    guard let self, !Task.isCancelled, self.generation == token, self.phase == .ready else {
                        capture.abort(); return
                    }
                    self.captureTask = nil
                    self.deadline?.cancel(); self.deadline = nil
                    self.recordStartedAt = self.now()
                    self.phase = .recording
                    self.onRecording?()
                } catch {
                    guard let self, !Task.isCancelled, self.generation == token else { capture.abort(); return }
                    self.captureTask = nil
                    self.fail(.captureStart(error))
                }
            }
        case .event(let event):
            if phase == .flushing { armFlushDeadline() }
            onEvent?(event)
        case .structured(let event): onStructured?(event)
        case .diagnostic(let line): onDiagnostic?(line)
        case .flushed:
            if phase == .flushing || phase == .processing { finish() }
        case .terminated(let code):
            if code == 0, phase == .processing || phase == .flushing { finish() }
            else { fail(.engineExit(code)) }
        }
    }
    func feed(offset: Double, wav: URL) { engine?.feed(offset: offset, wav: wav) }
    func feedPreview(wav: URL, forced: String) {
        guard phase == .recording else { return }
        engine?.feedPreview(wav: wav, forced: forced)
    }
    func pause() {
        guard phase == .recording else { return }
        capture?.pause(); pausedAt = now(); phase = .paused
    }
    func resume() {
        guard phase == .paused else { return }
        capture?.resume()
        if let pausedAt { pausedAccum += now().timeIntervalSince(pausedAt) }
        pausedAt = nil; phase = .recording
    }
    func stop() {
        guard phase == .recording || phase == .paused else { return }
        recordEndedAt = now(); phase = .flushing
        armFlushDeadline()
        capture?.stop() // final tail must be fed before FLUSH
        engine?.flush()
    }
    func fail(_ failure: Failure) {
        let hadSession = engine != nil || capture != nil || phase == .processing
        if hadSession { generation = UUID() }
        recordEndedAt = recordEndedAt ?? now()
        releaseResources()
        phase = .error(failureMessage(failure))
        if hadSession { onFailed?() }
    }
    private func finish() {
        guard phase == .flushing || phase == .processing else { return }
        recordEndedAt = recordEndedAt ?? now()
        releaseResources()
        phase = .done
        onFinished?()
    }
    private func armStartupDeadline() {
        let token = generation
        deadline = schedule(45) { [weak self] in
            guard let self, self.generation == token, self.phase == .engineStarting || self.phase == .ready else { return }
            self.fail(.startupTimeout)
        }
    }
    private func armFlushDeadline() {
        deadline?.cancel()
        deadlineID = UUID()
        let token = generation, identity = deadlineID
        deadline = schedule(45) { [weak self] in
            guard let self, self.generation == token, self.deadlineID == identity, self.phase == .flushing else { return }
            self.onFlushTimeout?()
            self.finish()
        }
    }
    private func retireEngine() {
        engineID = nil
        let old = engine; engine = nil
        old?.onOutput = nil; old?.terminate()
    }
    private func releaseResources() {
        deadline?.cancel(); deadline = nil
        countdown?.cancel(); countdown = nil
        countdownID = nil
        captureTask?.cancel(); captureTask = nil
        preparationTask?.cancel(); preparationTask = nil
        if let capture {
            capture.onSegment = nil; capture.onPreview = nil; capture.onLevel = nil; capture.onError = nil
            capture.abort()
        }
        capture = nil
        retireEngine()
        if let preparedFile { try? FileManager.default.removeItem(at: preparedFile) }
        preparedFile = nil
    }
}
