// WavWriter.swift — minimal 16 kHz mono 16-bit PCM WAV writer.
// Matches the engine's expected input format (what ffmpeg -ar 16000 -ac 1
// produced in the old runner). Writes a canonical 44-byte header + PCM.

import Foundation

enum WavWriter {
    static let sampleRate: UInt32 = 16_000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    /// Write Int16 samples to `url` as a mono 16 kHz WAV.
    static func write(samples: [Int16], to url: URL) throws {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        let riffSize = 36 + dataBytes

        var d = Data(capacity: Int(44 + dataBytes))
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }

        ascii("RIFF"); u32(riffSize); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1) /* PCM */; u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        ascii("data"); u32(dataBytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }

        try d.write(to: url, options: .atomic)
    }
}
