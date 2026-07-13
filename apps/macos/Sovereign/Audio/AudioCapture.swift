// AudioCapture.swift — AVAudioEngine mic capture → 16 kHz mono WAV segmenter.
//
// Replaces the old runner's `ffmpeg -f avfoundation … -ar 16000 -ac 1` capture.
// Resampling lives in Resampler, windowing in Segmenter; this class wires the
// mic tap (and a deterministic file-injection path for verification) to them
// and turns closed segments into temp WAVs handed back via onSegment.
//
// Concurrency: the input tap fires on a realtime audio thread (nonisolated).
// Resampler is @unchecked Sendable, so the tap never touches @MainActor state;
// converted Int16 frames hop to the main actor for segmentation/IO/UI.
//
// Permission: first tap install triggers the OS mic dialog (needs
// NSMicrophoneUsageDescription + the audio-input entitlement).

import AVFoundation

/// Where the audio comes from. `system` = ScreenCaptureKit (Teams/Slack/YouTube);
/// `both` = mic + system mixed (online meeting: you + remote participants).
enum AudioSource: String, CaseIterable, Identifiable {
    case mic, system, both
    var id: String { rawValue }
    var label: String { self == .mic ? "마이크" : self == .system ? "시스템 오디오" : "마이크+시스템" }
}

@MainActor
final class AudioCapture {
    /// SEG/OVERLAP mirror the runner defaults; user-tunable in Settings.
    var segmentSeconds: Double = 10 { didSet { segmenter.segmentSeconds = segmentSeconds } }
    var overlapSeconds: Double = 3 { didSet { segmenter.overlapSeconds = overlapSeconds } }
    /// Short first window so the first transcript paints in ~1.5 s instead of ~10 s
    /// (later windows keep the full `segmentSeconds` context — no accuracy loss).
    /// 3→1.5 s (2026-07-02): with the engine's AUDIO_CTX=auto truncated encoder a
    /// 1.5 s window decodes in ~0.3 s, and the 3 s overlap + WordMerger re-cover
    /// the boundary — first committed text ~3.5 s → ~1.8 s.
    var firstSegmentSeconds: Double = 1.5 { didSet { segmenter.firstSegmentSeconds = firstSegmentSeconds } }

    /// (global start offset seconds, segment wav url, window had speech)
    var onSegment: ((Double, URL, Bool) -> Void)?
    /// Streaming preview: the in-progress window written to a wav, emitted every
    /// ~previewSeconds of new audio so a separate engine can decode interim text
    /// before the window closes. nil = previews off.
    var onPreview: ((URL) -> Void)?
    /// 1.5→1.0 s (2026-07-02): AUDIO_CTX=auto cut the preview decode ~2× — the
    /// extra preview turns fit inside the freed GPU budget, interim text −0.5 s.
    var previewSeconds: Double = 1.0
    /// 0…1 input level for the meter.
    var onLevel: ((Float) -> Void)?
    /// Specific input device (nil = system default).
    var inputDeviceID: AudioDeviceID?
    /// Audio source: mic / system / both. Set before start().
    var source: AudioSource = .mic
    /// Surfaced when system-audio capture fails (e.g. Screen-Recording denied).
    var onError: ((String) -> Void)?

    private var sysCapture: SystemAudioCapture?
    private let engine = AVAudioEngine()
    private var resampler: Resampler?
    private var segmenter = Segmenter()
    private var segIndex = 0
    private let tempDir: URL
    var segmentDirectory: URL { tempDir }

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sovereign-segs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: live mic

    func start() throws {
        resetSegmenter()
        micPending.removeAll(); sysPending.removeAll()

        if source != .system {   // mic or both
            if let dev = inputDeviceID { AudioDevices.setInput(dev, on: engine) }
            let input = engine.inputNode
            let hwFormat = input.outputFormat(forBus: 0)
            guard let rs = Resampler(from: hwFormat) else {
                throw NSError(domain: "AudioCapture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
            }
            resampler = rs
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self, rs] buf, _ in
                let samples = rs.convert(buf)
                guard !samples.isEmpty else { return }
                let level = AudioCapture.rmsLevel(samples)
                Task { @MainActor in self?.ingest(samples, level: level, mic: true) }
            }
            engine.prepare()
            try engine.start()
        }

