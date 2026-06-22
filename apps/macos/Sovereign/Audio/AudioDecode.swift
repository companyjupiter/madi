// AudioDecode.swift — decode ANY audio OR video container (m4a/mp3/aac/flac/wav,
// mp4/mov/m4v…) to a temp 16 kHz mono PCM WAV the engine can read.
//
// The engine's file reader only accepts PCM16/float32 WAV; a dropped m4a/mp3
// would be rejected ("unsupported WAV format"). Two decode paths, both feeding
// the SAME Resampler + WavWriter:
//   · audio-only files  → AVAudioFile (fast, well-tested).
//   · video containers  → AVAssetReader on the first audio track. AVAudioFile
//     CANNOT open a video .mp4/.mov (it errors 2003334207 — it reads audio-only
//     containers), so we fall back to pulling the audio track's LPCM via the
//     reader. Codecs macOS can't decode (webm/mkv) still surface a clean error.
// Nonisolated + blocking → call from a background queue.
import Foundation
import AVFoundation

enum AudioDecode {
    static let maxInputBytes: Int64 = 2 * 1024 * 1024 * 1024
    // 4 h, not 2 h: the product targets ~2 h meetings, which routinely overrun
    // (2:00:05 etc.). 4 h keeps comfortable headroom while still bounding decode
    // (4 h @ 16 kHz = 230 M samples ≈ 460 MB PCM); the 2 GiB input cap is the real
    // decompression-bomb guard.
    static let maxDecodedSeconds = 4 * 60 * 60
    private static let maxDecodedSamples = maxDecodedSeconds * Int(WavWriter.sampleRate)

    static func validateImportBounds(inputBytes: Int64?,
                                     sourceFrames: AVAudioFramePosition,
                                     sampleRate: Double) throws {
        if let inputBytes, inputBytes > maxInputBytes {
            throw NSError(domain: "AudioDecode", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "file too large"])
        }
        guard sampleRate > 0 else {
            throw NSError(domain: "AudioDecode", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "invalid sample rate"])
        }
        let seconds = Double(sourceFrames) / sampleRate
        if seconds > Double(maxDecodedSeconds) {
            throw NSError(domain: "AudioDecode", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "file too long"])
        }
    }

    /// Transcode `src` → temp 16 kHz mono PCM16 WAV; returns the temp URL.
    /// Audio-only files go through AVAudioFile; anything it rejects (video
    /// containers) falls back to the AVAssetReader audio-track path.
    static func toWav16k(_ src: URL) throws -> URL {
        if let file = try? AVAudioFile(forReading: src) {
            return try writeSamples(decodeAudioFile(file, src: src))
        }
        return try writeSamples(decodeAssetAudioTrack(src))
    }

    /// Audio-only path (m4a/mp3/aac/flac/wav…).
    private static func decodeAudioFile(_ file: AVAudioFile, src: URL) throws -> [Int16] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        try validateImportBounds(
            inputBytes: attrs?[.size] as? Int64,
            sourceFrames: file.length,
            sampleRate: file.processingFormat.sampleRate
        )
        guard let rs = Resampler(from: file.processingFormat) else {
            throw NSError(domain: "AudioDecode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        var samples: [Int16] = []
        samples.reserveCapacity(min(Int(file.length), maxDecodedSamples))
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            samples.append(contentsOf: rs.convert(buf))
            try checkLength(samples.count)
        }
        samples.append(contentsOf: rs.drain())       // flush converter tail
        try checkLength(samples.count)
        return samples
    }

    /// Video-container path (mp4/mov/m4v…): pull the first audio track's LPCM via
    /// AVAssetReader (interleaved Float32 at native rate), then the same Resampler.
    private static func decodeAssetAudioTrack(_ src: URL) throws -> [Int16] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        let asset = AVURLAsset(url: src)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioDecode", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "no audio track in file"])
        }
        guard let fmtDesc = (track.formatDescriptions as? [CMFormatDescription])?.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee else {
            throw NSError(domain: "AudioDecode", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable audio format"])
        }
        try validateImportBounds(
            inputBytes: attrs?[.size] as? Int64,
            sourceFrames: AVAudioFramePosition(CMTimeGetSeconds(asset.duration) * asbd.mSampleRate),
            sampleRate: asbd.mSampleRate
        )
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,   // interleaved → one ABL buffer
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "AudioDecode", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read audio track"])
        }
        reader.add(output)
        reader.startReading()
        // Init the Resampler from the reader's OWN LPCM output format description —
        // it carries the channel layout AVAudioConverter needs to downmix stereo→
        // mono. A manually-built multi-channel AVAudioFormat lacks that layout and
        // silently yields SILENCE for stereo input (verified: stereo→0 amplitude).
        var rs: Resampler?
        var pcmFormat: AVAudioFormat?
        var samples: [Int16] = []
        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer() {
            if pcmFormat == nil, let fd = CMSampleBufferGetFormatDescription(sbuf) {
                pcmFormat = AVAudioFormat(cmAudioFormatDescription: fd)
                rs = pcmFormat.flatMap { Resampler(from: $0) }
            }
            if let rs, let fmt = pcmFormat, let pcm = pcmBuffer(from: sbuf, format: fmt) {
                samples.append(contentsOf: rs.convert(pcm))
            }
            CMSampleBufferInvalidate(sbuf)
            if samples.count > maxDecodedSamples { reader.cancelReading(); break }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "AudioDecode", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "audio decode failed"])
        }
        guard let rs else {
            throw NSError(domain: "AudioDecode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no audio decoded"])
        }
        samples.append(contentsOf: rs.drain())
        try checkLength(samples.count)
        return samples
    }

    /// Copy one LPCM CMSampleBuffer into an AVAudioPCMBuffer of `format` (must match
    /// the reader's interleaved-Float32 layout). Returns nil on empty/failed copy.
    private static func pcmBuffer(from sbuf: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = CMSampleBufferGetNumSamples(sbuf)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sbuf, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }

    private static func checkLength(_ count: Int) throws {
        if count > maxDecodedSamples {
            throw NSError(domain: "AudioDecode", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "file too long"])
        }
    }

    private static func writeSamples(_ samples: [Int16]) throws -> URL {
        guard !samples.isEmpty else {
            throw NSError(domain: "AudioDecode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no audio decoded"])
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("sovereign-decode.wav")
        try WavWriter.write(samples: samples, to: dst)
        return dst
    }
}
