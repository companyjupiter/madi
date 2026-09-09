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
        // video container: bytes are picture, only the duration cap applies
        check((try? AudioDecode.validateImportBounds(inputBytes: 7 * 1024 * 1024 * 1024, sourceFrames: 872 * 48_000,
                                                     sampleRate: 48_000, videoContainer: true)) != nil,
              "accepts a 7 GB video whose audio is 14.5 minutes")
        check((try? AudioDecode.validateImportBounds(inputBytes: 7 * 1024 * 1024 * 1024,
                                                     sourceFrames: AVAudioFramePosition((AudioDecode.maxDecodedSeconds + 1) * 48_000),
                                                     sampleRate: 48_000, videoContainer: true)) == nil,
              "still rejects an over-duration video")
        check(AudioDecode.reason(NSError(domain: "AudioDecode", code: 3)) == "파일이 64 GB를 넘습니다", "reason text for the byte cap")
        check(accepts(bytes: 12 * 1024 * 1024 * 1024, frames: 3600 * 48_000, rate: 48_000), "accepts a 12 GB one-hour audio-only file")

        if failures == 0 { print("✅ AudioDecode limits: all checks passed") }
        else { print("❌ \(failures) failure(s)"); exit(1) }
    }
}
