import AVFoundation
import CryptoKit
import Foundation

// Independent sequential reference: the unchanged shipping converter and
// Segmenter, driven exactly like AudioCapture.feedFile (including drain).
@main enum CaptureBridgeOracle {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let cases = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
        var results: [[String: Any]] = []
        for test in cases {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: test["path"] as! String))
            let converter = Resampler(from: file.processingFormat)!
            var segmenter = Segmenter(firstSegmentSeconds: 1.5)
            let chunk = UInt32(test["chunk"] as! Int)
            var bytes = Data(); var chunks: [Int] = []; var segments: [[String: Any]] = []
            func describe(_ segment: Segmenter.Segment) -> [String: Any] {
                let data = segment.samples.withUnsafeBytes { Data($0) }
                return ["offsetBits": String(format: "%016llx", segment.offset.bitPattern),
                        "bodyCount": segment.bodyCount, "sampleCount": segment.samples.count,
                        "hadSpeech": segment.hadSpeech,
                        "pcmSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
            }
            func consume(_ pcm: [Int16]) {
                guard !pcm.isEmpty else { return }
                chunks.append(pcm.count)
                pcm.withUnsafeBytes { bytes.append(contentsOf: $0) }
                segments.append(contentsOf: segmenter.push(pcm).map(describe))
            }
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                consume(converter.convert(buffer))
            }
            consume(converter.drain())
            if let tail = segmenter.flush() { segments.append(describe(tail)) }
            results.append(["name": test["name"]!, "sampleCount": bytes.count / 2, "chunks": chunks,
                            "pcmSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                            "segments": segments, "events": ["started", "stopped"], "cancelEvents": ["stopped"]])
        }
        let result = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        FileHandle.standardOutput.write(result)
    }
}
