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
    /// Transcode `src` → temp 16 kHz mono PCM16 WAV; returns the temp URL.
    static func toWav16k(_ src: URL) throws -> URL {
        let file = try AVAudioFile(forReading: src)
        guard let rs = Resampler(from: file.processingFormat) else {
            throw NSError(domain: "AudioDecode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(file.length))   // upper bound (pre-resample)
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            samples.append(contentsOf: rs.convert(buf))
        }
        samples.append(contentsOf: rs.drain())       // flush converter tail
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
