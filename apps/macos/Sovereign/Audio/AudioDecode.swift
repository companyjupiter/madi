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
    /// Korean reason for the import error banner; nil = generic "unsupported or damaged".
    static func reason(_ error: Error) -> String? {
        let e = error as NSError
        guard e.domain == "AudioDecode" else { return nil }
        switch e.code {
        case 3: return "파일이 \(maxInputBytes >> 30) GB를 넘습니다"
        case 5: return "길이가 \(maxDecodedSeconds / 3600)시간을 넘습니다"
        case 6: return "오디오 트랙이 없습니다"
        case 7, 8, 9: return "오디오 트랙을 macOS가 디코드하지 못합니다"
        default: return nil
        }
    }
    /// 64 GiB, effectively unbounded (2026-09-09; was 2 GiB): both decode paths
    /// stream, so bytes are not memory, and the duration cap is the real guard —
    /// a 4K60 master is 10+ GB for an hour, a 12 h 48 kHz stereo WAV is 10 GB.
    static let maxInputBytes: Int64 = 64 * 1024 * 1024 * 1024
    // 12 h (2026-09-09; was 4 h while the app held every sample in memory).
    // The decode now streams to the temp WAV, so the bound is the ENGINE's:
    // file mode reads the whole WAV into RAM (readFileAlloc, 2 GiB cap) —
    // 12 h of 16 kHz PCM16 is 1.38 GB, tolerable beside the 1.3 GB model on a
    // 16 GB machine; 18 h would hit the 2 GiB read cap. Longer masters need the
    // engine to mmap the WAV (backlog).
    static let maxDecodedSeconds = 12 * 60 * 60
    private static let maxDecodedSamples = maxDecodedSeconds * Int(WavWriter.sampleRate)

    /// `videoContainer`: the byte cap is a decompression-bomb guard for AUDIO
    /// files, where bytes ≈ audio. In a video container the bytes are the
    /// picture (a 14.5-minute YouTube master is 6.9 GB) and the audio track is
    /// streamed by AVAssetReader, never loaded whole — so only the duration cap
    /// applies there (2026-09-09: "지원하지 않는 형식" on a 6.9 GB 14.5-min H.264 mp4).
    static func validateImportBounds(inputBytes: Int64?,
                                     sourceFrames: AVAudioFramePosition,
                                     sampleRate: Double,
                                     videoContainer: Bool = false) throws {
        if !videoContainer, let inputBytes, inputBytes > maxInputBytes {
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
    static func toWav16k(_ src: URL) async throws -> URL {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("sovereign-decode.wav")
        let out = try WavWriter.Streaming(url: dst)
        if let file = try? AVAudioFile(forReading: src) {
            try await decodeAudioFile(file, src: src, into: out)
        } else {
            try await decodeAssetAudioTrack(src, into: out)
        }
        try out.finish()
        guard out.samples > 0 else {
            throw NSError(domain: "AudioDecode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no audio decoded"])
        }
        return dst
    }

    /// Audio-only path (m4a/mp3/aac/flac/wav…).
    private static func decodeAudioFile(_ file: AVAudioFile, src: URL, into out: WavWriter.Streaming) async throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        // AVAudioFile happily opens an mp4/mov that carries AAC — this path is
        // not "audio-only files" but "containers AVAudioFile can read", so the
        // byte cap must still be decided by what the bytes ARE.
        let hasVideo = !(try await AVURLAsset(url: src).loadTracks(withMediaType: .video)).isEmpty
        try validateImportBounds(
            inputBytes: attrs?[.size] as? Int64,
            sourceFrames: file.length,
            sampleRate: file.processingFormat.sampleRate,
            videoContainer: hasVideo
        )
        guard let rs = Resampler(from: file.processingFormat) else {
            throw NSError(domain: "AudioDecode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            try out.append(rs.convert(buf))
            try checkLength(out.samples)
        }
        try out.append(rs.drain())       // flush converter tail
        try checkLength(out.samples)
    }

    /// Video-container path (mp4/mov/m4v…): pull the first audio track's LPCM via
    /// AVAssetReader (interleaved Float32 at native rate), then the same Resampler.
    private static func decodeAssetAudioTrack(_ src: URL, into out: WavWriter.Streaming) async throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioDecode", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "no audio track in file"])
        }
        guard let fmtDesc = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee else {
            throw NSError(domain: "AudioDecode", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable audio format"])
        }
        try validateImportBounds(
            inputBytes: attrs?[.size] as? Int64,
            sourceFrames: AVAudioFramePosition(CMTimeGetSeconds(try await asset.load(.duration)) * asbd.mSampleRate),
            sampleRate: asbd.mSampleRate,
            videoContainer: true
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
        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer() {
            if pcmFormat == nil, let fd = CMSampleBufferGetFormatDescription(sbuf) {
                pcmFormat = AVAudioFormat(cmAudioFormatDescription: fd)
                rs = pcmFormat.flatMap { Resampler(from: $0) }
            }
            if let rs, let fmt = pcmFormat, let pcm = pcmBuffer(from: sbuf, format: fmt) {
                try out.append(rs.convert(pcm))
            }
            CMSampleBufferInvalidate(sbuf)
            if out.samples > maxDecodedSamples { reader.cancelReading(); break }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "AudioDecode", code: 9,
                userInfo: [NSLocalizedDescriptionKey: "audio decode failed"])
        }
        guard let rs else {
            throw NSError(domain: "AudioDecode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no audio decoded"])
        }
        try out.append(rs.drain())
        try checkLength(out.samples)
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

}
