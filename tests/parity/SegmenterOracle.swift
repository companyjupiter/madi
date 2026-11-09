import Foundation
import CryptoKit

private struct Configuration: Decodable {
    let sampleRate: Int
    let segmentSeconds: Double
    let overlapSeconds: Double
    let firstSegmentSeconds: Double
    let earlyFlushSilenceSeconds: Double
    let earlyFlushMinBodySeconds: Double
    func make() -> Segmenter {
        var stream = Segmenter(sampleRate: sampleRate, segmentSeconds: segmentSeconds,
                               overlapSeconds: overlapSeconds, firstSegmentSeconds: firstSegmentSeconds)
        apply(to: &stream)
        return stream
    }
    func apply(to stream: inout Segmenter) {
        precondition(stream.sampleRate == sampleRate)
        stream.segmentSeconds = segmentSeconds; stream.overlapSeconds = overlapSeconds
        stream.firstSegmentSeconds = firstSegmentSeconds
        stream.earlyFlushSilenceSeconds = earlyFlushSilenceSeconds
        stream.earlyFlushMinBodySeconds = earlyFlushMinBodySeconds
    }
}
private struct Operation: Decodable {
    let type: String
    let count: Int?
    let pattern: [Int16]?
    let phase: Int?
    let configuration: Configuration?
}
private struct Case: Decodable { let name: String; let configuration: Configuration; let operations: [Operation] }
private func pcm(_ offset: Double, _ samples: [Int16]) -> [String: Any] {
    let little = samples.map { $0.littleEndian }
    let bytes = little.withUnsafeBytes { Data($0) }
    return ["offsetBits": String(format: "%016llx", offset.bitPattern), "sampleCount": samples.count,
            "pcmSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
}
private func snapshot(_ stream: Segmenter, _ segments: [Segmenter.Segment]) -> [String: Any] {
    let preview = stream.previewWindow()
    return ["pendingCount": stream.pendingCount, "preview": pcm(preview.offset, preview.samples),
            "segments": segments.map { segment -> [String: Any] in
                var result = pcm(segment.offset, segment.samples)
                result["bodyCount"] = segment.bodyCount; result["hadSpeech"] = segment.hadSpeech
                return result
            }]
}
@main struct Oracle {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let result: [[String: Any]] = cases.map { item in
            var stream = item.configuration.make()
            var states = [snapshot(stream, [])]
            for operation in item.operations {
                var segments: [Segmenter.Segment] = []
                switch operation.type {
                case "push":
                    let pattern = operation.pattern!, phase = operation.phase ?? 0
                    let frames = (0..<operation.count!).map { pattern[($0 + phase) % pattern.count] }
                    segments = stream.push(frames)
                case "flush": if let tail = stream.flush() { segments = [tail] }
                case "configure": operation.configuration!.apply(to: &stream)
                default: preconditionFailure("unknown operation")
                }
                states.append(snapshot(stream, segments))
            }
            return ["name": item.name, "states": states]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
