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

    /// Incremental 16 kHz mono PCM16 writer (2026-09-09): the file import used
    /// to collect every sample in memory before writing (4 h = 460 MB, and the
    /// Data copy doubled it). Header sizes are patched on `finish()`.
    final class Streaming {
        private let handle: FileHandle
        private(set) var samples: Int = 0
        let url: URL
        init(url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            self.url = url
            try handle.write(contentsOf: WavWriter.header(dataBytes: 0))
        }
        func append(_ chunk: [Int16]) throws {
            guard !chunk.isEmpty else { return }
            try chunk.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
            samples += chunk.count
        }
        func finish() throws {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WavWriter.header(dataBytes: UInt32(samples * MemoryLayout<Int16>.size)))
            try handle.close()
        }
    }

    static func header(dataBytes: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var d = Data(capacity: 44)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        ascii("data"); u32(dataBytes)
        return d
    }

    /// Crop a canonical Madi segment WAV to one transcript line. Live segments
    /// are written by `write`, so a strict format check is safer than accepting a
    /// malformed container. The bounded clip prevents whole-window text from
    /// replacing one line and reduces forced-language decode work proportionally.
    static func crop16kMonoPCM(source: URL, start: Double, end: Double,
                               pad: Double = 0.2) throws -> URL {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        func ascii(_ offset: Int, _ value: String) -> Bool {
            guard let bytes = value.data(using: .ascii), offset + bytes.count <= data.count else { return false }
            return data[offset..<(offset + bytes.count)].elementsEqual(bytes)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        guard data.count >= 44, ascii(0, "RIFF"), ascii(8, "WAVE"), ascii(12, "fmt "),
              u16(20) == 1, u16(22) == channels, u32(24) == sampleRate,
              u16(34) == bitsPerSample, ascii(36, "data") else {
            throw NSError(domain: "WavWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unsupported segment WAV"])
        }
        let payloadBytes = min(Int(u32(40)), data.count - 44)
        let sampleCount = payloadBytes / MemoryLayout<Int16>.size
        let lo = max(0, min(sampleCount, Int(floor((start - pad) * Double(sampleRate)))))
        let hi = max(lo, min(sampleCount, Int(ceil((end + pad) * Double(sampleRate)))))
        guard hi > lo else {
            throw NSError(domain: "WavWriter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "empty crop"])
        }
        var samples: [Int16] = []
        samples.reserveCapacity(hi - lo)
        for index in lo..<hi {
            let offset = 44 + index * 2
            samples.append(Int16(bitPattern: u16(offset)))
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-correction-\(UUID().uuidString).wav")
        try write(samples: samples, to: destination)
        return destination
    }
}