        if source != .mic {      // system or both
            let sc = SystemAudioCapture()
            sc.onSamples = { [weak self] s, lvl in self?.ingest(s, level: lvl, mic: false) }
            sc.onError = { [weak self] msg in self?.onError?(msg) }
            sysCapture = sc
            Task { [weak self] in
                do { try await sc.start() }
                catch { self?.onError?("시스템 오디오를 시작할 수 없습니다 — 화면 기록 권한을 허용하세요. (\(error.localizedDescription))") }
            }
        }
    }

    /// Route a source's samples: single-source → straight to the segmenter; `both`
    /// → time-aligned mix (sum the overlapping prefix; a stalled source counts as
    /// silence so an absent/silent side never blocks the other).
    private var micPending: [Int16] = []
    private var sysPending: [Int16] = []
    private func ingest(_ samples: [Int16], level: Float, mic: Bool) {
        guard source == .both else { consume(samples, level: level); return }
        if paused { onLevel?(0); micPending.removeAll(); sysPending.removeAll(); return }
        if mic { micPending.append(contentsOf: samples) } else { sysPending.append(contentsOf: samples) }
        let stall = WavWriter.sampleRate * 2   // 2 s: a side with no counterpart → flush solo
        if micPending.count > stall, sysPending.isEmpty { let m = micPending; micPending.removeAll(); consume(m, level: AudioCapture.rmsLevel(m)); return }
        if sysPending.count > stall, micPending.isEmpty { let s = sysPending; sysPending.removeAll(); consume(s, level: AudioCapture.rmsLevel(s)); return }
        let n = min(micPending.count, sysPending.count)
        guard n > 0 else { return }
        var mixed = [Int16](); mixed.reserveCapacity(n)
        for i in 0..<n { mixed.append(Int16(max(-32768, min(32767, Int(micPending[i]) + Int(sysPending[i]))))) }
        micPending.removeFirst(n); sysPending.removeFirst(n)
        consume(mixed, level: AudioCapture.rmsLevel(mixed))
    }

    /// Pause/resume: keep the AVAudioEngine running (mic warm, instant resume)
    /// but drop captured buffers while paused — the paused span is simply absent
    /// from the segmenter timeline, so the recording skips the break.
    private var paused = false
    func pause() { paused = true }
    func resume() { paused = false }

    /// Switch the input mic MID-capture: brief engine hop (tap off → device →
    /// tap on) on the new device's hardware format. The segmenter timeline
    /// simply has no samples for the ~100 ms swap — same as a short pause.
    /// Not running (or system-audio source): just records the choice for the
    /// next start().
    func switchInput(to id: AudioDeviceID?) {
        inputDeviceID = id
        guard source != .system, engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // nil = follow the system default. The AUHAL keeps whatever device it
        // was bound to, so re-bind the CURRENT default explicitly.
        if let dev = id ?? AudioDevices.defaultInputID {
            AudioDevices.setInput(dev, on: engine)
        }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let rs = Resampler(from: hwFormat) else {
            onError?("마이크를 전환하지 못했어요 — 이전 마이크로 계속 녹음하려면 다시 선택하세요.")
            return
        }
        resampler = rs
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self, rs] buf, _ in
            let samples = rs.convert(buf)
            guard !samples.isEmpty else { return }
            let level = AudioCapture.rmsLevel(samples)
            Task { @MainActor in self?.ingest(samples, level: level, mic: true) }
        }
        engine.prepare()
        do { try engine.start() }
        catch { onError?("마이크 전환 후 재시작 실패: \(error.localizedDescription)") }
    }

    /// Finish the current partial window (final tail) and stop.
    func stop() {
        paused = false
        if source != .system { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        sysCapture?.stop(); sysCapture = nil
        // mix tail: flush whatever remains (the other side counts as silence)
        if source == .both {
            let tail = micPending.count >= sysPending.count ? micPending : sysPending
            if !tail.isEmpty { consume(tail, level: 0) }
            micPending.removeAll(); sysPending.removeAll()
        }
        if let seg = segmenter.flush() { write(seg) }
    }

    // MARK: deterministic file injection (verification + --replay)

    /// Drive the EXACT mic path from a WAV file (any rate) instead of the mic.
    /// Returns the number of segments emitted. Used by the capture-verify harness
    /// and the file-replay mode — no AVAudioEngine, same Resampler+Segmenter.
    @discardableResult
    func feedFile(_ url: URL, chunkFrames: AVAudioFrameCount = 4096) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        guard let rs = Resampler(from: file.processingFormat) else {
            throw NSError(domain: "AudioCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        resampler = rs
        resetSegmenter()
        var count = 0
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: chunkFrames) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            let samples = rs.convert(buf)
            guard !samples.isEmpty else { continue }
            for seg in segmenter.push(samples) { write(seg); count += 1 }
        }
        for seg in segmenter.push(rs.drain()) { write(seg); count += 1 } // flush converter tail
        if let seg = segmenter.flush() { write(seg); count += 1 }
        return count
    }

    // MARK: plumbing

    private func resetSegmenter() {
        segmenter = Segmenter(segmentSeconds: segmentSeconds, overlapSeconds: overlapSeconds,
                              firstSegmentSeconds: firstSegmentSeconds)
        segIndex = 0
    }

    private var samplesSincePreview = 0
    private func consume(_ samples: [Int16], level: Float) {
        if paused { onLevel?(0); return }   // drop audio + drop the meter while paused
        onLevel?(level)
        for seg in segmenter.push(samples) { write(seg); samplesSincePreview = 0 }
        // streaming preview: every previewSeconds of new audio, hand the in-progress
        // window to the preview engine (only if there's enough pending to be useful).
        if onPreview != nil {
            samplesSincePreview += samples.count
            let interval = Int(previewSeconds * Double(WavWriter.sampleRate))
            if samplesSincePreview >= interval, segmenter.pendingCount > interval / 2 {
                samplesSincePreview = 0
                let pw = segmenter.previewWindow()
                writePreview(pw.samples)
            }
        }
    }

    private var previewSlot = 0
    private func writePreview(_ samples: [Int16]) {
        // rotate a few files so the engine never reads one mid-overwrite
        previewSlot = (previewSlot + 1) % 3
        let url = tempDir.appendingPathComponent("preview-\(previewSlot).wav")
        do { try WavWriter.write(samples: samples, to: url); onPreview?(url) }
        catch { /* preview is best-effort */ }
    }

    private func write(_ seg: Segmenter.Segment) {
        let url = tempDir.appendingPathComponent(String(format: "seg%05d.wav", segIndex))
        segIndex += 1
        do {
            try WavWriter.write(samples: seg.samples, to: url)
            onSegment?(seg.offset, url, seg.hadSpeech)
        } catch { NSLog("WAV write failed: \(error)") }
    }

    nonisolated private static func rmsLevel(_ s: [Int16]) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Double = 0
        for v in s { let f = Double(v) / 32768.0; acc += f * f }
        return Float(min(1, (acc / Double(s.count)).squareRoot() * 3))
    }
}
