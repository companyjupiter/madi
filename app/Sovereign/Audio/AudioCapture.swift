// AudioCapture.swift — AVAudioEngine mic capture → 16 kHz mono WAV segmenter.
//
// Replaces the old runner's `ffmpeg -f avfoundation … -ar 16000 -ac 1` capture.
// Reproduces the runner's segmentation: SEG-second windows with OVERLAP seconds
// of left-context prepended (so words split across a boundary are recovered by
// the engine's sliding-window logic). Each closed segment is written to a temp
// WAV and handed back via `onSegment(offset:url:)`.
//
// Concurrency: the input tap fires on a realtime audio thread (nonisolated).
// Resampling state lives in a dedicated `@unchecked Sendable` Resampler so the
// tap never touches @MainActor state; converted Int16 frames hop to the main
// actor for segmentation/UI.
//
// Permission: first tap install triggers the OS mic dialog (needs
// NSMicrophoneUsageDescription + the audio-input entitlement).

import AVFoundation

/// Owns the AVAudioConverter; safe to call from the audio thread.
private final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from hwFormat: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(WavWriter.sampleRate),
            channels: 1, interleaved: true),
            let conv = AVAudioConverter(from: hwFormat, to: target) else { return nil }
        self.target = target
        self.converter = conv
    }

    /// Convert one hw buffer to 16 kHz mono Int16 samples.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

@MainActor
final class AudioCapture {
    /// SEG/OVERLAP mirror the runner defaults; user-tunable in Settings.
    var segmentSeconds: Double = 10
    var overlapSeconds: Double = 3

    /// (global start offset seconds, segment wav url)
    var onSegment: ((Double, URL) -> Void)?
    /// 0…1 input level for the meter.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var resampler: Resampler?

    private var pending: [Int16] = []          // samples not yet emitted (current window)
    private var overlapTail: [Int16] = []      // last OVERLAP seconds, prepended to next seg
    private var globalSampleCount: Int = 0      // total emitted-window samples (for offset)
    private var segIndex = 0
    private let tempDir: URL

    private var segSamples: Int { Int(segmentSeconds * Double(WavWriter.sampleRate)) }
    private var overlapSamples: Int { Int(overlapSeconds * Double(WavWriter.sampleRate)) }

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sovereign-segs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: control

    func start() throws {
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
            Task { @MainActor in self?.append(samples, level: level) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Finish the current partial window (final tail) and stop.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if !pending.isEmpty { emitSegment(final: true) }
    }

    // MARK: segmentation (main actor)

    private func append(_ samples: [Int16], level: Float) {
        onLevel?(level)
        pending.append(contentsOf: samples)
        while pending.count >= segSamples { emitSegment(final: false) }
    }

    private func emitSegment(final: Bool) {
        let take = final ? pending.count : segSamples
        guard take > 0 else { return }
        let body = Array(pending.prefix(take))
        pending.removeFirst(take)

        // prepend overlap tail from the previous window (none on the first)
        let seg = overlapTail + body
        let offset = Double(globalSampleCount - overlapTail.count)
            / Double(WavWriter.sampleRate)

        let url = tempDir.appendingPathComponent(String(format: "seg%05d.wav", segIndex))
        segIndex += 1
        do {
            try WavWriter.write(samples: seg, to: url)
            onSegment?(max(offset, 0), url)
        } catch { NSLog("WAV write failed: \(error)") }

        globalSampleCount += body.count
        overlapTail = Array(body.suffix(overlapSamples))
    }

    // MARK: util

    nonisolated private static func rmsLevel(_ s: [Int16]) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Double = 0
        for v in s { let f = Double(v) / 32768.0; acc += f * f }
        return Float(min(1, (acc / Double(s.count)).squareRoot() * 3))
    }
}
