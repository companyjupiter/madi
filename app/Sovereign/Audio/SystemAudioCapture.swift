// SystemAudioCapture.swift — capture SYSTEM audio (what's playing through the Mac:
// Teams / Slack huddles / Zoom / YouTube) via ScreenCaptureKit, resampled to the
// same 16 kHz mono Int16 the mic path produces, so the engine pipeline is unchanged.
//
// Sovereign: no virtual-audio driver (BlackHole/Loopback) — ScreenCaptureKit is
// built into macOS 13+. First use triggers the system Screen-Recording permission
// prompt (audio-only still needs it). We exclude our OWN process audio so the app's
// sounds aren't captured. Video frames are requested minimally and ignored.

import AVFoundation
import ScreenCaptureKit

@MainActor
final class SystemAudioCapture: NSObject {
    /// 16 kHz mono Int16 samples + a 0…1 level, delivered on the main actor.
    var onSamples: (([Int16], Float) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "sovereign.sysaudio")
    // touched only on sampleQueue (serial) — created on the first buffer when the
    // stream's audio format is known. Resampler is @unchecked Sendable.
    nonisolated(unsafe) private var resampler: Resampler?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no display available"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true      // don't capture our own output
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2                // minimal video (ignored)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        sampleQueue.async { [weak self] in self?.resampler = nil }
    }
}

extension SystemAudioCapture: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let fmtDesc = sampleBuffer.formatDescription else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
        let n = CMSampleBufferGetNumSamples(sampleBuffer)
        guard n > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        pcm.frameLength = AVAudioFrameCount(n)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        if resampler == nil { resampler = Resampler(from: fmt) }   // serial queue → safe
        guard let rs = resampler else { return }
        let samples = rs.convert(pcm)
        guard !samples.isEmpty else { return }
        let level = SystemAudioCapture.rmsLevel(samples)
        Task { @MainActor in self.onSamples?(samples, level) }
    }

    nonisolated private static func rmsLevel(_ s: [Int16]) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc = 0.0
        for v in s { let f = Double(v) / 32768.0; acc += f * f }
        return Float(min(1, (acc / Double(s.count)).squareRoot() * 3))
    }
}
