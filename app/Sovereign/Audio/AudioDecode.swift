// AudioDecode.swift — decode ANY audio container (m4a/mp3/aac/flac/wav/mov…) to a
// temp 16 kHz mono PCM WAV the engine can read.
//
// The engine's file reader only accepts PCM16/float32 WAV; a dropped m4a/mp3
// would be rejected ("unsupported WAV format"). AVFoundation decodes every
// format macOS supports, so we transcode to a normalized 16k mono WAV first,
// then hand THAT path to the engine's fast native file mode. Nonisolated +
// blocking → call from a background queue. Reuses Resampler + WavWriter.
import Foundation
import AVFoundation

enum AudioDecode {
    static let maxInputBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxDecodedSeconds = 2 * 60 * 60
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
    static func toWav16k(_ src: URL) throws -> URL {
        let file = try AVAudioFile(forReading: src)
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
            if samples.count > maxDecodedSamples {
                throw NSError(domain: "AudioDecode", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "file too long"])
            }
        }
        samples.append(contentsOf: rs.drain())       // flush converter tail
        if samples.count > maxDecodedSamples {
            throw NSError(domain: "AudioDecode", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "file too long"])
        }
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
