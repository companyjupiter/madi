// AudioDecodeLimitTests.swift — bounds checks for file import transcoding.
//
// Build standalone:
//   swiftc -parse-as-library Sovereign/Audio/AudioDecode.swift \
//          Sovereign/Audio/Resampler.swift Sovereign/Audio/WavWriter.swift \
//          Tests/AudioDecodeLimitTests.swift -o /tmp/adtest && /tmp/adtest

import AVFoundation
import Foundation

@main
struct AudioDecodeLimitTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond { failures += 1; print("FAIL: \(msg)") }
        }
        func accepts(bytes: Int64?, frames: AVAudioFramePosition, rate: Double) -> Bool {
            do {
                try AudioDecode.validateImportBounds(inputBytes: bytes, sourceFrames: frames, sampleRate: rate)
                return true
            } catch {
                return false
            }
        }

        check(accepts(bytes: 10 * 1024 * 1024, frames: 60 * 48_000, rate: 48_000),
              "accepts a normal one-minute import")
        check(!accepts(bytes: AudioDecode.maxInputBytes + 1, frames: 60 * 48_000, rate: 48_000),
              "rejects oversized source files")
        check(!accepts(bytes: 10 * 1024 * 1024,
                       frames: AVAudioFramePosition((AudioDecode.maxDecodedSeconds + 1) * 48_000),
                       rate: 48_000),
              "rejects over-duration source files")
        check(!accepts(bytes: 10 * 1024 * 1024, frames: 60 * 48_000, rate: 0),
              "rejects invalid sample rates")

        if failures == 0 { print("✅ AudioDecode limits: all checks passed") }
        else { print("❌ \(failures) failure(s)"); exit(1) }
    }
}
