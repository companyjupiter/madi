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

@MainActor
final class AudioCapture {
    /// SEG/OVERLAP mirror the runner defaults; user-tunable in Settings.
    var segmentSeconds: Double = 10 { didSet { segmenter.segmentSeconds = segmentSeconds } }
    var overlapSeconds: Double = 3 { didSet { segmenter.overlapSeconds = overlapSeconds } }

    /// (global start offset seconds, segment wav url)
    var onSegment: ((Double, URL) -> Void)?
    /// 0…1 input level for the meter.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var resampler: Resampler?
    private var segmenter = Segmenter()
    private var segIndex = 0
    private let tempDir: URL

    init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sovereign-segs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: live mic

    func start() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let rs = Resampler(from: hwFormat) else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        resampler = rs
        resetSegmenter()

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self, rs] buf, _ in
            let samples = rs.convert(buf)
            guard !samples.isEmpty else { return }
            let level = AudioCapture.rmsLevel(samples)
            Task { @MainActor in self?.consume(samples, level: level) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Finish the current partial window (final tail) and stop.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        segmenter = Segmenter(segmentSeconds: segmentSeconds, overlapSeconds: overlapSeconds)
        segIndex = 0
    }

    private func consume(_ samples: [Int16], level: Float) {
        onLevel?(level)
        for seg in segmenter.push(samples) { write(seg) }
    }

    private func write(_ seg: Segmenter.Segment) {
        let url = tempDir.appendingPathComponent(String(format: "seg%05d.wav", segIndex))
        segIndex += 1
        do {
            try WavWriter.write(samples: seg.samples, to: url)
            onSegment?(seg.offset, url)
        } catch { NSLog("WAV write failed: \(error)") }
    }

    nonisolated private static func rmsLevel(_ s: [Int16]) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Double = 0
        for v in s { let f = Double(v) / 32768.0; acc += f * f }
        return Float(min(1, (acc / Double(s.count)).squareRoot() * 3))
    }
}
