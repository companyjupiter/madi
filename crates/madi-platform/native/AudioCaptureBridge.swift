// In-process OS boundary only. Rust owns mixing, pauses, segmenting and files.
// The callback borrows its buffers for the duration of the call. IDs never reuse
// a Swift object or a Rust pointer. All commands and callbacks are main-queue
// ordered; stop acknowledges only after an in-flight start and SCStream stop.
import AVFoundation
import ScreenCaptureKit

typealias CaptureCallback = @convention(c) (UInt64, UInt32, UnsafePointer<Int16>?, Int,
                                          UnsafePointer<CChar>?) -> UInt8

// Bound PCM waiting to enter the main actor as well as Rust's receiver queue.
// A suspended UI/main actor must not retain unbounded tap-delivery Tasks.
private final class DeliveryBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var closed = false
    func reserve(_ count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if closed { return 0 }
        if count > 320_000 - samples { closed = true; return -1 }
        samples += count
        return 1
    }
    func release(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        samples -= count
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
}

@MainActor private final class CaptureEndpoint: NSObject, SCStreamOutput, SCStreamDelegate {
    static var owners: [UInt64: CaptureEndpoint] = [:]
    let id: UInt64
    let callback: CaptureCallback
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var tapGeneration: UInt64 = 0
    private var stream: SCStream?
    private var starting: Task<Void, Never>?
    private var ending = false
    private var finishing = false
    private let sampleQueue = DispatchQueue(label: "madi.capture.system")
    private let deliveryBudget = DeliveryBudget()
    // Accessed exclusively by sampleQueue, as in shipping SystemAudioCapture.
    nonisolated(unsafe) private var systemResampler: Resampler?

    init(id: UInt64, callback: @escaping CaptureCallback) {
        self.id = id
        self.callback = callback
    }

    @discardableResult private func emit(_ kind: UInt32, samples: [Int16] = [], error: String? = nil) -> Bool {
        let accepted = samples.withUnsafeBufferPointer { pcm in
            if let error {
                return error.withCString { callback(id, kind, pcm.baseAddress, pcm.count, $0) }
            }
            return callback(id, kind, pcm.baseAddress, pcm.count, nil)
        } != 0
        if !accepted, kind != 5 { end() }
        return accepted
    }

    private func deliver(_ samples: [Int16], mic: Bool) {
        guard !ending, !samples.isEmpty else { return }
        emit(mic ? 2 : 3, samples: samples)
    }

    // Rust drops/mixes samples; these markers serialize pause/resume with the
    // exact main-queue PCM ordering without stopping or restarting a device.
    func pauseMarker(_ paused: Bool) {
        guard !ending else { return }
        emit(paused ? 6 : 7)
    }

    nonisolated private func enqueue(_ samples: [Int16], mic: Bool, generation: UInt64? = nil) {
        guard !samples.isEmpty else { return }
        switch deliveryBudget.reserve(samples.count) {
        case 1:
            DispatchQueue.main.async {
                defer { self.deliveryBudget.release(samples.count) }
                guard generation == nil || self.tapGeneration == generation else { return }
                self.deliver(samples, mic: mic)
            }
        case -1:
            DispatchQueue.main.async {
                guard !self.ending else { return }
                self.emit(4, error: "native audio main queue fell behind")
                self.end()
            }
        default: break
        }
    }

