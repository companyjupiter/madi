// FileFeeder.swift — drive the resident STREAM engine from an audio FILE,
// OFF the main actor (drag-&-drop file transcription).
//
// AudioCapture is @MainActor (it owns the mic tap + UI-bound state), so its
// feedFile() would block the UI on a long recording. This is a deliberate fork:
// a nonisolated, self-contained file→16k→segment→WAV pipeline that reuses the
// exact same Resampler / Segmenter / WavWriter the mic path uses (so a dropped
// file gets identical diarization, OSD, confidence and offsets), but runs on a
// background queue and touches no @MainActor state. Each closed segment is
// handed to `onSegment` as ("<global offset s>", <temp wav url>), which the
// caller forwards to EngineProcess.feed (thread-safe).
import Foundation
import AVFoundation

enum FileFeeder {
    /// Read `url` (any format/rate), resample to 16 kHz, segment with the same
    /// asymmetric-first windowing the mic uses, write temp WAVs, and hand each
    /// to `onSegment`. BLOCKING — call from a background queue. Returns the
    /// number of segments emitted. Throws if the file can't be opened/decoded.
    @discardableResult
    static func feed(_ url: URL, tempDir: URL,
                     segmentSeconds: Double = 10, overlapSeconds: Double = 3,
                     firstSegmentSeconds: Double = 3,
                     onSegment: (Double, URL) -> Void) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        guard let rs = Resampler(from: file.processingFormat) else {
            throw NSError(domain: "FileFeeder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        var segmenter = Segmenter(segmentSeconds: segmentSeconds, overlapSeconds: overlapSeconds,
                                  firstSegmentSeconds: firstSegmentSeconds)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var idx = 0
        func write(_ segs: [Segmenter.Segment]) throws {
            for s in segs {
                let out = tempDir.appendingPathComponent(String(format: "drop%05d.wav", idx)); idx += 1
                try WavWriter.write(samples: s.samples, to: out)
                onSegment(s.offset, out)
            }
        }

        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            let samples = rs.convert(buf)
            if samples.isEmpty { continue }
            try write(segmenter.push(samples))
        }
        try write(segmenter.push(rs.drain()))   // flush converter tail
        if let f = segmenter.flush() {           // final partial window
            let out = tempDir.appendingPathComponent(String(format: "drop%05d.wav", idx)); idx += 1
            try WavWriter.write(samples: f.samples, to: out)
            onSegment(f.offset, out)
        }
        return idx
    }
}
