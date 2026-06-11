// Resampler.swift — any-format → 16 kHz mono Int16, via AVAudioConverter.
//
// Extracted from AudioCapture so both the mic tap AND the file-injection
// verification harness drive the SAME conversion code (Layer 1: native capture
// must match ffmpeg's `-ar 16000 -ac 1` closely enough that transcription is
// unaffected). @unchecked Sendable: the only mutable state is AVAudioConverter,
// which we call serially (one buffer at a time) from a single thread.
//
// Quality knob: `sampleRateConverterQuality = .max` — this is the ONE variable
// to sweep if Layer 1 fidelity falls short of ffmpeg's swr (DESIGN/verification).

import AVFoundation

final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    let target: AVAudioFormat

    init?(from inputFormat: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(WavWriter.sampleRate),
            channels: 1, interleaved: true),
            let conv = AVAudioConverter(from: inputFormat, to: target) else { return nil }
        conv.sampleRateConverterQuality = .max
        self.target = target
        self.converter = conv
    }

    /// Convert one input buffer to 16 kHz mono Int16 samples.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard cap > 0, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)
        else { return [] }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Flush the sample-rate converter's internal buffer (the last ~filter-latency
    /// samples). Call once after the final input buffer so the tail isn't dropped
    /// (measured: ~12 ms lost over a 17-min file without this).
    func drain() -> [Int16] {
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return [] }
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            status.pointee = .endOfStream; return nil
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