    func begin(source: UInt32, device: UInt32) {
        starting = Task { @MainActor in
            do {
                try Task.checkCancellation()
                if source != 1 { try startMic(device: device) }
                if source != 0 {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    try Task.checkCancellation()
                    guard let display = content.displays.first else {
                        throw NSError(domain: "SystemAudioCapture", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "no display available"])
                    }
                    let configuration = SCStreamConfiguration()
                    configuration.capturesAudio = true
                    configuration.excludesCurrentProcessAudio = true
                    configuration.sampleRate = 48_000
                    configuration.channelCount = 2
                    configuration.width = 2; configuration.height = 2
                    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    let input = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                         configuration: configuration, delegate: self)
                    try input.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                    // Retain this exact stream even if end arrives during await.
                    stream = input
                    try await input.startCapture()
                    try Task.checkCancellation()
                }
                if !ending { emit(1) }
            } catch {
                if !ending { emit(4, error: error.localizedDescription); ending = true }
            }
            starting = nil
            if ending { await finish() }
        }
    }

    private func startMic(device: UInt32) throws {
        let engine = engine ?? AVAudioEngine()
        self.engine = engine
        if device != 0 { AudioDevices.setInput(device, on: engine) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = Resampler(from: format) else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        tapGeneration += 1
        let generation = tapGeneration
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self, converter] buffer, _ in
            let samples = converter.convert(buffer)
            self?.enqueue(samples, mic: true, generation: generation)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func stopMic() {
        tapGeneration += 1
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop()
    }

    func switchInput(_ device: UInt32) {
        guard !ending, engine?.isRunning == true else { return }
        stopMic()
        do { try startMic(device: device == 0 ? (AudioDevices.defaultInputID ?? 0) : device) }
        catch { emit(4, error: error.localizedDescription); end() }
    }

    func end() {
        guard !ending else { return }
        ending = true
        deliveryBudget.close()
        starting?.cancel()
        stopMic()
        Task { @MainActor in await finish() }
    }

    private func finish() async {
        guard !finishing else { return }
        finishing = true
        deliveryBudget.close()
        if let pending = starting { await pending.value }
        stopMic()
        if let input = stream {
            stream = nil
            do { try await input.stopCapture() }
            catch { emit(4, error: error.localizedDescription) }
        }
        // Drain the serial conversion queue before the final acknowledgement.
        await withCheckedContinuation { continuation in
            sampleQueue.async { self.systemResampler = nil; continuation.resume() }
        }
        engine = nil
        emit(5)
        Self.owners.removeValue(forKey: id)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(buffer), let description = buffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(count),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return }
        if systemResampler == nil { systemResampler = Resampler(from: format) }
        guard let converter = systemResampler else { return }
        let samples = converter.convert(pcm)
        enqueue(samples, mic: false)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard !self.ending, self.stream === stream else { return }
            self.emit(4, error: error.localizedDescription)
            self.end()
        }
    }

#if MADI_CAPTURE_REPLAY
    // Debug-only deterministic input through the shipping converter; never opens
    // a device or requests permission. Each yield allows cancellation to interleave.
    func replay(path: String, chunk: UInt32) {
        starting = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                guard let converter = Resampler(from: file.processingFormat) else {
                    throw NSError(domain: "AudioCapture", code: 2)
                }
                emit(1)
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                        throw NSError(domain: "AudioCapture", code: 3)
                    }
                    try file.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    enqueue(converter.convert(buffer), mic: true)
                    await Task.yield()
                }
                try Task.checkCancellation()
                enqueue(converter.drain(), mic: true)
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            } catch {
                if !ending { emit(4, error: error.localizedDescription) }
            }
            ending = true
            starting = nil
            await finish()
        }
    }
#endif
}

@_cdecl("madi_capture_start")
func captureStart(_ id: UInt64, _ source: UInt32, _ device: UInt32, _ callback: @escaping CaptureCallback) {
    DispatchQueue.main.async {
        let owner = CaptureEndpoint(id: id, callback: callback)
        CaptureEndpoint.owners[id] = owner
        owner.begin(source: source, device: device)
    }
}

@_cdecl("madi_capture_stop")
func captureStop(_ id: UInt64) {
    DispatchQueue.main.async { CaptureEndpoint.owners[id]?.end() }
}

@_cdecl("madi_capture_switch_input")
func captureSwitchInput(_ id: UInt64, _ device: UInt32) {
    DispatchQueue.main.async { CaptureEndpoint.owners[id]?.switchInput(device) }
}

@_cdecl("madi_capture_pause_marker")
func capturePauseMarker(_ id: UInt64, _ paused: UInt8) {
    DispatchQueue.main.async { CaptureEndpoint.owners[id]?.pauseMarker(paused != 0) }
}

#if MADI_CAPTURE_REPLAY
@_cdecl("madi_capture_replay")
func captureReplay(_ id: UInt64, _ path: UnsafePointer<CChar>, _ chunk: UInt32, _ callback: @escaping CaptureCallback) {
    let copiedPath = String(cString: path)
    DispatchQueue.main.async {
        let owner = CaptureEndpoint(id: id, callback: callback)
        CaptureEndpoint.owners[id] = owner
        owner.replay(path: copiedPath, chunk: chunk)
    }
}

@_cdecl("madi_capture_pump")
func capturePump() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
#endif
